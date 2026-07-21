<#
.SYNOPSIS
    Shared engine used by Remove-OldFilesByAge.ps1 and Remove-FilesFromExcelList.ps1.
    Dot-source this file from both - do not run it directly.

.DESCRIPTION
    Deletion approach and why:
      - Individual files  : Remove-Item (HardDelete) or Move-Item (Quarantine).
      - Whole folders     : NOT Remove-Item -Recurse. Robocopy is used instead:
          HardDelete : robocopy <empty-temp-dir> <target> /MIR
                       (wipes the folder's contents), then Remove-Item the
                       now-empty folder.
          Quarantine : robocopy <target> <quarantine-dest> /MOVE /E
                       (moves the whole tree, removing the source once copied).
        Robocopy is dramatically faster than recursive Remove-Item on folders
        with large file counts, and - unlike plain PowerShell/.NET file APIs
        on Windows Server 2008/2012 - it natively handles paths beyond the
        260-character MAX_PATH limit, which is a real risk on old, deeply
        nested file shares.

    Every candidate (whether dry-run or executed) is written to the CSV log,
    so there is always a full audit trail of what was found and what
    happened to it.
#>

$script:EmptyMirrorDir = $null

# Windows system-reserved folders. Never scan or touch these: deleting/moving
# their contents can break the Recycle Bin or VSS shadow copies/backups.
# This list is intentionally not user-configurable.
$script:SystemExcludeFolderNames = @('$RECYCLE.BIN', 'System Volume Information')

# Common junk/lock files safe to remove regardless of age, used by -RemoveJunkFiles.
$script:JunkFileNames = @('Thumbs.db', 'desktop.ini', '.DS_Store', 'ehthumbs.db')
$script:JunkFilePatterns = @('~$*.tmp', '~$*.doc*', '~$*.xls*', '~$*.ppt*')

function Get-EmptyMirrorDir {
    if (-not $script:EmptyMirrorDir) {
        $script:EmptyMirrorDir = Join-Path $env:TEMP "RobocopyEmpty_$([guid]::NewGuid())"
        New-Item -ItemType Directory -Path $script:EmptyMirrorDir -Force | Out-Null
    }
    return $script:EmptyMirrorDir
}

function Test-ExcludedPath {
    <#
    True if $Path is a Windows system-reserved folder (or under one), or is
    inside -QuarantineRoot. The latter matters because -QuarantineRoot is
    often placed inside the same share being cleaned (e.g. \Projects\_ToBeDeleted
    under \Projects) - without this, a second run would rescan and re-flag
    files that are already quarantined.
    #>
    param(
        [Parameter(Mandatory)] [string] $Path,
        [string] $QuarantineRoot
    )

    $segments = $Path -split '\\'
    foreach ($name in $script:SystemExcludeFolderNames) {
        if ($segments -contains $name) { return $true }
    }

    if ($QuarantineRoot -and $Path.StartsWith($QuarantineRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }

    return $false
}

function Test-JunkFileMatch {
    param([Parameter(Mandatory)] [string] $FileName)

    if ($script:JunkFileNames -contains $FileName) { return $true }
    foreach ($pattern in $script:JunkFilePatterns) {
        if ($FileName -like $pattern) { return $true }
    }
    return $false
}

function Get-FolderStats {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [string] $QuarantineRoot
    )

    $files = Get-ChildItem -LiteralPath $Path -File -Recurse -Force -ErrorAction SilentlyContinue |
        Where-Object { -not (Test-ExcludedPath -Path $_.FullName -QuarantineRoot $QuarantineRoot) }
    $agg = $files | Measure-Object -Property Length -Sum
    $newest = ($files | Sort-Object LastWriteTime -Descending | Select-Object -First 1).LastWriteTime

    [PSCustomObject]@{
        SizeBytes  = if ($agg.Sum) { $agg.Sum } else { 0 }
        FileCount  = $agg.Count
        NewestFile = $newest
    }
}

function Test-ExtensionMatch {
    param(
        [Parameter(Mandatory)] [string] $FileName,
        [Parameter(Mandatory)] [string[]] $Extensions
    )

    $ext = [System.IO.Path]::GetExtension($FileName).TrimStart('.')
    return $Extensions -contains $ext
}

function Test-FileCriteriaMatch {
    <#
    AND-combines whichever of Extensions / Cutoff (age) / MinSizeBytes were
    actually supplied - each is skipped if not given. Returns $false if NONE
    of the three were given, since there'd be nothing to match on.
    #>
    param(
        [Parameter(Mandatory)] $File,
        [string[]] $Extensions,
        [Nullable[datetime]] $Cutoff,
        [Nullable[long]] $MinSizeBytes
    )

    if (-not $Extensions -and -not $Cutoff -and -not $MinSizeBytes) { return $false }
    if ($Extensions -and -not (Test-ExtensionMatch -FileName $File.Name -Extensions $Extensions)) { return $false }
    if ($Cutoff -and $File.LastWriteTime -ge $Cutoff) { return $false }
    if ($MinSizeBytes -and $File.Length -lt $MinSizeBytes) { return $false }

    return $true
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

function Test-MatchesFilters {
    <#
    Combines the Path / Owner / Age filters with AND logic. Any filter left
    unset ($null/empty) is skipped, so passing none of them matches everything.
    #>
    param(
        [Parameter(Mandatory)] [string] $Path,
        $NewestFile,
        $Owner,
        [string] $PathFilter,
        [string] $OwnerFilter,
        [Nullable[datetime]] $OlderThanDate
    )

    if ($PathFilter -and ($Path -notlike $PathFilter)) { return $false }
    if ($OwnerFilter -and ($Owner -notlike $OwnerFilter)) { return $false }
    if ($OlderThanDate -and $NewestFile -and ($NewestFile -ge $OlderThanDate)) { return $false }

    return $true
}

function Write-CleanupLogEntry {
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
        ExecutedBy  = $env:USERNAME
        Error       = $ErrorMessage
    } | Export-Csv -Path $LogPath -Append -NoTypeInformation
}

function Invoke-CleanupAction {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [ValidateSet("File", "Folder")] [string] $ItemType,
        [Parameter(Mandatory)] [string] $MatchedRule,
        [Parameter(Mandatory)] [ValidateSet("HardDelete", "Quarantine")] [string] $Mode,
        [string] $QuarantineRoot,
        [Parameter(Mandatory)] [string] $SourceRoot,
        [Parameter(Mandatory)] [string] $LogPath,
        $Owner = $null,
        [switch] $Execute
    )

    $stats = if ($ItemType -eq "Folder") {
        Get-FolderStats -Path $Path -QuarantineRoot $QuarantineRoot
    }
    else {
        $fi = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
        [PSCustomObject]@{ SizeBytes = $fi.Length; FileCount = 1; NewestFile = $fi.LastWriteTime }
    }

    if (-not $Owner) { $Owner = Get-ItemOwner -Path $Path }

    if (-not $Execute) {
        $action = if ($Mode -eq "Quarantine") { "WouldQuarantine" } else { "WouldDelete" }
        Write-CleanupLogEntry -LogPath $LogPath -Path $Path -ItemType $ItemType `
            -SizeBytes $stats.SizeBytes -FileCount $stats.FileCount -NewestFile $stats.NewestFile -Owner $Owner `
            -MatchedRule $MatchedRule -Action $action
        return $stats
    }

    try {
        if ($Mode -eq "Quarantine") {
            $relative = $Path.Substring($SourceRoot.Length).TrimStart('\')
            $destination = Join-Path $QuarantineRoot $relative
            New-Item -ItemType Directory -Path (Split-Path $destination -Parent) -Force | Out-Null

            if ($ItemType -eq "Folder") {
                robocopy $Path $destination /MOVE /E /R:1 /W:1 /NP /NFL /NDL /LOG+:"$LogPath.robocopy.log" | Out-Null
                if ($LASTEXITCODE -ge 8) { throw "robocopy failed with exit code $LASTEXITCODE" }
            }
            else {
                Move-Item -LiteralPath $Path -Destination $destination -Force
            }
            $action = "Quarantined"
        }
        else {
            if ($ItemType -eq "Folder") {
                $emptyDir = Get-EmptyMirrorDir
                robocopy $emptyDir $Path /MIR /R:1 /W:1 /NP /NFL /NDL /LOG+:"$LogPath.robocopy.log" | Out-Null
                if ($LASTEXITCODE -ge 8) { throw "robocopy failed with exit code $LASTEXITCODE" }
                Remove-Item -LiteralPath $Path -Force -Recurse -ErrorAction Stop
            }
            else {
                Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
            }
            $action = "Deleted"
        }

        Write-CleanupLogEntry -LogPath $LogPath -Path $Path -ItemType $ItemType `
            -SizeBytes $stats.SizeBytes -FileCount $stats.FileCount -NewestFile $stats.NewestFile -Owner $Owner `
            -MatchedRule $MatchedRule -Action $action
    }
    catch {
        Write-CleanupLogEntry -LogPath $LogPath -Path $Path -ItemType $ItemType `
            -SizeBytes $stats.SizeBytes -FileCount $stats.FileCount -NewestFile $stats.NewestFile -Owner $Owner `
            -MatchedRule $MatchedRule -Action "Error" -ErrorMessage $_.Exception.Message
        Write-Warning "Failed on $Path : $($_.Exception.Message)"
    }

    return $stats
}

function Write-CleanupSummary {
    param([Parameter(Mandatory)] [string] $LogPath)

    if (-not (Test-Path $LogPath)) { return }
    $rows = Import-Csv $LogPath
    $totalGB = [math]::Round((($rows | Measure-Object -Property SizeBytes -Sum).Sum) / 1GB, 2)
    Write-Host "`nSummary: $($rows.Count) items matched, totaling $totalGB GB. Full detail in $LogPath."
}

function Write-CleanupProgress {
    <#
    Prints a live console progress bar (Write-Progress) plus a plain status
    line every 25 items / at completion, so progress is visible both in an
    interactive session and in a redirected/transcript log from an
    unattended overnight run (Write-Progress itself doesn't show up there).
    #>
    param(
        [Parameter(Mandatory)] [int] $Current,
        [Parameter(Mandatory)] [int] $Total,
        [Parameter(Mandatory)] [datetime] $StartTime,
        [string] $CurrentItem = "",
        [long] $BytesSoFar = 0
    )

    if ($Total -eq 0) { return }
    $percent = [math]::Min(100, [math]::Round(($Current / $Total) * 100))
    $elapsed = (Get-Date) - $StartTime
    $etaText = if ($Current -gt 0) {
        $avgSecondsPerItem = $elapsed.TotalSeconds / $Current
        [timespan]::FromSeconds($avgSecondsPerItem * ($Total - $Current)).ToString("hh\:mm\:ss")
    }
    else { "unknown" }

    Write-Progress -Activity "File share cleanup" -CurrentOperation $CurrentItem `
        -Status "$Current / $Total items ($percent%) - ETA $etaText" -PercentComplete $percent

    if ($Current % 25 -eq 0 -or $Current -eq $Total) {
        $gb = [math]::Round($BytesSoFar / 1GB, 2)
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $Current / $Total ($percent%) - $gb GB matched so far - ETA $etaText"
    }
}
