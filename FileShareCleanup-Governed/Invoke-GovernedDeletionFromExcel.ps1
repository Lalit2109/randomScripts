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

    -ThrottleLimit (default 1 = sequential, exactly today's behavior) runs
    that many rows at once via ForEach-Object -Parallel - needs PowerShell 7+.
    Worth reaching for on a large list: the per-row cost here is almost
    entirely waiting on the file server (Test-Path/Get-Acl/move/delete over
    a UNC path), not CPU, so several of those waits in flight at once is a
    close-to-linear speedup rather than something fighting over one CPU
    core. CSV log writes are synchronized (a shared Mutex) so concurrent
    rows can never corrupt the log; the Excel write-back still happens once,
    after every row is done, exactly as in sequential mode. Start modest
    (8-16) and watch how the file server copes before pushing higher - too
    many at once can just as easily make things slower by overloading it.

.EXAMPLE
    # Fully interactive - asks for everything it needs, one question at a time
    .\Invoke-GovernedDeletionFromExcel.ps1

.EXAMPLE
    # Large list: process 10 rows at a time instead of one at a time (needs PowerShell 7+)
    .\Invoke-GovernedDeletionFromExcel.ps1 -ExcelPath ".\candidates.xlsx" `
        -ActivityType Delete -ThrottleLimit 10 -Execute

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
    [string] $LogPath = ".\governed-cleanup-from-excel-$(Get-Date -Format yyyyMMdd-HHmmss).csv",
    [int] $ThrottleLimit = 1
)

. (Join-Path $PSScriptRoot "FileShareCleanup-Governed.Common.ps1")

if ($ThrottleLimit -gt 1 -and $PSVersionTable.PSVersion.Major -lt 7) {
    throw "-ThrottleLimit > 1 needs PowerShell 7 or later (it uses ForEach-Object -Parallel). This session is running $($PSVersionTable.PSVersion) - install PowerShell 7, or omit -ThrottleLimit (or pass -ThrottleLimit 1) to run sequentially, exactly as before."
}
if ($ThrottleLimit -gt 32) {
    Write-Host "-ThrottleLimit $ThrottleLimit is high - that's a lot of simultaneous connections to the file server. Start lower (e.g. 8-16) and watch how the server copes before pushing it higher." -ForegroundColor Yellow
}

$HeaderRow = 1
# List[object] of {RowNumber, CleanupStatus, CleanupDetail, CleanupTimestamp,
# CleanupBy} - NOT full row objects. Update-ExcelWithResults writes only
# these specific cells directly into the workbook, so it never has to
# rebuild (and inadvertently reformat) the rest of the sheet. Rows already
# terminally actioned by a prior run don't get an update entry at all -
# their cells are already correct, so there's nothing to touch.
$rowUpdates = [System.Collections.Generic.List[object]]::new()
$matchedCount = 0
$totalBytesSoFar = 0
$statusCounts = @{}

function Save-RowResult {
    <#
    Folds one Invoke-GovernedRowEvaluation result into the running
    Excel-update list and summary tallies. Called from the main thread
    only - either directly per-row in sequential mode, or once per
    collected result after a parallel run completes - never from inside a
    ForEach-Object -Parallel scriptblock itself.
    #>
    param($EvalResult)
    if (-not $EvalResult) { return }

    $rowUpdates.Add([PSCustomObject]@{
        RowNumber        = $EvalResult.RowNumber
        CleanupStatus    = $EvalResult.ExcelStatus
        CleanupDetail    = $EvalResult.ExcelDetail
        CleanupTimestamp = (Get-Date).ToString("o")
        CleanupBy        = $env:USERNAME
    })

    if ($EvalResult.ActionStatus) {
        $script:matchedCount++
        $script:totalBytesSoFar += $EvalResult.SizeBytes
        $prior = if ($script:statusCounts.ContainsKey($EvalResult.ActionStatus)) { $script:statusCounts[$EvalResult.ActionStatus] } else { 0 }
        $script:statusCounts[$EvalResult.ActionStatus] = $prior + 1
    }
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

Write-PhaseHeader "Phase 2/3: Evaluating $($rows.Count) candidates$(if ($ThrottleLimit -gt 1) { " (up to $ThrottleLimit at a time)" })"

$cutoff = if ($OlderThanYears) { (Get-Date).AddYears(-$OlderThanYears) } else { $null }
$startTime = Get-Date

if ($ThrottleLimit -le 1) {
    $rowIndex = 0
    foreach ($row in $rows) {
        $rowIndex++
        Write-ScanProgress -Current $rowIndex -Total $rows.Count -StartTime $startTime -CurrentItem $row.Path `
            -Activity "Evaluating candidates" -Verb "Evaluated"
        $evalResult = Invoke-GovernedRowEvaluation -Row $row -ActivityType $ActivityType -LogPath $LogPath `
            -QuarantineRoot $QuarantineRoot -TargetDrive $TargetDrive -BatchId $batchId -Cutoff $cutoff `
            -PathFilter $PathFilter -OwnerFilter $OwnerFilter -Execute:$Execute
        Save-RowResult -EvalResult $evalResult
    }
    Write-Progress -Activity "Evaluating candidates" -Completed
}
else {
    # Same per-row logic as the sequential branch (Invoke-GovernedRowEvaluation,
    # in the common engine both branches dot-source), run across several
    # runspaces at once. This helps because the per-row cost here is almost
    # entirely waiting on the file server (Test-Path/Get-Acl/move/delete over
    # a UNC path), not CPU - so several of those waits in flight at once is a
    # close-to-linear speedup, not something fighting over a shared resource.
    #
    # -LogMutex (a single Mutex object shared into every runspace via $using:)
    # serializes CSV log appends so concurrent writes can't corrupt the file;
    # Invoke-GovernedRowEvaluation's own results go into a ConcurrentBag,
    # which is safe for many threads to .Add() to at once, then get folded
    # into the real running totals back on the main thread afterward - never
    # from inside the parallel scriptblock itself.
    $csvMutex = [System.Threading.Mutex]::new($false)
    $commonScriptPath = Join-Path $PSScriptRoot "FileShareCleanup-Governed.Common.ps1"
    $parallelResults = [System.Collections.Concurrent.ConcurrentBag[object]]::new()

    $rows | ForEach-Object -Parallel {
        $row = $_
        # Dot-source once per runspace, not once per item: functions defined
        # in one invocation persist for the rest of that runspace's work, so
        # this only actually runs up to -ThrottleLimit times, not per-row.
        if (-not (Get-Command Invoke-GovernedRowEvaluation -ErrorAction SilentlyContinue)) {
            . $using:commonScriptPath
        }

        $evalResult = Invoke-GovernedRowEvaluation -Row $row -ActivityType $using:ActivityType -LogPath $using:LogPath `
            -QuarantineRoot $using:QuarantineRoot -TargetDrive $using:TargetDrive -BatchId $using:batchId -Cutoff $using:cutoff `
            -PathFilter $using:PathFilter -OwnerFilter $using:OwnerFilter -Execute:$using:Execute -LogMutex $using:csvMutex

        if ($evalResult) { ($using:parallelResults).Add($evalResult) }

        $doneCount = ($using:parallelResults).Count
        $totalCount = ($using:rows).Count
        if ($doneCount % 250 -eq 0 -or $doneCount -eq $totalCount) {
            $elapsed = (Get-Date) - $using:startTime
            $rate = if ($elapsed.TotalSeconds -gt 0) { [math]::Round($doneCount / $elapsed.TotalSeconds, 1) } else { 0 }
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Evaluated $doneCount / $totalCount candidates (~$rate/sec)"
        }
    } -ThrottleLimit $ThrottleLimit

    foreach ($evalResult in $parallelResults) {
        Save-RowResult -EvalResult $evalResult
    }
}

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
    if ($ThrottleLimit -gt 1) { $nextCmd += " -ThrottleLimit $ThrottleLimit" }
    $nextCmd += " -Execute"
    Write-Host "  $nextCmd" -ForegroundColor Yellow
}
