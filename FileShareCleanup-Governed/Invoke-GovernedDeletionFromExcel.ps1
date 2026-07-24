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
    Install-Module ImportExcel, no Excel/Office installation required),
    row by row with live progress ("Read N / Total rows") rather than one
    single opaque blocking call - matters on a workbook with hundreds of
    thousands of rows, where a plain Import-Excel read can otherwise sit
    with zero console output for minutes. Each row may point at either a
    single file or a whole folder - both are handled, determined per-row
    via Get-Item/.PSIsContainer.

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

    The write-back only ever touches the four CleanupStatus/CleanupDetail/
    CleanupTimestamp/CleanupBy cells for rows actually processed this run -
    it opens the workbook directly and edits those specific cells rather
    than reading everything into memory and rewriting the whole sheet, so
    every other column keeps its original Excel formatting (number/date
    formats, currency, column widths, etc.) exactly as the team set it up.

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

$HeaderRow = 1
# List[object] of {RowNumber, CleanupStatus, CleanupDetail, CleanupTimestamp,
# CleanupBy} - NOT full row objects. Update-ExcelWithResults writes only
# these specific cells directly into the workbook, so it never has to
# rebuild (and inadvertently reformat) the rest of the sheet. Rows already
# terminally actioned by a prior run don't get an update entry at all -
# their cells are already correct, so there's nothing to touch.
$rowUpdates = [System.Collections.Generic.List[object]]::new()

function Add-RowUpdate {
    param([Parameter(Mandatory)] [int] $RowNumber, [Parameter(Mandatory)] [string] $Status, [string] $Detail = "")
    $script:rowUpdates.Add([PSCustomObject]@{
        RowNumber        = $RowNumber
        CleanupStatus    = $Status
        CleanupDetail    = $Detail
        CleanupTimestamp = (Get-Date).ToString("o")
        CleanupBy        = $env:USERNAME
    })
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
# wasn't passed - and, importantly, to one that actually HAS data (see
# Resolve-GovernedWorksheetName; a blind "first sheet by position" pick
# breaks as soon as that first sheet is an empty cover/instructions tab).
# Reads and the write-back both use this same resolved name, so they can
# never end up targeting two different sheets.
$WorksheetName = if ($WorksheetName) { $WorksheetName } else { Resolve-GovernedWorksheetName -ExcelPath $ExcelPath -HeaderRow $HeaderRow }

try {
    # Read-GovernedCandidateRows, not Import-Excel: this package only ever
    # needs a row's path and its existing CleanupStatus, and reading just
    # those two per row (with real progress reporting) is both faster and
    # far more informative than Import-Excel's single opaque blocking call
    # across every column of a workbook that can run into the hundreds of
    # thousands of rows.
    $rows = Read-GovernedCandidateRows -ExcelPath $ExcelPath -WorksheetName $WorksheetName -PathColumn $PathColumn -HeaderRow $HeaderRow
}
catch {
    throw "Could not read data from worksheet '$WorksheetName' in $ExcelPath - it may be empty (no rows below the header), or the column '$PathColumn' may not exist on it. Open the file and confirm the candidate list is really on that sheet, or re-run with -WorksheetName/-PathColumn pointing at the right place. Original error: $($_.Exception.Message)"
}
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

foreach ($row in $rows) {
    $rowIndex++
    $path = $row.Path
    Write-ScanProgress -Current $rowIndex -Total $rows.Count -StartTime $startTime -CurrentItem $path `
        -Activity "Evaluating candidates" -Verb "Evaluated"

    if ([string]::IsNullOrWhiteSpace($path)) {
        Add-RowUpdate -RowNumber $row.RowNumber -Status "SkippedNoPath"
        continue
    }

    # Resume check: a row already terminally actioned by a prior run is left
    # alone entirely - its cells are already correct, nothing to rewrite.
    if ($row.CleanupStatus -in @('Deleted', 'Quarantined')) {
        continue
    }

    if (-not (Test-Path -LiteralPath $path)) {
        Write-GovernedLogEntry -LogPath $LogPath -Path $path -ItemType File -MatchedRule "ExcelList" -Action "Error" -ErrorMessage "Path not found"
        Add-RowUpdate -RowNumber $row.RowNumber -Status "Error" -Detail "Path not found"
        continue
    }

    if ($TargetDrive -and ($path -notlike "$TargetDrive*")) {
        Add-RowUpdate -RowNumber $row.RowNumber -Status "SkippedOutOfScope" -Detail "Not under $TargetDrive"
        continue
    }

    if (Test-ExcludedPath -Path $path) {
        Write-GovernedLogEntry -LogPath $LogPath -Path $path -ItemType File -MatchedRule "ExcelList" -Action "SkippedByFilter" -ErrorMessage "System-reserved path"
        Add-RowUpdate -RowNumber $row.RowNumber -Status "SkippedSystemPath"
        continue
    }

    $item = Get-Item -LiteralPath $path -Force
    $itemType = if ($item.PSIsContainer) { "Folder" } else { "File" }
    $owner = Get-ItemOwner -Path $path
    $newestFile = if ($itemType -eq "Folder") { (Get-FolderStats -Path $path).NewestFile } else { $item.LastWriteTime }

    if ($cutoff -and $newestFile -and $newestFile -ge $cutoff) {
        Add-RowUpdate -RowNumber $row.RowNumber -Status "SkippedByFilter" -Detail "Newer than -OlderThanYears cutoff"
        continue
    }
    if ($PathFilter -and ($path -notlike $PathFilter)) {
        Add-RowUpdate -RowNumber $row.RowNumber -Status "SkippedByFilter" -Detail "Did not match -PathFilter"
        continue
    }
    if ($OwnerFilter -and ($owner -notlike $OwnerFilter)) {
        Add-RowUpdate -RowNumber $row.RowNumber -Status "SkippedByFilter" -Detail "Did not match -OwnerFilter"
        continue
    }

    $result = Invoke-GovernedAction -Path $path -ItemType $itemType -ActivityType $ActivityType -MatchedRule "ExcelList" `
        -LogPath $LogPath -QuarantineRoot $QuarantineRoot -SourceRoot $TargetDrive -BatchId $batchId -Owner $owner -Execute:$Execute

    $totalBytesSoFar += $result.SizeBytes
    $matchedCount++
    $statusCounts[$result.Status] = 1 + ($(if ($statusCounts.ContainsKey($result.Status)) { $statusCounts[$result.Status] } else { 0 }))
    Add-RowUpdate -RowNumber $row.RowNumber -Status $result.Status -Detail $result.Detail
}

Write-Progress -Activity "Evaluating candidates" -Completed

Write-PhaseHeader "Phase 3/3: Writing results back to Excel"
Update-ExcelWithResults -ExcelPath $ExcelPath -WorksheetName $WorksheetName -RowUpdates $rowUpdates.ToArray() -HeaderRow $HeaderRow

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
