<#
.SYNOPSIS
    Finds - and optionally removes - folders whose contents haven't been
    touched in N+ years, plus zero-byte files, under one or more file share
    paths. No Excel input needed; this searches on its own using a date cutoff.

.DESCRIPTION
    Three independent criteria, all optional except -TargetPath:
      1. Folders    - only runs if -OlderThanYears is supplied. Every
                      immediate subfolder under each -TargetPath is a
                      candidate; it qualifies if the newest LastWriteTime of
                      ANY file inside it (recursively, including subfolders)
                      is older than -OlderThanYears. This avoids relying on
                      the folder's own timestamp, which gets touched by
                      unrelated scans/backups and is not a reliable signal.
      2. Zero-byte  - matched independently, anywhere under -TargetPath,
         files         regardless of age. Runs by default; disable with
                      -SkipZeroByteFiles.
      3. Extensions - files matching -Extensions (e.g. jar, html, log).
                      -OlderThanYears is optional here too: if supplied,
                      only matching files older than that also qualify; if
                      omitted, every file with a matching extension qualifies
                      regardless of age.

    -OlderThanYears is not required to run the script at all - e.g. you can
    run with just -Extensions to delete by extension only, with no age
    condition, or combine both for "extension AND older than N years".

    Rules 2 and 3 share a single recursive file scan per -TargetPath (rather
    than walking a multi-TB tree twice), so adding -Extensions costs no extra
    scan time.

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
#>

param(
    [Parameter(Mandatory)] [string[]] $TargetPath,
    [int] $OlderThanYears,
    [switch] $SkipZeroByteFiles,
    [string[]] $Extensions,

    [string] $PathFilter,
    [string] $OwnerFilter,

    [ValidateSet("HardDelete", "Quarantine")]
    [string] $Mode = "Quarantine",
    [string] $QuarantineRoot,

    [switch] $Execute,
    [string] $LogPath = ".\cleanup-by-age-$(Get-Date -Format yyyyMMdd-HHmmss).csv"
)

. (Join-Path $PSScriptRoot "FileShareCleanup.Common.ps1")

if ($Mode -eq "Quarantine" -and -not $QuarantineRoot) {
    throw "-QuarantineRoot is required when -Mode is Quarantine."
}

if (-not $OlderThanYears -and -not $Extensions -and $SkipZeroByteFiles) {
    throw "Nothing to do: supply -OlderThanYears (folder-age rule), -Extensions, and/or leave zero-byte scanning enabled."
}

$cutoff = if ($OlderThanYears) { (Get-Date).AddYears(-$OlderThanYears) } else { $null }
if ($cutoff) {
    Write-Host "Cutoff date: items with no activity since before $($cutoff.ToString('yyyy-MM-dd')) qualify."
}
else {
    Write-Host "No -OlderThanYears given: folder-age rule is skipped, and extension matches (if any) are not age-gated."
}
Write-Host "Mode: $Mode | Execute: $($Execute.IsPresent) | Log: $LogPath"

$startTime = Get-Date
$totalBytesSoFar = 0

foreach ($root in $TargetPath) {

    # --- Rule 1: candidate folders untouched since before the cutoff (only if -OlderThanYears was given) ---
    if ($cutoff) {
        $candidates = @(Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue)
        Write-Host "`n$root : evaluating $($candidates.Count) candidate folders..."
        $i = 0
        foreach ($folder in $candidates) {
            $i++
            $stats = Get-FolderStats -Path $folder.FullName
            if ($stats.FileCount -gt 0) {
                $owner = Get-ItemOwner -Path $folder.FullName
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

    # --- Rules 2 & 3: zero-byte files, and/or files matching -Extensions that are also older than the cutoff ---
    # Combined into one recursive scan so a multi-TB tree is only walked once.
    if (-not $SkipZeroByteFiles -or $Extensions) {
        $fileCandidates = @(Get-ChildItem -LiteralPath $root -File -Recurse -Force -ErrorAction SilentlyContinue |
            Where-Object {
                (-not $SkipZeroByteFiles -and $_.Length -eq 0) -or
                ($Extensions -and (Test-ExtensionMatch -FileName $_.Name -Extensions $Extensions) -and (-not $cutoff -or $_.LastWriteTime -lt $cutoff))
            })
        Write-Host "$root : found $($fileCandidates.Count) file-level candidates (zero-byte / matching extensions) to evaluate..."
        $j = 0
        foreach ($file in $fileCandidates) {
            $j++
            $owner = Get-ItemOwner -Path $file.FullName
            $ext = [System.IO.Path]::GetExtension($file.Name).TrimStart('.')
            $rule = if ($file.Length -eq 0) { "ZeroByte" } elseif ($cutoff) { "OldExtension:$ext" } else { "Extension:$ext" }
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
