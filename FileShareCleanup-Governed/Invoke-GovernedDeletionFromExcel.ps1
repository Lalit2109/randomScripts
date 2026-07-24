<#
.SYNOPSIS
    Governed quarantine/delete run driven by a ManageEngine-produced Excel
    candidate list, writing the outcome of every row back into that same
    Excel file as an audit trail.

.DESCRIPTION
    Can be run with NO parameters at all - it asks for anything it needs in
    plain language (Excel path, Quarantine vs. Delete, quarantine folder)
    and only skips a question if you already answered it with a -Parameter.
    This is meant to be runnable by someone who has never used PowerShell
    parameters before, not just by whoever wrote it.

    Reads a column of paths from an Excel worksheet (ImportExcel module -
    Install-Module ImportExcel, no Excel/Office installation required).
    Each row may point at either a single file or a whole folder - both are
    handled, determined per-row via Get-Item/.PSIsContainer.

    -TargetDrive is asked as an OPTIONAL question (Enter to skip). Every
    row already carries its own full path, so it's never required:
      - If given, it's an extra safety-net scope filter (rows outside it
        are skipped as "SkippedOutOfScope") and anchors every quarantined
        item's relative path to that one root.
      - If skipped, no scope filter is applied, and each quarantined item's
        relative path is anchored to ITS OWN UNC share/drive root instead -
        so a list spanning multiple shares still quarantines sensibly.

    Dry run by default. Nothing is touched unless you pass -Execute:
      -ActivityType Quarantine   moves matches under -QuarantineRoot, in a
                                  run-dated batch folder.
      -ActivityType Delete       permanently removes matches.
    If -ActivityType isn't passed, you're asked for it interactively (as a
    simple 1/2 menu) - this one is always asked, because there's no way to
    infer it from the Excel data. -Execute itself is intentionally NEVER
    asked interactively - it stays a deliberate command-line-only step, so
    a real run always requires having already reviewed a dry run's output
    and consciously re-running with -Execute added.
    Without -Execute, every row is still fully evaluated and logged/written
    back with "WouldQuarantine"/"WouldDelete" - the dry-run Excel/CSV output
    is a complete preview of exactly what a real run would do.

    Safe to re-run: rows whose CleanupStatus is already the terminal
    "Deleted" or "Quarantined" are skipped, so an interrupted run can just be
    re-run as-is.

    Optional narrowing filters (all combined with AND) act as a safety net
    on top of the Excel list itself:
      -PathFilter     wildcard match against the full path, e.g. "*\Archive\*"
      -OwnerFilter    wildcard match against the NTFS owner, e.g. "CONTOSO\jsmith"
      -OlderThanYears require the file/folder's newest content to predate this

.EXAMPLE
    # Fully interactive - asks for everything it needs, one question at a time
    .\Invoke-GovernedDeletionFromExcel.ps1

.EXAMPLE
    # Dry run - reports exactly what would happen, nothing touched.
    # You'll be prompted once for -ActivityType since it wasn't passed.
    .\Invoke-GovernedDeletionFromExcel.ps1 -ExcelPath ".\candidates.xlsx" -ActivityType Quarantine -QuarantineRoot "\\FS01\_Quarantine"

.EXAMPLE
    # Real quarantine run, no -TargetDrive - each row anchors to its own share/drive root
    .\Invoke-GovernedDeletionFromExcel.ps1 -ExcelPath ".\candidates.xlsx" `
        -ActivityType Quarantine -QuarantineRoot "\\FS01\_Quarantine" -Execute

.EXAMPLE
    # Real quarantine run WITH the optional -TargetDrive safety net
    .\Invoke-GovernedDeletionFromExcel.ps1 -ExcelPath ".\candidates.xlsx" -TargetDrive "\\FS01\Projects" `
        -ActivityType Quarantine -QuarantineRoot "\\FS01\_Quarantine" -Execute

.EXAMPLE
    # Real permanent-delete run (requires typed confirmation before it proceeds)
    .\Invoke-GovernedDeletionFromExcel.ps1 -ExcelPath ".\candidates.xlsx" -ActivityType Delete -Execute
#>

param(
    [string] $ExcelPath,
    [string] $WorksheetName,
    [string] $PathColumn = "Path",
    [string] $TargetDrive,

    [ValidateSet('Quarantine', 'Delete')] [string] $ActivityType,
    [string] $QuarantineRoot,

    [string] $PathFilter,
    [string] $OwnerFilter,
    [int] $OlderThanYears,

    [switch] $Execute,
    [string] $LogPath = ".\governed-cleanup-from-excel-$(Get-Date -Format yyyyMMdd-HHmmss).csv"
)

. (Join-Path $PSScriptRoot "FileShareCleanup-Governed.Common.ps1")

function Set-RowResult {
    param($Row, [string] $Status, [string] $Detail = "")
    Add-Member -InputObject $Row -NotePropertyName CleanupStatus -NotePropertyValue $Status -Force
    Add-Member -InputObject $Row -NotePropertyName CleanupDetail -NotePropertyValue $Detail -Force
    Add-Member -InputObject $Row -NotePropertyName CleanupTimestamp -NotePropertyValue (Get-Date).ToString("o") -Force
    Add-Member -InputObject $Row -NotePropertyName CleanupBy -NotePropertyValue $env:USERNAME -Force
}

Write-PhaseHeader "Governed File Share Cleanup - Setup"
Write-Host "Answer a few questions to get started. Anything you already passed as a -Parameter won't be asked again."

# -ExcelPath isn't [Parameter(Mandatory)] on purpose - that would trigger
# PowerShell's own generic "Supply values for the following parameters"
# prompt before this script's friendlier one ever got a chance to run.
if (-not $ExcelPath) {
    $ExcelPath = Read-RequiredPath -Prompt "Full path to the candidate Excel file" -MustExist
}
elseif (-not (Test-Path -LiteralPath $ExcelPath)) {
    throw "Excel file not found: $ExcelPath"
}

if (-not $ActivityType) { $ActivityType = Read-ActivityTypeChoice }
if ($ActivityType -eq 'Quarantine' -and -not $QuarantineRoot) {
    $QuarantineRoot = Read-RequiredPath -Prompt "Folder where quarantined items should be moved to (e.g. \\FS01\_Quarantine)" -MustExist -OfferCreate
}
if (-not $TargetDrive) {
    Write-Host ""
    $TargetDrive = Read-OptionalValue -Prompt "Optional: restrict this run to one specific drive/folder for extra safety?"
}

Write-PhaseHeader "Phase 1/3: Reading candidate list from $ExcelPath"

if (-not (Get-Module -ListAvailable -Name ImportExcel)) {
    throw "ImportExcel module not found. Install it first: Install-Module ImportExcel -Scope CurrentUser"
}
Import-Module ImportExcel

# Resolve to a concrete worksheet name up front, even if -WorksheetName
# wasn't passed. Import-Excel without -WorksheetName reads the first sheet
# by POSITION regardless of its name, but Export-Excel without
# -WorksheetName defaults to a sheet literally named "Sheet1" - on a
# multi-sheet workbook whose first sheet isn't named that, read and write
# would silently target two different sheets. Resolving once here and
# reusing it for both the read and the later write-back keeps them in sync.
$WorksheetName = if ($WorksheetName) { $WorksheetName } else { (Get-ExcelSheetInfo -Path $ExcelPath | Select-Object -First 1 -ExpandProperty Name) }

$rows = Import-Excel -Path $ExcelPath -WorksheetName $WorksheetName
Write-Host "Read $($rows.Count) rows from $ExcelPath, worksheet '$WorksheetName' (column '$PathColumn')."

$modeText = if ($Execute) { "EXECUTE - $ActivityType will really happen" } else { "DRY RUN - reporting only, nothing will be touched" }
Write-Host "Target drive : $(if ($TargetDrive) { $TargetDrive } else { '(not specified - no scope filter; quarantine anchors each item to its own share/drive root)' })"
Write-Host "Activity type: $ActivityType"
Write-Host "Mode         : $modeText"
Write-Host "Log          : $LogPath"

if ($Execute -and $ActivityType -eq 'Delete') {
    Write-Host ""
    $scopeText = if ($TargetDrive) { "under $TargetDrive" } else { "from the Excel list" }
    Write-Host "You are about to PERMANENTLY DELETE matched items $scopeText." -ForegroundColor Red
    $confirmPhrase = if ($TargetDrive) { $TargetDrive } else { "DELETE" }
    $typed = Read-Host "Type '$confirmPhrase' to confirm and continue"
    if ($typed -ne $confirmPhrase) {
        Write-Host "Confirmation text did not match. Aborting - nothing was touched." -ForegroundColor Yellow
        return
    }
}

$batchId = if ($ActivityType -eq 'Quarantine') { New-QuarantineBatchId } else { $null }
if ($batchId) { Write-Host "Quarantine batch: $batchId $(if (-not $Execute) { '(preview - dry run)' })" }

Write-PhaseHeader "Phase 2/3: Evaluating $($rows.Count) candidates"

$cutoff = if ($OlderThanYears) { (Get-Date).AddYears(-$OlderThanYears) } else { $null }
$startTime = Get-Date
$rowIndex = 0
$totalBytesSoFar = 0
$matchedCount = 0
$statusCounts = @{}
$resultRows = @()

foreach ($row in $rows) {
    $rowIndex++
    $path = $row.$PathColumn
    Write-ScanProgress -Current $rowIndex -Total $rows.Count -StartTime $startTime -CurrentItem $path

    if ([string]::IsNullOrWhiteSpace($path)) {
        Set-RowResult -Row $row -Status "SkippedNoPath"
        $resultRows += $row
        continue
    }

    # Resume check: a row already terminally actioned by a prior run is left alone.
    if ($row.CleanupStatus -in @('Deleted', 'Quarantined')) {
        $resultRows += $row
        continue
    }

    if (-not (Test-Path -LiteralPath $path)) {
        Write-GovernedLogEntry -LogPath $LogPath -Path $path -ItemType File -MatchedRule "ExcelList" -Action "Error" -ErrorMessage "Path not found"
        Set-RowResult -Row $row -Status "Error" -Detail "Path not found"
        $resultRows += $row
        continue
    }

    if ($TargetDrive -and ($path -notlike "$TargetDrive*")) {
        Set-RowResult -Row $row -Status "SkippedOutOfScope" -Detail "Not under $TargetDrive"
        $resultRows += $row
        continue
    }

    if (Test-ExcludedPath -Path $path) {
        Write-GovernedLogEntry -LogPath $LogPath -Path $path -ItemType File -MatchedRule "ExcelList" -Action "SkippedByFilter" -ErrorMessage "System-reserved path"
        Set-RowResult -Row $row -Status "SkippedSystemPath"
        $resultRows += $row
        continue
    }

    $item = Get-Item -LiteralPath $path -Force
    $itemType = if ($item.PSIsContainer) { "Folder" } else { "File" }
    $owner = Get-ItemOwner -Path $path
    $newestFile = if ($itemType -eq "Folder") { (Get-FolderStats -Path $path).NewestFile } else { $item.LastWriteTime }

    if ($cutoff -and $newestFile -and $newestFile -ge $cutoff) {
        Set-RowResult -Row $row -Status "SkippedByFilter" -Detail "Newer than -OlderThanYears cutoff"
        $resultRows += $row
        continue
    }
    if ($PathFilter -and ($path -notlike $PathFilter)) {
        Set-RowResult -Row $row -Status "SkippedByFilter" -Detail "Did not match -PathFilter"
        $resultRows += $row
        continue
    }
    if ($OwnerFilter -and ($owner -notlike $OwnerFilter)) {
        Set-RowResult -Row $row -Status "SkippedByFilter" -Detail "Did not match -OwnerFilter"
        $resultRows += $row
        continue
    }

    $result = Invoke-GovernedAction -Path $path -ItemType $itemType -ActivityType $ActivityType -MatchedRule "ExcelList" `
        -LogPath $LogPath -QuarantineRoot $QuarantineRoot -SourceRoot $TargetDrive -BatchId $batchId -Owner $owner -Execute:$Execute

    $totalBytesSoFar += $result.SizeBytes
    $matchedCount++
    $statusCounts[$result.Status] = 1 + ($(if ($statusCounts.ContainsKey($result.Status)) { $statusCounts[$result.Status] } else { 0 }))
    Set-RowResult -Row $row -Status $result.Status -Detail $result.Detail
    $resultRows += $row
}

Write-Progress -Activity "File share scan" -Completed

Write-PhaseHeader "Phase 3/3: Writing results back to Excel"
Update-ExcelWithResults -ExcelPath $ExcelPath -WorksheetName $WorksheetName -Rows $resultRows

Write-GovernedSummary -LogPath $LogPath -MatchedCount $matchedCount -TotalBytes $totalBytesSoFar -ExcelPath $ExcelPath -StatusCounts $statusCounts
if (-not $Execute) {
    Write-Host ""
    Write-Host "This was a PREVIEW (dry run) - nothing was changed. Open the Excel file and review the CleanupStatus column." -ForegroundColor Yellow
    Write-Host "When you're ready to actually $ActivityType these items for real, run this exact command again with -Execute added:" -ForegroundColor Yellow
    $nextCmd = ".\Invoke-GovernedDeletionFromExcel.ps1 -ExcelPath `"$ExcelPath`" -ActivityType $ActivityType"
    if ($QuarantineRoot) { $nextCmd += " -QuarantineRoot `"$QuarantineRoot`"" }
    if ($TargetDrive) { $nextCmd += " -TargetDrive `"$TargetDrive`"" }
    $nextCmd += " -Execute"
    Write-Host "  $nextCmd" -ForegroundColor Yellow
}
