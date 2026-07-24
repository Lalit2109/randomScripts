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
    Write-Progress bar (interactive) plus a plain status line every
    -PrintEvery items (visible in a redirected/transcript log too, where
    Write-Progress doesn't show up), used for the raw filesystem-walk phase
    where printing every single item would flood the console.
    #>
    param(
        [Parameter(Mandatory)] [int] $Current,
        [Parameter(Mandatory)] [int] $Total,
        [Parameter(Mandatory)] [datetime] $StartTime,
        [string] $CurrentItem = "",
        [int] $PrintEvery = 250
    )

    if ($Total -le 0) { return }
    $percent = [math]::Min(100, [math]::Round(($Current / $Total) * 100))
    $elapsed = (Get-Date) - $StartTime
    $etaText = if ($Current -gt 0) {
        $avgSecondsPerItem = $elapsed.TotalSeconds / $Current
        [timespan]::FromSeconds($avgSecondsPerItem * ($Total - $Current)).ToString("hh\:mm\:ss")
    }
    else { "unknown" }

    Write-Progress -Activity "File share scan" -CurrentOperation $CurrentItem `
        -Status "$Current / $Total ($percent%) - ETA $etaText" -PercentComplete $percent

    if ($Current % $PrintEvery -eq 0 -or $Current -eq $Total) {
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Scanned $Current / $Total ($percent%) - ETA $etaText"
    }
}

function Read-ActivityTypeChoice {
    <# Interactive prompt used when -ActivityType wasn't passed. No default - forces an explicit answer. #>
    while ($true) {
        $answer = Read-Host "Choose action for matched candidates - type 'Quarantine' or 'Delete'"
        if ($answer -imatch '^quarantine$') { return 'Quarantine' }
        if ($answer -imatch '^delete$') { return 'Delete' }
        Write-Host "Please type exactly 'Quarantine' or 'Delete'." -ForegroundColor Yellow
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
                                  preserving its path relative to -SourceRoot.
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
        if ($ActivityType -eq 'Quarantine' -and $QuarantineRoot -and $SourceRoot -and $BatchId) {
            $relative = Get-GovernedRelativePath -Path $Path -SourceRoot $SourceRoot
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
            if (-not $SourceRoot) { throw "SourceRoot is required when -ActivityType is 'Quarantine' (used to compute the relative path)." }
            if (-not $BatchId) { throw "BatchId is required when -ActivityType is 'Quarantine'." }

            $relative = Get-GovernedRelativePath -Path $Path -SourceRoot $SourceRoot
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
    Writes the CleanupStatus/CleanupDetail/CleanupTimestamp/CleanupBy columns
    (already added to $Rows by the caller via Add-Member) back into the same
    Excel file/worksheet the team shared, preserving every original column.
    Retries a few times in case the file is open/locked - the CSV log is the
    durable fallback if every attempt fails, so results are never lost, only
    the human-readable copy is delayed.
    #>
    param(
        [Parameter(Mandatory)] [string] $ExcelPath,
        [string] $WorksheetName,
        [Parameter(Mandatory)] [array] $Rows,
        [int] $MaxAttempts = 3
    )

    $sheetParam = if ($WorksheetName) { @{ WorksheetName = $WorksheetName } } else { @{} }

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            $Rows | Export-Excel -Path $ExcelPath -ClearSheet @sheetParam -ErrorAction Stop
            Write-ActionLine -Level Success -Message "Excel write-back complete: $ExcelPath"
            return $true
        }
        catch {
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
