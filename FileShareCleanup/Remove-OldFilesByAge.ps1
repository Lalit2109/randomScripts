<#
.SYNOPSIS
    Finds - and optionally removes - old/junk/oversized content under one or
    more file share paths on its own criteria. No Excel input needed.

.DESCRIPTION
    Independent criteria, all optional except -TargetPath:
      1. Folders       - only runs if -OlderThanYears is supplied. Every
                         immediate subfolder under each -TargetPath is a
                         candidate; it qualifies if the newest LastWriteTime
                         of ANY file inside it (recursively) is older than
                         -OlderThanYears. Avoids relying on the folder's own
                         timestamp, which gets touched by unrelated
                         scans/backups and isn't a reliable signal.
      2. Empty folders - only runs with -IncludeEmptyFolders. A folder with
                         zero files anywhere in its tree qualifies. If
                         -OlderThanYears is also given, the folder's own
                         LastWriteTime must additionally predate it (safety
                         net so a folder created five minutes ago isn't
                         swept just because it's still empty).
      3. Zero-byte      - matched independently, anywhere under -TargetPath,
         files            regardless of age. Runs by default; disable with
                         -SkipZeroByteFiles.
      4. Junk files     - only runs with -RemoveJunkFiles. Matches common
                         OS/app litter (Thumbs.db, desktop.ini, .DS_Store,
                         Office ~$ lock files) regardless of age.
      5. Extension /    - if -Extensions is supplied, only files matching one
         age / size       of those extensions qualify. If -OlderThanYears
                         and/or -MinSizeMB are ALSO given, they're additional
                         AND conditions. If -Extensions is NOT supplied but
                         -OlderThanYears and/or -MinSizeMB are, that criterion
                         alone applies to every file regardless of extension.
                         Examples: age alone = "any old file"; size alone =
                         "any large file"; extensions alone = "this type
                         regardless of age/size"; combine any of the three
                         for an AND match.

    Rules 3-5 share a single recursive file scan per -TargetPath (rather than
    walking a multi-TB tree more than once).

    Built-in safety exclusions (not configurable): Windows system-reserved
    folders ($RECYCLE.BIN, System Volume Information) are never scanned or
    touched, and anything already under -QuarantineRoot is skipped so a
    second run doesn't re-flag files it already quarantined.

    Note: Rule 1 (whole folders) and Rule 5 (individual old files, when run
    without -Extensions) can overlap - a folder where every file is old will
    be reported once by Rule 1 AND once per file by Rule 5 in a dry run, so
    the summary GB total can look inflated. In an -Execute run this is
    harmless (Rule 1 removes the folder first, so Rule 5 finds nothing left
    there), but it's worth knowing when reading a dry-run report.

    Additional narrowing filters (all optional, combined with AND):
      -PathFilter  wildcard match against the full path, e.g. "*\Archive\*"
      -OwnerFilter wildcard match against the NTFS owner, e.g. "CONTOSO\jsmith"

    Safe by default: without -Execute, this ONLY writes a CSV report of what
    WOULD be deleted/quarantined - nothing on disk is touched. Review the
    report, then re-run with -Execute to actually perform the action.

    Run this from a modern admin/jump host against the share's UNC path
    (e.g. \\FS01\Projects), not locally on the old 2008/2012 server itself -
    those OS versions ship old PowerShell (2.0 / 3.0) that lacks features
    this script and robocopy's long-path handling depend on.

.EXAMPLE
    # Dry run - produces a report only
    .\Remove-OldFilesByAge.ps1 -TargetPath "\\FS01\Projects" -OlderThanYears 7

.EXAMPLE
    # Real run, quarantine (default) so it can be purged after a grace period
    .\Remove-OldFilesByAge.ps1 -TargetPath "\\FS01\Projects" -OlderThanYears 7 `
        -QuarantineRoot "\\FS01\_ToBeDeleted" -Execute

.EXAMPLE
    # Real run, permanent delete instead of quarantine
    .\Remove-OldFilesByAge.ps1 -TargetPath "\\FS01\Projects" -OlderThanYears 7 `
        -Mode HardDelete -Execute

.EXAMPLE
    # Only touch a specific sub-path, owned by a specific (e.g. departed) user
    .\Remove-OldFilesByAge.ps1 -TargetPath "\\FS01\Projects" -OlderThanYears 7 `
        -PathFilter "*\Archive\*" -OwnerFilter "CONTOSO\jsmith"

.EXAMPLE
    # Also clear out .jar and .html files older than 7 years, anywhere under the target
    .\Remove-OldFilesByAge.ps1 -TargetPath "\\FS01\Projects" -OlderThanYears 7 `
        -Extensions jar, html -QuarantineRoot "\\FS01\_ToBeDeleted" -Execute

.EXAMPLE
    # Delete by extension only, no age condition, no folder-age rule
    .\Remove-OldFilesByAge.ps1 -TargetPath "\\FS01\Projects" `
        -Extensions jar, html -QuarantineRoot "\\FS01\_ToBeDeleted" -Execute

.EXAMPLE
    # Age only, no extension filter: delete any individual file older than 7 years
    .\Remove-OldFilesByAge.ps1 -TargetPath "\\FS01\Projects" -OlderThanYears 7 `
        -QuarantineRoot "\\FS01\_ToBeDeleted" -Execute

.EXAMPLE
    # Space hogs: any file over 500 MB, regardless of age or type
    .\Remove-OldFilesByAge.ps1 -TargetPath "\\FS01\Projects" -MinSizeMB 500 `
        -QuarantineRoot "\\FS01\_ToBeDeleted" -Execute

.EXAMPLE
    # Leftover empty folders (7+ years untouched) plus OS/app junk files
    .\Remove-OldFilesByAge.ps1 -TargetPath "\\FS01\Projects" -OlderThanYears 7 `
        -IncludeEmptyFolders -RemoveJunkFiles -QuarantineRoot "\\FS01\_ToBeDeleted" -Execute
#>

param(
    [Parameter(Mandatory)] [string[]] $TargetPath,
    [int] $OlderThanYears,
    [switch] $SkipZeroByteFiles,
    [string[]] $Extensions,
    [double] $MinSizeMB,
    [switch] $IncludeEmptyFolders,
    [switch] $RemoveJunkFiles,

    [string] $PathFilter,
    [string] $OwnerFilter,

    [ValidateSet("HardDelete", "Quarantine")]
    [string] $Mode = "Quarantine",
    [string] $QuarantineRoot,

    [switch] $Execute,
    [string] $LogPath = ".\cleanup-by-age-$(Get-Date -Format yyyyMMdd-HHmmss).csv"
)

. (Join-Path $PSScriptRoot "FileShareCleanup.Common.ps1")

if ($Execute -and $Mode -eq "Quarantine" -and -not $QuarantineRoot) {
    throw "-QuarantineRoot is required when -Mode is Quarantine and -Execute is set."
}

if (-not $OlderThanYears -and -not $Extensions -and -not $MinSizeMB -and -not $IncludeEmptyFolders -and -not $RemoveJunkFiles -and $SkipZeroByteFiles) {
    throw "Nothing to do: supply -OlderThanYears, -Extensions, -MinSizeMB, -IncludeEmptyFolders, -RemoveJunkFiles, and/or leave zero-byte scanning enabled."
}

$cutoff = if ($OlderThanYears) { (Get-Date).AddYears(-$OlderThanYears) } else { $null }
$minSizeBytes = if ($MinSizeMB) { [long]($MinSizeMB * 1MB) } else { $null }

if ($cutoff) {
    Write-Host "Cutoff date: items with no activity since before $($cutoff.ToString('yyyy-MM-dd')) qualify."
}
else {
    Write-Host "No -OlderThanYears given: folder-age rule is skipped, and other age-aware criteria are not age-gated."
}
Write-Host "Mode: $Mode | Execute: $($Execute.IsPresent) | Log: $LogPath"

$startTime = Get-Date
$totalBytesSoFar = 0

foreach ($root in $TargetPath) {

    # --- Rules 1 & 2: whole-folder age rule, and/or completely empty folders ---
    if ($cutoff -or $IncludeEmptyFolders) {
        $candidates = @(Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue |
            Where-Object { -not (Test-ExcludedPath -Path $_.FullName -QuarantineRoot $QuarantineRoot) })
        Write-Host "`n$root : evaluating $($candidates.Count) candidate folders..."
        $i = 0
        foreach ($folder in $candidates) {
            $i++
            $stats = Get-FolderStats -Path $folder.FullName -QuarantineRoot $QuarantineRoot
            $owner = Get-ItemOwner -Path $folder.FullName

            if ($IncludeEmptyFolders -and $stats.FileCount -eq 0 -and (-not $cutoff -or $folder.LastWriteTime -lt $cutoff)) {
                $matches = Test-MatchesFilters -Path $folder.FullName -Owner $owner `
                    -PathFilter $PathFilter -OwnerFilter $OwnerFilter
                if ($matches) {
                    $result = Invoke-CleanupAction -Path $folder.FullName -ItemType Folder `
                        -MatchedRule "EmptyFolder" -Mode $Mode `
                        -QuarantineRoot $QuarantineRoot -SourceRoot $root -Owner $owner `
                        -LogPath $LogPath -Execute:$Execute
                    $totalBytesSoFar += $result.SizeBytes
                }
            }
            elseif ($cutoff -and $stats.FileCount -gt 0) {
                $matches = Test-MatchesFilters -Path $folder.FullName -NewestFile $stats.NewestFile -Owner $owner `
                    -PathFilter $PathFilter -OwnerFilter $OwnerFilter -OlderThanDate $cutoff
                if ($matches) {
                    $result = Invoke-CleanupAction -Path $folder.FullName -ItemType Folder `
                        -MatchedRule "OlderThan$($OlderThanYears)y" -Mode $Mode `
                        -QuarantineRoot $QuarantineRoot -SourceRoot $root -Owner $owner `
                        -LogPath $LogPath -Execute:$Execute
                    $totalBytesSoFar += $result.SizeBytes
                }
            }
            Write-CleanupProgress -Current $i -Total $candidates.Count -StartTime $startTime `
                -CurrentItem $folder.FullName -BytesSoFar $totalBytesSoFar
        }
    }

    # --- Rules 3-5: zero-byte, junk files, and/or extension/age/size matches ---
    # Combined into one recursive scan so a multi-TB tree is only walked once.
    if (-not $SkipZeroByteFiles -or $RemoveJunkFiles -or $Extensions -or $cutoff -or $minSizeBytes) {
        $fileCandidates = @(Get-ChildItem -LiteralPath $root -File -Recurse -Force -ErrorAction SilentlyContinue |
            Where-Object {
                (-not (Test-ExcludedPath -Path $_.FullName -QuarantineRoot $QuarantineRoot)) -and (
                    (-not $SkipZeroByteFiles -and $_.Length -eq 0) -or
                    ($RemoveJunkFiles -and (Test-JunkFileMatch -FileName $_.Name)) -or
                    (Test-FileCriteriaMatch -File $_ -Extensions $Extensions -Cutoff $cutoff -MinSizeBytes $minSizeBytes)
                )
            })
        Write-Host "$root : found $($fileCandidates.Count) file-level candidates to evaluate..."
        $j = 0
        foreach ($file in $fileCandidates) {
            $j++
            $owner = Get-ItemOwner -Path $file.FullName
            $ext = [System.IO.Path]::GetExtension($file.Name).TrimStart('.')

            $rule = if ($file.Length -eq 0) { "ZeroByte" }
                    elseif ($RemoveJunkFiles -and (Test-JunkFileMatch -FileName $file.Name)) { "JunkFile" }
                    else {
                        $parts = @()
                        if ($Extensions) { $parts += "Ext:$ext" }
                        if ($cutoff) { $parts += "OlderThan$($OlderThanYears)y" }
                        if ($minSizeBytes) { $parts += "MinSize$($MinSizeMB)MB" }
                        $parts -join "+"
                    }

            $matches = Test-MatchesFilters -Path $file.FullName -Owner $owner `
                -PathFilter $PathFilter -OwnerFilter $OwnerFilter
            if ($matches) {
                $result = Invoke-CleanupAction -Path $file.FullName -ItemType File `
                    -MatchedRule $rule -Mode $Mode `
                    -QuarantineRoot $QuarantineRoot -SourceRoot $root -Owner $owner `
                    -LogPath $LogPath -Execute:$Execute
                $totalBytesSoFar += $result.SizeBytes
            }
            Write-CleanupProgress -Current $j -Total $fileCandidates.Count -StartTime $startTime `
                -CurrentItem $file.FullName -BytesSoFar $totalBytesSoFar
        }
    }
}

Write-Progress -Activity "File share cleanup" -Completed
Write-CleanupSummary -LogPath $LogPath
if (-not $Execute) {
    Write-Host "This was a DRY RUN. Re-run with -Execute after reviewing the log to actually delete/quarantine."
}
