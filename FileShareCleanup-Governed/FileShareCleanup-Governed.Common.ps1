<#
.SYNOPSIS
    Shared engine for the governed file-share deletion package. Dot-source
    this file from the entry-point scripts - do not run it directly.

.DESCRIPTION
    Two independent switches control every action taken by this package:

      -ActivityType   Quarantine or Delete - WHAT would happen to a match.
      -Execute        WHETHER it actually happens. Omitted (the default) =
                       dry run: every candidate is fully evaluated and
                       logged/written back to Excel exactly as a real run
                       would (status "WouldQuarantine"/"WouldDelete"), but
                       nothing on disk is touched. Passing -Execute performs
                       the chosen -ActivityType for real.

    Quarantine moves the matched item under -QuarantineRoot, preserving its
    path relative to -SourceRoot, nested under a run-dated batch folder
    (yyyy-MM-dd_HHmmss). That batch-folder naming is deliberate: it lets
    Remove-ExpiredQuarantine.ps1 age out whole batches later using nothing
    but the folder name, with no dependency on the Excel file or which
    script created the batch.

    Folders are never wiped/moved with a recursive Remove-Item/Move-Item -
    robocopy is used instead (/MIR to wipe before delete, /MOVE for
    quarantine), which is dramatically faster on folders with large file
    counts and - unlike plain PowerShell/.NET file APIs on old Windows
    Server 2008/2012 shares - natively handles paths beyond the
    260-character MAX_PATH limit.

    Every candidate, whether dry-run or executed, is written to the CSV log
    as it's evaluated - one row at a time, never buffered - so there is
    always a complete, live-updating audit trail independent of whether the
    Excel write-back succeeds.
#>

$script:EmptyMirrorDir = $null
$script:OwnerActiveCache = @{}

# Windows system-reserved folders. Never scan, quarantine, or delete these -
# touching their contents can break the Recycle Bin or VSS shadow copies/backups.
$script:SystemExcludeFolderNames = @('$RECYCLE.BIN', 'System Volume Information')

# Matches the batch-folder naming Invoke-GovernedAction creates under
# -QuarantineRoot, e.g. "2026-07-24_143201". Used by Remove-ExpiredQuarantine.ps1
# to recognize which subfolders it's allowed to touch.
$script:QuarantineBatchNamePattern = '^\d{4}-\d{2}-\d{2}_\d{6}$'

function Get-EmptyMirrorDir {
    if (-not $script:EmptyMirrorDir) {
        $script:EmptyMirrorDir = Join-Path $env:TEMP "GovernedCleanupEmpty_$([guid]::NewGuid())"
        New-Item -ItemType Directory -Path $script:EmptyMirrorDir -Force | Out-Null
    }
    return $script:EmptyMirrorDir
}

function New-QuarantineBatchId {
    (Get-Date).ToString('yyyy-MM-dd_HHmmss')
}

function Test-ExcludedPath {
    <# True if $Path is a Windows system-reserved folder, or is under one. #>
    param([Parameter(Mandatory)] [string] $Path)

    $segments = $Path -split '\\'
    foreach ($name in $script:SystemExcludeFolderNames) {
        if ($segments -contains $name) { return $true }
    }
    return $false
}

function Get-FolderStats {
    <#
    Streams the folder's file list through ForEach-Object instead of
    collecting it into an array first. A variable assignment from a pipeline
    ($files = Get-ChildItem ...) fully materializes every object in memory
    before the assignment completes - for a folder with millions of files
    that's a real risk. Piping straight into ForEach-Object lets each
    FileInfo object be garbage-collected as soon as it's counted, so memory
    stays flat regardless of file count.
    #>
    param([Parameter(Mandatory)] [string] $Path)

    $sizeBytes = [long]0
    $count = 0
    $newest = $null

    Get-ChildItem -LiteralPath $Path -File -Recurse -Force -ErrorAction SilentlyContinue |
        Where-Object { -not (Test-ExcludedPath -Path $_.FullName) } |
        ForEach-Object {
            $sizeBytes += $_.Length
            $count++
            if (-not $newest -or $_.LastWriteTime -gt $newest) { $newest = $_.LastWriteTime }
        }

    [PSCustomObject]@{
        SizeBytes  = $sizeBytes
        FileCount  = $count
        NewestFile = $newest
    }
}

function Get-ItemOwner {
    param([Parameter(Mandatory)] [string] $Path)

    try {
        return (Get-Acl -LiteralPath $Path -ErrorAction Stop).Owner
    }
    catch {
        return $null
    }
}

function Test-OwnerInactive {
    <#
    Checks whether a file's NTFS owner is a disabled AD account, caching the
    result per-owner. Many files typically share the same owner, so caching
    is what keeps this fast at scale - without it, a share with a million
    files could mean a million Get-ADUser calls instead of a few hundred
    (one per distinct owner actually encountered).
    #>
    param([string] $Owner)

    if ([string]::IsNullOrWhiteSpace($Owner)) {
        # Get-ItemOwner returns $null when Get-Acl itself failed (permissions,
        # unresolvable SID, etc.) - never auto-flagged as inactive without a
        # positive signal from AD, same as an AD lookup failure below.
        return $false
    }
    if ($script:OwnerActiveCache.ContainsKey($Owner)) {
        return $script:OwnerActiveCache[$Owner]
    }

    $samAccountName = ($Owner -split '\\')[-1]
    $inactive = $false
    try {
        $adUser = Get-ADUser -Identity $samAccountName -Properties Enabled -ErrorAction Stop
        $inactive = -not $adUser.Enabled
    }
    catch {
        # Unresolvable owner (deleted account, local account, group SID, etc.) -
        # never auto-flagged as inactive without a positive signal from AD.
        $inactive = $false
    }

    $script:OwnerActiveCache[$Owner] = $inactive
    return $inactive
}

function Get-GovernedPathRoot {
    <#
    The natural root of a path - the UNC share (\\server\share) or drive
    (C:\) it lives on. Used to compute a quarantine-relative path per item
    when no explicit -SourceRoot was given: an Excel candidate list already
    carries each item's full path, so there's no need to make an operator
    type a root up front just to anchor the relative path - it can be
    derived from the path itself.
    #>
    param([Parameter(Mandatory)] [string] $Path)

    if ($Path -match '^(\\\\[^\\]+\\[^\\]+)') { return $Matches[1] }
    if ($Path -match '^([a-zA-Z]:\\)') { return $Matches[1] }
    return $Path
}

function Get-GovernedRelativePath {
    <# Path relative to SourceRoot, used to mirror folder structure under quarantine. #>
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $SourceRoot
    )

    $normalizedRoot = $SourceRoot.TrimEnd('\')
    if ($Path.StartsWith($normalizedRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        $relative = $Path.Substring($normalizedRoot.Length).TrimStart('\')
    }
    else {
        # Path isn't under SourceRoot (e.g. an Excel row from a different share) -
        # fall back to a flattened drive/share-qualified path so it still lands
        # somewhere sane in quarantine instead of erroring out.
        $relative = ($Path -replace '^[a-zA-Z]:\\', '') -replace '^\\\\', ''
    }

    if ([string]::IsNullOrWhiteSpace($relative)) { $relative = Split-Path $Path -Leaf }
    return $relative
}

function Write-PhaseHeader {
    param([Parameter(Mandatory)] [string] $Text)

    Write-Host ""
    Write-Host ("=" * 72) -ForegroundColor Cyan
    Write-Host $Text -ForegroundColor Cyan
    Write-Host ("=" * 72) -ForegroundColor Cyan
}

function Write-ActionLine {
    <# One live console line per matched item, color-coded so run state is readable at a glance. #>
    param(
        [Parameter(Mandatory)] [ValidateSet('Success', 'DryRun', 'Warn', 'Error', 'Info')] [string] $Level,
        [Parameter(Mandatory)] [string] $Message
    )

    $color = switch ($Level) {
        'Success' { 'Green' }
        'DryRun' { 'Yellow' }
        'Warn' { 'Yellow' }
        'Error' { 'Red' }
        'Info' { 'Cyan' }
    }
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $Message" -ForegroundColor $color
}

function Write-ScanProgress {
    <#
    Write-Progress bar (interactive) plus a plain status line, both throttled
    to once every -PrintEvery items (plus always on the last item) rather
    than every single one. The plain line matters for a redirected/
    transcript log, where Write-Progress doesn't show up at all - but
    Write-Progress itself isn't free either: at hundreds of thousands of
    rows, calling it unconditionally on every iteration adds up to real,
    avoidable overhead for no visible benefit (a bar that updates every 250
    items out of 500,000 still looks perfectly smooth).
    #>
    param(
        [Parameter(Mandatory)] [int] $Current,
        [Parameter(Mandatory)] [int] $Total,
        [Parameter(Mandatory)] [datetime] $StartTime,
        [string] $CurrentItem = "",
        [int] $PrintEvery = 250,
        [string] $Activity = "File share scan",
        [string] $Verb = "Scanned"
    )

    if ($Total -le 0) { return }
    if ($Current % $PrintEvery -ne 0 -and $Current -ne $Total) { return }

    $percent = [math]::Min(100, [math]::Round(($Current / $Total) * 100))
    $elapsed = (Get-Date) - $StartTime
    $etaText = if ($Current -gt 0) {
        $avgSecondsPerItem = $elapsed.TotalSeconds / $Current
        [timespan]::FromSeconds($avgSecondsPerItem * ($Total - $Current)).ToString("hh\:mm\:ss")
    }
    else { "unknown" }

    Write-Progress -Activity $Activity -CurrentOperation $CurrentItem `
        -Status "$Current / $Total ($percent%) - ETA $etaText" -PercentComplete $percent
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $Verb $Current / $Total ($percent%) - ETA $etaText"
}

function Read-ActivityTypeChoice {
    <# Interactive prompt used when -ActivityType wasn't passed. No default - forces an explicit answer. #>
    Write-Host ""
    Write-Host "What should happen to the matched items?" -ForegroundColor Cyan
    Write-Host "  1) Quarantine - move them to a holding folder. Reversible - nothing is permanently deleted yet."
    Write-Host "  2) Delete     - permanently remove them. Cannot be undone."
    while ($true) {
        $answer = (Read-Host "Type 1 or 2 (or Quarantine / Delete)").Trim()
        if ($answer -imatch '^(1|quarantine)$') { return 'Quarantine' }
        if ($answer -imatch '^(2|delete)$') { return 'Delete' }
        Write-Host "Please type 1, 2, Quarantine, or Delete." -ForegroundColor Yellow
    }
}

function Read-RequiredPath {
    <#
    Prompts until a non-empty path is entered. Strips surrounding quotes,
    since copying a path from Windows Explorer ("Copy as path") or
    drag-and-dropping a file into the console both wrap it in quotes.
    -MustExist re-prompts until the path actually resolves; -OfferCreate
    (folders only) offers to create it instead of rejecting it.
    #>
    param(
        [Parameter(Mandatory)] [string] $Prompt,
        [switch] $MustExist,
        [switch] $OfferCreate
    )

    while ($true) {
        $value = (Read-Host $Prompt).Trim().Trim('"').Trim("'")
        if ([string]::IsNullOrWhiteSpace($value)) {
            Write-Host "A value is required." -ForegroundColor Yellow
            continue
        }
        if (-not $MustExist -or (Test-Path -LiteralPath $value)) { return $value }

        if ($OfferCreate -and (Read-YesNo -Prompt "That folder doesn't exist yet. Create it now?")) {
            New-Item -ItemType Directory -Path $value -Force | Out-Null
            return $value
        }
        Write-Host "Couldn't find that path - please check it and try again." -ForegroundColor Yellow
    }
}

function Read-OptionalValue {
    <# Prompts once; Enter with nothing typed accepts -Default (which may be empty/skip). #>
    param(
        [Parameter(Mandatory)] [string] $Prompt,
        [string] $Default = ""
    )

    $suffix = if ($Default) { " [$Default]" } else { " (press Enter to skip)" }
    $answer = (Read-Host "$Prompt$suffix").Trim().Trim('"').Trim("'")
    if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
    return $answer
}

function Read-OptionalInt {
    <# Like Read-OptionalValue, but re-prompts on anything that isn't a whole number instead of crashing. #>
    param(
        [Parameter(Mandatory)] [string] $Prompt,
        [Parameter(Mandatory)] [int] $Default
    )

    while ($true) {
        $answer = Read-OptionalValue -Prompt $Prompt -Default "$Default"
        $parsed = 0
        if ([int]::TryParse($answer, [ref] $parsed)) { return $parsed }
        Write-Host "Please enter a whole number." -ForegroundColor Yellow
    }
}

function Read-YesNo {
    param(
        [Parameter(Mandatory)] [string] $Prompt,
        [bool] $DefaultYes = $false
    )

    $suffix = if ($DefaultYes) { "[Y/n]" } else { "[y/N]" }
    while ($true) {
        $answer = (Read-Host "$Prompt $suffix").Trim()
        if ([string]::IsNullOrWhiteSpace($answer)) { return $DefaultYes }
        if ($answer -imatch '^y(es)?$') { return $true }
        if ($answer -imatch '^n(o)?$') { return $false }
        Write-Host "Please answer yes or no." -ForegroundColor Yellow
    }
}

function Resolve-GovernedWorksheetName {
    <#
    Picks a worksheet when -WorksheetName wasn't given. Does NOT just trust
    "first sheet by position" - a workbook's first tab is often a blank
    cover/instructions sheet, and reading that gives ImportExcel's own
    "does not contain any data in the row/s after the top row of '1'"
    error, which is exactly what a mis-picked empty sheet looks like.

    Checks each sheet's own Dimension (the used cell range EPPlus already
    tracks in the workbook's XML - reading it costs nothing close to
    reading actual cell data) and picks the first one whose used range
    extends past the header row. No row data is read at all here; the real,
    full read happens exactly once afterward, via Read-GovernedCandidateRows.
    #>
    param(
        [Parameter(Mandatory)] [string] $ExcelPath,
        [int] $HeaderRow = 1
    )

    $pkg = Open-ExcelPackage -Path $ExcelPath -ErrorAction Stop
    try {
        $sheets = @($pkg.Workbook.Worksheets | Sort-Object Index)
        if ($sheets.Count -eq 0) { throw "No worksheets found in $ExcelPath." }
        if ($sheets.Count -eq 1) { return $sheets[0].Name }

        Write-Host "Workbook has $($sheets.Count) sheets: $(($sheets | ForEach-Object Name) -join ', ')"
        foreach ($sheet in $sheets) {
            if ($sheet.Dimension -and $sheet.Dimension.End.Row -gt $HeaderRow) {
                Write-Host "Using sheet '$($sheet.Name)' - the first one with data. Pass -WorksheetName to point at a different one." -ForegroundColor Cyan
                return $sheet.Name
            }
        }

        throw "None of the sheets in $ExcelPath have any data rows below row $HeaderRow`: $(($sheets | ForEach-Object Name) -join ', '). Check the file, or pass -WorksheetName to point at the right one."
    }
    finally {
        Close-ExcelPackage $pkg -NoSave -ErrorAction SilentlyContinue
    }
}

function Read-GovernedCandidateRows {
    <#
    Reads just two things per data row - the -PathColumn value and the
    existing CleanupStatus value (if that column exists from a prior run) -
    via direct cell access, instead of Import-Excel's full per-cell type
    inference across every column. This package only ever needs those two
    values (the path to act on, and whether a prior run already finished
    it), so there's no reason to pay for materializing every column of
    every row into a fully-typed PSCustomObject just to read two of them.

    The real payoff: since this reads row by row under our own control,
    it can report genuine per-row progress via Write-ScanProgress (same as
    every filesystem-walk phase in this package) - something Import-Excel,
    as a single opaque blocking call, has no way to do. On a workbook with
    hundreds of thousands of rows, that's the difference between a
    console that goes silent for minutes and one that keeps showing
    "Read N / Total rows" the whole way through.
    #>
    param(
        [Parameter(Mandatory)] [string] $ExcelPath,
        [Parameter(Mandatory)] [string] $WorksheetName,
        [Parameter(Mandatory)] [string] $PathColumn,
        [int] $HeaderRow = 1
    )

    $pkg = Open-ExcelPackage -Path $ExcelPath -ErrorAction Stop
    try {
        $ws = $pkg.Workbook.Worksheets[$WorksheetName]
        if (-not $ws -or -not $ws.Dimension) {
            throw "Worksheet '$WorksheetName' has no data."
        }

        $lastCol = $ws.Dimension.End.Column
        $lastRow = $ws.Dimension.End.Row
        $pathCol = $null
        $statusCol = $null
        for ($c = 1; $c -le $lastCol; $c++) {
            $header = $ws.Cells[$HeaderRow, $c].Text
            if ($header -eq $PathColumn) { $pathCol = $c }
            if ($header -eq 'CleanupStatus') { $statusCol = $c }
        }
        if (-not $pathCol) {
            throw "Column '$PathColumn' not found in worksheet '$WorksheetName'. Pass -PathColumn to point at the right header."
        }

        $totalRows = $lastRow - $HeaderRow
        $startTime = Get-Date
        $result = [System.Collections.Generic.List[object]]::new()

        for ($r = $HeaderRow + 1; $r -le $lastRow; $r++) {
            $current = $r - $HeaderRow
            Write-ScanProgress -Current $current -Total $totalRows -StartTime $startTime `
                -CurrentItem "row $r" -Activity "Reading Excel" -Verb "Read"

            $status = if ($statusCol) { $ws.Cells[$r, $statusCol].Text } else { "" }
            $result.Add([PSCustomObject]@{
                RowNumber     = $r
                Path          = $ws.Cells[$r, $pathCol].Text
                CleanupStatus = $status
            })
        }
        Write-Progress -Activity "Reading Excel" -Completed
        return $result
    }
    finally {
        Close-ExcelPackage $pkg -NoSave -ErrorAction SilentlyContinue
    }
}

function Write-GovernedLogEntry {
    param(
        [Parameter(Mandatory)] [string] $LogPath,
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [ValidateSet("File", "Folder")] [string] $ItemType,
        [long] $SizeBytes = 0,
        [int] $FileCount = 0,
        $NewestFile = $null,
        $Owner = $null,
        [Parameter(Mandatory)] [string] $MatchedRule,
        [Parameter(Mandatory)] [string] $Action,
        [string] $Detail = "",
        [string] $ErrorMessage = ""
    )

    [PSCustomObject]@{
        Timestamp   = (Get-Date).ToString("o")
        Path        = $Path
        ItemType    = $ItemType
        SizeBytes   = $SizeBytes
        FileCount   = $FileCount
        NewestFile  = $NewestFile
        Owner       = $Owner
        MatchedRule = $MatchedRule
        Action      = $Action
        Detail      = $Detail
        ExecutedBy  = $env:USERNAME
        Error       = $ErrorMessage
    } | Export-Csv -Path $LogPath -Append -NoTypeInformation
}

function Invoke-GovernedAction {
    <#
    Central action function for both scenarios. Three real outcomes:
      - No -Execute            : fully evaluates and logs "WouldQuarantine"/
                                  "WouldDelete", touches nothing.
      - -Execute + Quarantine  : moves the item under -QuarantineRoot\-BatchId,
                                  preserving its path relative to -SourceRoot
                                  (or, if -SourceRoot wasn't given, relative
                                  to its own UNC share/drive root - see
                                  Get-GovernedPathRoot).
      - -Execute + Delete      : permanently removes the item.
    #>
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [ValidateSet('File', 'Folder')] [string] $ItemType,
        [Parameter(Mandatory)] [ValidateSet('Quarantine', 'Delete')] [string] $ActivityType,
        [Parameter(Mandatory)] [string] $MatchedRule,
        [Parameter(Mandatory)] [string] $LogPath,
        [string] $QuarantineRoot,
        [string] $SourceRoot,
        [string] $BatchId,
        $Owner = $null,
        [switch] $Execute
    )

    $stats = if ($ItemType -eq 'Folder') {
        Get-FolderStats -Path $Path
    }
    else {
        $fi = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
        [PSCustomObject]@{ SizeBytes = $fi.Length; FileCount = 1; NewestFile = $fi.LastWriteTime }
    }
    if (-not $Owner) { $Owner = Get-ItemOwner -Path $Path }
    $sizeMB = '{0:N1} MB' -f ($stats.SizeBytes / 1MB)

    if (-not $Execute) {
        # Dry run mirrors a real run's output exactly, including where a
        # quarantine WOULD land, so the preview is a true preview - not a
        # generic placeholder - of what -Execute would actually do.
        $status = if ($ActivityType -eq 'Quarantine') { 'WouldQuarantine' } else { 'WouldDelete' }
        $wouldBeDetail = ""
        if ($ActivityType -eq 'Quarantine' -and $QuarantineRoot -and $BatchId) {
            $effectiveSourceRoot = if ($SourceRoot) { $SourceRoot } else { Get-GovernedPathRoot -Path $Path }
            $relative = Get-GovernedRelativePath -Path $Path -SourceRoot $effectiveSourceRoot
            $wouldBeDetail = Join-Path (Join-Path $QuarantineRoot $BatchId) $relative
        }
        Write-GovernedLogEntry -LogPath $LogPath -Path $Path -ItemType $ItemType `
            -SizeBytes $stats.SizeBytes -FileCount $stats.FileCount -NewestFile $stats.NewestFile -Owner $Owner `
            -MatchedRule $MatchedRule -Action $status -Detail $wouldBeDetail
        $suffix = if ($wouldBeDetail) { " -> $wouldBeDetail" } else { "" }
        Write-ActionLine -Level DryRun -Message "$status  $Path$suffix  ($sizeMB, owner $Owner)"
        return [PSCustomObject]@{ Status = $status; Detail = $wouldBeDetail; SizeBytes = $stats.SizeBytes; FileCount = $stats.FileCount; Owner = $Owner; Timestamp = Get-Date }
    }

    try {
        if ($ActivityType -eq 'Quarantine') {
            if (-not $QuarantineRoot) { throw "QuarantineRoot is required when -ActivityType is 'Quarantine'." }
            if (-not $BatchId) { throw "BatchId is required when -ActivityType is 'Quarantine'." }

            # -SourceRoot is an optional safety-net scope; when it's not given,
            # each item's own UNC share/drive root anchors its relative path.
            $effectiveSourceRoot = if ($SourceRoot) { $SourceRoot } else { Get-GovernedPathRoot -Path $Path }
            $relative = Get-GovernedRelativePath -Path $Path -SourceRoot $effectiveSourceRoot
            $destination = Join-Path (Join-Path $QuarantineRoot $BatchId) $relative
            $destParent = Split-Path $destination -Parent
            if ($destParent -and -not (Test-Path -LiteralPath $destParent)) {
                New-Item -ItemType Directory -Path $destParent -Force | Out-Null
            }

            if ($ItemType -eq 'Folder') {
                robocopy $Path $destination /MOVE /E /R:1 /W:1 /NP /NFL /NDL /LOG+:"$LogPath.robocopy.log" | Out-Null
                if ($LASTEXITCODE -ge 8) { throw "robocopy failed moving folder to quarantine (exit code $LASTEXITCODE) - see $LogPath.robocopy.log" }
            }
            else {
                Move-Item -LiteralPath $Path -Destination $destination -Force
            }

            Write-GovernedLogEntry -LogPath $LogPath -Path $Path -ItemType $ItemType `
                -SizeBytes $stats.SizeBytes -FileCount $stats.FileCount -NewestFile $stats.NewestFile -Owner $Owner `
                -MatchedRule $MatchedRule -Action "Quarantined" -Detail $destination
            Write-ActionLine -Level Success -Message "QUARANTINED  $Path -> $destination  ($sizeMB, owner $Owner)"
            return [PSCustomObject]@{ Status = "Quarantined"; Detail = $destination; SizeBytes = $stats.SizeBytes; FileCount = $stats.FileCount; Owner = $Owner; Timestamp = Get-Date }
        }
        else {
            if ($ItemType -eq 'Folder') {
                $emptyDir = Get-EmptyMirrorDir
                robocopy $emptyDir $Path /MIR /R:1 /W:1 /NP /NFL /NDL /LOG+:"$LogPath.robocopy.log" | Out-Null
                if ($LASTEXITCODE -ge 8) { throw "robocopy failed wiping folder (exit code $LASTEXITCODE) - see $LogPath.robocopy.log" }
                Remove-Item -LiteralPath $Path -Force -Recurse -ErrorAction Stop
            }
            else {
                Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
            }

            Write-GovernedLogEntry -LogPath $LogPath -Path $Path -ItemType $ItemType `
                -SizeBytes $stats.SizeBytes -FileCount $stats.FileCount -NewestFile $stats.NewestFile -Owner $Owner `
                -MatchedRule $MatchedRule -Action "Deleted"
            Write-ActionLine -Level Success -Message "DELETED  $Path  ($sizeMB, owner $Owner)"
            return [PSCustomObject]@{ Status = "Deleted"; Detail = ""; SizeBytes = $stats.SizeBytes; FileCount = $stats.FileCount; Owner = $Owner; Timestamp = Get-Date }
        }
    }
    catch {
        Write-GovernedLogEntry -LogPath $LogPath -Path $Path -ItemType $ItemType `
            -SizeBytes $stats.SizeBytes -FileCount $stats.FileCount -NewestFile $stats.NewestFile -Owner $Owner `
            -MatchedRule $MatchedRule -Action "Error" -ErrorMessage $_.Exception.Message
        Write-ActionLine -Level Error -Message "ERROR  $Path : $($_.Exception.Message)"
        return [PSCustomObject]@{ Status = "Error"; Detail = $_.Exception.Message; SizeBytes = $stats.SizeBytes; FileCount = $stats.FileCount; Owner = $Owner; Timestamp = Get-Date }
    }
}

function Update-ExcelWithResults {
    <#
    Writes CleanupStatus/CleanupDetail/CleanupTimestamp/CleanupBy back into
    the SAME cells of the original candidate Excel - updating only those
    four columns, on only the rows in -RowUpdates, and never touching any
    other cell.

    This is deliberate, and replaces an earlier version of this function
    that rebuilt the whole sheet via Import-Excel + Export-Excel -ClearSheet.
    Import-Excel only captures cell VALUES, not their formatting (number
    format, date format, currency, colors, column width, ...) - so
    rebuilding the sheet from those values silently reset every column's
    original Excel formatting to ImportExcel's defaults for whatever .NET
    type each value happened to become, not just the four new columns'.
    Opening the workbook directly (Open-ExcelPackage) and writing only the
    specific cells that actually need to change leaves every other cell -
    and its formatting - completely untouched.

    -RowUpdates is an array of {RowNumber, CleanupStatus, CleanupDetail,
    CleanupTimestamp, CleanupBy}, where RowNumber is the 1-based row in the
    ACTUAL worksheet (header row + position - the caller computes this,
    since Import-Excel's result order matches the sheet's row order).
    Retries a few times in case the file is open/locked - the CSV log is
    the durable fallback if every attempt fails, so results are never
    lost, only the human-readable copy is delayed.
    #>
    param(
        [Parameter(Mandatory)] [string] $ExcelPath,
        [Parameter(Mandatory)] [string] $WorksheetName,
        [Parameter(Mandatory)] [array] $RowUpdates,
        [int] $HeaderRow = 1,
        [int] $MaxAttempts = 3
    )

    if ($RowUpdates.Count -eq 0) {
        Write-ActionLine -Level Success -Message "Nothing new to write back to Excel (no rows needed updating this run)."
        return $true
    }

    $statusColumns = @('CleanupStatus', 'CleanupDetail', 'CleanupTimestamp', 'CleanupBy')

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $pkg = $null
        try {
            $pkg = Open-ExcelPackage -Path $ExcelPath -ErrorAction Stop
            $ws = $pkg.Workbook.Worksheets[$WorksheetName]
            if (-not $ws) { throw "Worksheet '$WorksheetName' not found in $ExcelPath." }

            # Find each status column by header name if a prior run already
            # added it; otherwise append a new column after the last used one.
            $lastCol = $ws.Dimension.End.Column
            $columnMap = @{}
            for ($c = 1; $c -le $lastCol; $c++) {
                $header = $ws.Cells[$HeaderRow, $c].Text
                if ($statusColumns -contains $header) { $columnMap[$header] = $c }
            }
            foreach ($colName in $statusColumns) {
                if (-not $columnMap.ContainsKey($colName)) {
                    $lastCol++
                    $ws.Cells[$HeaderRow, $lastCol].Value = $colName
                    $columnMap[$colName] = $lastCol
                }
            }

            foreach ($update in $RowUpdates) {
                $ws.Cells[$update.RowNumber, $columnMap['CleanupStatus']].Value = $update.CleanupStatus
                $ws.Cells[$update.RowNumber, $columnMap['CleanupDetail']].Value = $update.CleanupDetail
                $ws.Cells[$update.RowNumber, $columnMap['CleanupTimestamp']].Value = $update.CleanupTimestamp
                $ws.Cells[$update.RowNumber, $columnMap['CleanupBy']].Value = $update.CleanupBy
            }

            Close-ExcelPackage $pkg -ErrorAction Stop
            Write-ActionLine -Level Success -Message "Excel write-back complete: $ExcelPath ($($RowUpdates.Count) row(s) updated)"
            return $true
        }
        catch {
            if ($pkg) { try { Close-ExcelPackage $pkg -NoSave -ErrorAction SilentlyContinue } catch { } }
            if ($attempt -ge $MaxAttempts) {
                Write-ActionLine -Level Error -Message "Excel write-back FAILED after $attempt attempt(s): $($_.Exception.Message). Results are still complete in the CSV log - close the file and re-run to retry (already-completed rows will be skipped)."
                return $false
            }
            Write-ActionLine -Level Warn -Message "Excel write-back attempt $attempt failed (file may be open) - retrying in 5s..."
            Start-Sleep -Seconds 5
        }
    }
}

function Write-GovernedSummary {
    param(
        [Parameter(Mandatory)] [string] $LogPath,
        [int] $MatchedCount = 0,
        [long] $TotalBytes = 0,
        [string] $ExcelPath = "",
        [hashtable] $StatusCounts = @{}
    )

    $totalGB = [math]::Round($TotalBytes / 1GB, 2)
    Write-PhaseHeader "Summary"
    Write-Host "Matched items : $MatchedCount"
    Write-Host "Total size    : $totalGB GB"
    foreach ($key in $StatusCounts.Keys) {
        Write-Host ("  {0,-18}: {1}" -f $key, $StatusCounts[$key])
    }
    Write-Host "CSV log       : $LogPath"
    if ($ExcelPath) { Write-Host "Excel updated : $ExcelPath" }
}
