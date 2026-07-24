<#
.SYNOPSIS
    Identifies deletion candidates directly from a file share (Phase 2 rules:
    age + inactive AD owner, or 0-byte files) and writes them out as an Excel
    list in the same shape Invoke-GovernedDeletionFromExcel.ps1 expects.

.DESCRIPTION
    Can be run with NO parameters at all - it asks for anything it needs
    (which folder to scan, where to save the results) in plain language,
    and only skips a question if you already answered it with a -Parameter.

    This script only FINDS and REPORTS candidates - it never quarantines or
    deletes anything itself. That's deliberate: there is exactly one script
    in this package that ever touches a file on disk
    (Invoke-GovernedDeletionFromExcel.ps1, via the common engine's
    Invoke-GovernedAction), and exactly one kind of input it acts on - an
    Excel list. This script is the second scenario's way of producing that
    input without needing the ManageEngine tool first.

    The intended pipeline:
      1. Run this script (no -Execute anywhere here - it always just reports)
         against a drive/share. It writes -OutputExcelPath with a "Path"
         column plus Owner/MatchedRule/SizeBytes/LastWriteTime for review.
      2. A human reviews/approves that Excel - same governance step the
         ManageEngine-driven flow already goes through.
      3. Hand the approved Excel to Invoke-GovernedDeletionFromExcel.ps1
         (-ExcelPath pointing at it, -TargetDrive matching the -TargetPath
         used here) for the actual dry-run-then-execute quarantine/delete.
    This guarantees whatever gets approved is EXACTLY what gets acted on -
    a second scan at execute time could see a share that's already changed,
    which is the gap a single "identify and act in the same run" script
    would have.

    Candidate rule (files only - no whole-folder or duplicate rule in this
    first cut):
        (file is $OlderThanYears+ years old AND its NTFS owner's AD account
         is disabled)  OR  (file is 0 bytes)

    Duplicate detection ("same filename+size+modified") is deliberately NOT
    implemented - checking that across a petabyte-scale share risks breaking
    the script on runtime/memory alone, so it's parked. See TODO.md.

    Owner-activity checks go through Test-OwnerInactive in the common
    engine, which caches one AD lookup per distinct owner rather than one
    per file - the real cost at scale is repeated AD calls, not memory, and
    this keeps it bounded to roughly the number of distinct owners on the
    share (typically hundreds, not millions).

    Every candidate found is written to the CSV log as it's found (one row
    at a time, never buffered) - a complete audit trail of what was
    identified even if the run is interrupted before the Excel is written.
    The Excel export itself is capped at -MaxExcelExportRows to avoid
    holding an unbounded result set in memory; past that cap, narrow
    -TargetPath / tighten the filters and re-run, or work from the CSV log
    directly.

.EXAMPLE
    # Fully interactive - asks for everything it needs, one question at a time
    .\Find-GovernedCandidatesByScan.ps1

.EXAMPLE
    .\Find-GovernedCandidatesByScan.ps1 -TargetPath "\\FS01\Projects" -OutputExcelPath ".\candidates.xlsx"

.EXAMPLE
    # No ActiveDirectory module available on this host - age/0-byte rules only
    .\Find-GovernedCandidatesByScan.ps1 -TargetPath "\\FS01\Projects" -SkipInactiveOwnerCheck -OutputExcelPath ".\candidates.xlsx"

.EXAMPLE
    # Then, once candidates.xlsx has been reviewed and approved:
    .\Invoke-GovernedDeletionFromExcel.ps1 -ExcelPath ".\candidates.xlsx" -TargetDrive "\\FS01\Projects" `
        -ActivityType Quarantine -QuarantineRoot "\\FS01\_Quarantine" -Execute
#>

param(
    [string] $TargetPath,
    [int] $OlderThanYears = 7,
    [switch] $SkipInactiveOwnerCheck,
    [switch] $SkipZeroByteFiles,

    [string] $PathFilter,
    [string] $OwnerFilter,

    [string] $OutputExcelPath,
    [int] $MaxExcelExportRows = 50000,
    [string] $LogPath = ".\governed-candidates-$(Get-Date -Format yyyyMMdd-HHmmss).csv"
)

. (Join-Path $PSScriptRoot "FileShareCleanup-Governed.Common.ps1")

Write-PhaseHeader "Governed File Share Cleanup - Setup"
Write-Host "Answer a few questions to get started. Anything you already passed as a -Parameter won't be asked again."

# Not [Parameter(Mandatory)] on purpose - see the same note in
# Invoke-GovernedDeletionFromExcel.ps1 about avoiding PowerShell's own
# generic parameter prompt in favor of this friendlier one.
if (-not $TargetPath) {
    $TargetPath = Read-RequiredPath -Prompt "Which folder/drive do you want to scan? (e.g. \\FS01\Projects)" -MustExist
}
elseif (-not (Test-Path -LiteralPath $TargetPath)) {
    throw "Target path not found: $TargetPath"
}

if (-not $OutputExcelPath) {
    $defaultOutput = ".\candidates-$(Get-Date -Format yyyyMMdd-HHmmss).xlsx"
    $OutputExcelPath = Read-OptionalValue -Prompt "Where should the candidate list be saved?" -Default $defaultOutput
}

if (-not $PSBoundParameters.ContainsKey('OlderThanYears')) {
    $OlderThanYears = Read-OptionalInt -Prompt "How many years old should a file be to qualify (plus owner no longer active)?" -Default $OlderThanYears
}

Write-PhaseHeader "Phase 1/3: Validating prerequisites"

if (-not $SkipInactiveOwnerCheck) {
    if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) {
        throw "ActiveDirectory module not found (needed to check whether a file owner's AD account is disabled). Install RSAT/ActiveDirectory, or pass -SkipInactiveOwnerCheck to run the age/0-byte rules without it."
    }
    Import-Module ActiveDirectory
}
if (-not (Get-Module -ListAvailable -Name ImportExcel)) {
    throw "ImportExcel module not found. Install it first: Install-Module ImportExcel -Scope CurrentUser"
}
Import-Module ImportExcel

Write-Host "Target path   : $TargetPath"
Write-Host "Cutoff        : items older than $OlderThanYears years qualify (if owner inactive), plus 0-byte files"
Write-Host "Output Excel  : $OutputExcelPath"
Write-Host "Log           : $LogPath"
Write-Host "This script only IDENTIFIES candidates - it never quarantines or deletes anything." -ForegroundColor Cyan

$cutoff = (Get-Date).AddYears(-$OlderThanYears)
$startTime = Get-Date
$script:matchedCount = 0
$script:totalBytesSoFar = 0
# List[object], not a plain array - "+=" rebuilds the whole array on every
# append (O(n^2)), impractical once matches climb into the tens of
# thousands. Still bounded by -MaxExcelExportRows below, but there's no
# reason to pay the O(n^2) cost even up to that cap.
$script:resultRows = [System.Collections.Generic.List[object]]::new()
$script:ruleCounts = @{}

Write-PhaseHeader "Phase 2/3: Scanning $TargetPath"

# Cheap pre-filter (no AD calls) shared by the count pass and the process
# pass below - AD lookups only happen in the process pass, and only for
# files that already pass this age/zero-byte check.
$fileFilter = {
    (-not (Test-ExcludedPath -Path $_.FullName)) -and (
        (-not $SkipZeroByteFiles -and $_.Length -eq 0) -or
        ($_.LastWriteTime -lt $cutoff)
    )
}

$totalFileCandidates = (Get-ChildItem -LiteralPath $TargetPath -File -Recurse -Force -ErrorAction SilentlyContinue |
        Where-Object $fileFilter | Measure-Object).Count
Write-Host "$TargetPath : $totalFileCandidates file(s) to evaluate (age and/or zero-byte pre-filter)..."

$script:j = 0
Get-ChildItem -LiteralPath $TargetPath -File -Recurse -Force -ErrorAction SilentlyContinue |
    Where-Object $fileFilter |
    ForEach-Object {
        $file = $_
        $script:j++
        Write-ScanProgress -Current $j -Total $totalFileCandidates -StartTime $startTime -CurrentItem $file.FullName

        $owner = Get-ItemOwner -Path $file.FullName
        $rule = $null

        if ($file.Length -eq 0) {
            $rule = "ZeroByte"
        }
        elseif ($file.LastWriteTime -lt $cutoff) {
            $ownerInactive = if ($SkipInactiveOwnerCheck) { $true } else { Test-OwnerInactive -Owner $owner }
            if ($ownerInactive) {
                $rule = if ($SkipInactiveOwnerCheck) { "OlderThan$($OlderThanYears)y-OwnerCheckSkipped" } else { "OlderThan$($OlderThanYears)y+InactiveOwner" }
            }
        }

        # Age-old but active owner: does not qualify under this rule set - not a candidate.
        if (-not $rule) { return }
        if ($PathFilter -and ($file.FullName -notlike $PathFilter)) { return }
        if ($OwnerFilter -and ($owner -notlike $OwnerFilter)) { return }

        Write-GovernedLogEntry -LogPath $LogPath -Path $file.FullName -ItemType File `
            -SizeBytes $file.Length -FileCount 1 -NewestFile $file.LastWriteTime -Owner $owner `
            -MatchedRule $rule -Action "Identified"
        Write-ActionLine -Level Info -Message "CANDIDATE  $($file.FullName)  ($('{0:N1} MB' -f ($file.Length / 1MB)), owner $owner, rule $rule)"

        $script:matchedCount++
        $script:totalBytesSoFar += $file.Length
        $prior = if ($script:ruleCounts.ContainsKey($rule)) { $script:ruleCounts[$rule] } else { 0 }
        $script:ruleCounts[$rule] = $prior + 1

        if ($script:resultRows.Count -lt $MaxExcelExportRows) {
            $candidateRow = [PSCustomObject]@{
                Path          = $file.FullName
                Owner         = $owner
                MatchedRule   = $rule
                SizeBytes     = $file.Length
                LastWriteTime = $file.LastWriteTime
                Identified    = (Get-Date).ToString("o")
            }
            $script:resultRows.Add($candidateRow)
        }
    }

Write-Progress -Activity "File share scan" -Completed

Write-PhaseHeader "Phase 3/3: Writing candidate list"

if ($script:resultRows.Count -ge $MaxExcelExportRows) {
    Write-ActionLine -Level Warn -Message "Match count reached the $MaxExcelExportRows-row export cap - not writing $OutputExcelPath. Full detail is in the CSV log: $LogPath. Narrow -TargetPath or tighten filters and re-run."
    $excelWritten = $null
}
elseif ($script:resultRows.Count -eq 0) {
    Write-Host "No candidates found under $TargetPath with the current rules - nothing to write."
    $excelWritten = $null
}
else {
    $script:resultRows | Export-Excel -Path $OutputExcelPath -WorksheetName "Candidates" -AutoSize
    Write-ActionLine -Level Success -Message "Candidate list written to $OutputExcelPath"
    $excelWritten = $OutputExcelPath
}

Write-GovernedSummary -LogPath $LogPath -MatchedCount $script:matchedCount -TotalBytes $script:totalBytesSoFar -ExcelPath $excelWritten -StatusCounts $script:ruleCounts

if ($excelWritten) {
    Write-Host ""
    Write-Host "Next step: review and approve $excelWritten, then run:" -ForegroundColor Cyan
    Write-Host "  .\Invoke-GovernedDeletionFromExcel.ps1 -ExcelPath `"$excelWritten`" -TargetDrive `"$TargetPath`" -ActivityType Quarantine -QuarantineRoot <path>" -ForegroundColor Cyan
    Write-Host "  (add -Execute once the dry run output looks right)" -ForegroundColor Cyan
}
