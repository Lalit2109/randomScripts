<#
.SYNOPSIS
    Finds - and optionally permanently deletes - old/junk/oversized content
    under one or more file share paths on its own criteria. No Excel input
    needed.

.DESCRIPTION
    Dry run by default (no -Execute - always safe). With -Execute, matched
    items are quarantined by default (-Mode Quarantine, moved to
    -QuarantineRoot with a recovery window) or permanently deleted
    (-Mode HardDelete). Every matched item is written to the CSV log as
    it's found - one row per item - so the dry-run CSV is a complete,
    reviewable list of exactly what will happen before you ever pass
    -Execute.

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
    walking a multi-TB tree more than once), and stream rather than collect
    matches into memory first - see the code comments for why.

    Built-in safety exclusion (not configurable): Windows system-reserved
    folders ($RECYCLE.BIN, System Volume Information) are never scanned or
    touched - deleting/moving their contents can break the Recycle Bin or
    VSS shadow copies/backups.

    Note: Rule 1 (whole folders) and Rule 5 (individual old files, when run
    without -Extensions) can overlap - a folder where every file is old will
    be reported once by Rule 1 AND once per file by Rule 5 in a dry run, so
    the summary GB total can look inflated. In an -Execute run this is
    harmless (Rule 1 removes the folder first, so Rule 5 finds nothing left
    there), but it's worth knowing when reading a dry-run report.

    Additional narrowing filters (all optional, combined with AND):
      -PathFilter  wildcard match against the full path, e.g. "*\Archive\*"
      -OwnerFilter wildcard match against the NTFS owner, e.g. "CONTOSO\jsmith"

    Run this from a modern admin/jump host against the share's UNC path
    (e.g. \\FS01\Projects), not locally on the old 2008/2012 server itself -
    those OS versions ship old PowerShell (2.0 / 3.0) that lacks features
    this script and robocopy's long-path handling depend on.

.EXAMPLE
    # Dry run - produces a report only, nothing is touched
    .\Remove-OldFilesByAge.ps1 -TargetPath "\\FS01\Projects" -OlderThanYears 7

.EXAMPLE
    # Real run - quarantines what matched (default mode), recoverable
    .\Remove-OldFilesByAge.ps1 -TargetPath "\\FS01\Projects" -OlderThanYears 7 `
        -QuarantineRoot "\\FS01\_ToBeDeleted" -Execute

.EXAMPLE
    # Real run - permanently deletes what matched, no recovery window
    .\Remove-OldFilesByAge.ps1 -TargetPath "\\FS01\Projects" -OlderThanYears 7 -Mode HardDelete -Execute

.EXAMPLE
    # Only touch a specific sub-path, owned by a specific (e.g. departed) user
    .\Remove-OldFilesByAge.ps1 -TargetPath "\\FS01\Projects" -OlderThanYears 7 `
        -PathFilter "*\Archive\*" -OwnerFilter "CONTOSO\jsmith"

.EXAMPLE
    # Also clear out .jar and .html files older than 7 years, anywhere under the target
    .\Remove-OldFilesByAge.ps1 -TargetPath "\\FS01\Projects" -OlderThanYears 7 `
        -Extensions jar, html -Mode HardDelete -Execute

.EXAMPLE
    # Delete by extension only, no age condition, no folder-age rule
    .\Remove-OldFilesByAge.ps1 -TargetPath "\\FS01\Projects" -Extensions jar, html -Mode HardDelete -Execute

.EXAMPLE
    # Age only, no extension filter: delete any individual file older than 7 years
    .\Remove-OldFilesByAge.ps1 -TargetPath "\\FS01\Projects" -OlderThanYears 7 -Mode HardDelete -Execute

.EXAMPLE
    # Space hogs: any file over 500 MB, regardless of age or type
    .\Remove-OldFilesByAge.ps1 -TargetPath "\\FS01\Projects" -MinSizeMB 500 -Mode HardDelete -Execute

.EXAMPLE
    # Leftover empty folders (7+ years untouched) plus OS/app junk files
    .\Remove-OldFilesByAge.ps1 -TargetPath "\\FS01\Projects" -OlderThanYears 7 `
        -IncludeEmptyFolders -RemoveJunkFiles -Mode HardDelete -Execute
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

if (-not $OlderThanYears -and -not $Extensions -and -not $MinSizeMB -and -not $IncludeEmptyFolders -and -not $RemoveJunkFiles -and $SkipZeroByteFiles) {
    throw "Nothing to do: supply -OlderThanYears, -Extensions, -MinSizeMB, -IncludeEmptyFolders, -RemoveJunkFiles, and/or leave zero-byte scanning enabled."
}

if ($Execute -and $Mode -eq "Quarantine" -and -not $QuarantineRoot) {
    throw "-QuarantineRoot is required when -Mode is Quarantine (the default) and -Execute is set. Pass -Mode HardDelete if you don't want quarantine."
}

$cutoff = if ($OlderThanYears) { (Get-Date).AddYears(-$OlderThanYears) } else { $null }
$minSizeBytes = if ($MinSizeMB) { [long]($MinSizeMB * 1MB) } else { $null }

if ($cutoff) {
    Write-Host "Cutoff date: items with no activity since before $($cutoff.ToString('yyyy-MM-dd')) qualify."
}
else {
    Write-Host "No -OlderThanYears given: folder-age rule is skipped, and other age-aware criteria are not age-gated."
}
$executeDescription = if (-not $Execute) { '(dry run - nothing will be touched)' }
                       elseif ($Mode -eq "Quarantine") { "(items will be MOVED to $QuarantineRoot)" }
                       else { '(files will be PERMANENTLY deleted)' }
Write-Host "Execute: $($Execute.IsPresent) $executeDescription | Mode: $Mode | Log: $LogPath"

$startTime = Get-Date
$script:totalBytesSoFar = 0
$script:matchedCount = 0

foreach ($root in $TargetPath) {

    # --- Rules 1 & 2: whole-folder age rule, and/or completely empty folders ---
    # Only enumerates ONE level of subfolders (not recursive), so even a share with
    # thousands of top-level project folders stays well within safe array size -
    # unlike the recursive file-level scan below, this doesn't need to stream.
    if ($cutoff -or $IncludeEmptyFolders) {
        $candidates = @(Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue |
            Where-Object { -not (Test-ExcludedPath -Path $_.FullName) })
        Write-Host "`n$root : evaluating $($candidates.Count) candidate folders..."
        $i = 0
        foreach ($folder in $candidates) {
            $i++
            $stats = Get-FolderStats -Path $folder.FullName
            $owner = Get-ItemOwner -Path $folder.FullName

            if ($IncludeEmptyFolders -and $stats.FileCount -eq 0 -and (-not $cutoff -or $folder.LastWriteTime -lt $cutoff)) {
                $matches = Test-MatchesFilters -Path $folder.FullName -Owner $owner `
                    -PathFilter $PathFilter -OwnerFilter $OwnerFilter
                if ($matches) {
                    $result = Invoke-CleanupAction -Path $folder.FullName -ItemType Folder `
                        -MatchedRule "EmptyFolder" -Owner $owner -LogPath $LogPath `
                        -Mode $Mode -QuarantineRoot $QuarantineRoot -SourceRoot $root -Execute:$Execute
                    $totalBytesSoFar += $result.SizeBytes
                    $matchedCount++
                }
            }
            elseif ($cutoff -and $stats.FileCount -gt 0) {
                $matches = Test-MatchesFilters -Path $folder.FullName -NewestFile $stats.NewestFile -Owner $owner `
                    -PathFilter $PathFilter -OwnerFilter $OwnerFilter -OlderThanDate $cutoff
                if ($matches) {
                    $result = Invoke-CleanupAction -Path $folder.FullName -ItemType Folder `
                        -MatchedRule "OlderThan$($OlderThanYears)y" -Owner $owner -LogPath $LogPath `
                        -Mode $Mode -QuarantineRoot $QuarantineRoot -SourceRoot $root -Execute:$Execute
                    $totalBytesSoFar += $result.SizeBytes
                    $matchedCount++
                }
            }
            Write-CleanupProgress -Current $i -Total $candidates.Count -StartTime $startTime `
                -CurrentItem $folder.FullName -BytesSoFar $totalBytesSoFar
        }
    }

    # --- Rules 3-5: zero-byte, junk files, and/or extension/age/size matches ---
    # A multi-TB share can have millions of matching files, so this does NOT
    # collect them into an array first (that would hold every match in memory
    # at once before processing even starts). Instead it's two streamed passes:
    # pass 1 counts matches (for the progress bar) without retaining any of
    # them, pass 2 processes and discards each one as it goes - memory stays
    # flat regardless of how many files match. The trade-off is walking the
    # tree twice instead of once; worth it to keep memory bounded at scale.
    if (-not $SkipZeroByteFiles -or $RemoveJunkFiles -or $Extensions -or $cutoff -or $minSizeBytes) {
        $fileFilter = {
            (-not (Test-ExcludedPath -Path $_.FullName)) -and (
                (-not $SkipZeroByteFiles -and $_.Length -eq 0) -or
                ($RemoveJunkFiles -and (Test-JunkFileMatch -FileName $_.Name)) -or
                (Test-FileCriteriaMatch -File $_ -Extensions $Extensions -Cutoff $cutoff -MinSizeBytes $minSizeBytes)
            )
        }

        $totalFileCandidates = (Get-ChildItem -LiteralPath $root -File -Recurse -Force -ErrorAction SilentlyContinue |
            Where-Object $fileFilter | Measure-Object).Count
        Write-Host "$root : found $totalFileCandidates file-level candidates to evaluate..."

        $script:j = 0
        Get-ChildItem -LiteralPath $root -File -Recurse -Force -ErrorAction SilentlyContinue |
            Where-Object $fileFilter |
            ForEach-Object {
                $file = $_
                $script:j++
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
                        -MatchedRule $rule -Owner $owner -LogPath $LogPath `
                        -Mode $Mode -QuarantineRoot $QuarantineRoot -SourceRoot $root -Execute:$Execute
                    $script:totalBytesSoFar += $result.SizeBytes
                    $script:matchedCount++
                }
                Write-CleanupProgress -Current $j -Total $totalFileCandidates -StartTime $startTime `
                    -CurrentItem $file.FullName -BytesSoFar $totalBytesSoFar
            }
    }
}

Write-Progress -Activity "File share cleanup" -Completed
Write-CleanupSummary -LogPath $LogPath -MatchedCount $matchedCount -TotalBytes $totalBytesSoFar
if (-not $Execute) {
    Write-Host "This was a DRY RUN. Review $LogPath, and re-run with -Execute to actually delete."
}
