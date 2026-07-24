<#
.SYNOPSIS
    Permanently purges quarantine batches older than the retention window.
    Works for any batch Invoke-GovernedDeletionFromExcel.ps1 created,
    regardless of whether that Excel came from the ManageEngine tool or from
    Find-GovernedCandidatesByScan.ps1 - both feed the same script, which
    writes into -QuarantineRoot using the same run-dated batch-folder
    convention (yyyy-MM-dd_HHmmss).

.DESCRIPTION
    Enumerates the IMMEDIATE subfolders of -QuarantineRoot only (each one is
    a batch from a single run). Any subfolder whose name doesn't match the
    expected yyyy-MM-dd_HHmmss pattern is skipped with a warning and left
    completely alone - this script never touches anything it doesn't
    recognize as one of its own batches, even if something else is also
    using -QuarantineRoot as a parent folder.

    Batches are purged (or reported, in a dry run) as a whole unit - one CSV
    log row per batch folder, not per file inside it - using the same
    robocopy /MIR-then-Remove-Item approach as every other permanent delete
    in this package (long-path safety + speed on folders with large file
    counts).

    Dry run by default: reports every batch past -RetentionDays with its
    age and size, touches nothing. Pass -Execute to actually purge them.

.EXAMPLE
    # Dry run - reports which batches are past 30 days
    .\Remove-ExpiredQuarantine.ps1 -QuarantineRoot "\\FS01\_Quarantine"

.EXAMPLE
    # Real purge of everything past 30 days
    .\Remove-ExpiredQuarantine.ps1 -QuarantineRoot "\\FS01\_Quarantine" -Execute

.EXAMPLE
    # Different retention window
    .\Remove-ExpiredQuarantine.ps1 -QuarantineRoot "\\FS01\_Quarantine" -RetentionDays 45 -Execute
#>

param(
    [Parameter(Mandatory)] [string] $QuarantineRoot,
    [int] $RetentionDays = 30,
    [switch] $Execute,
    [string] $LogPath = ".\governed-quarantine-purge-$(Get-Date -Format yyyyMMdd-HHmmss).csv"
)

. (Join-Path $PSScriptRoot "FileShareCleanup-Governed.Common.ps1")

if (-not (Test-Path -LiteralPath $QuarantineRoot)) {
    throw "QuarantineRoot not found: $QuarantineRoot"
}

Write-PhaseHeader "Phase 1/3: Scanning quarantine batches under $QuarantineRoot"

$batches = @(Get-ChildItem -LiteralPath $QuarantineRoot -Directory -Force -ErrorAction SilentlyContinue)
$eligible = @()

foreach ($batch in $batches) {
    if ($batch.Name -notmatch $script:QuarantineBatchNamePattern) {
        Write-ActionLine -Level Warn -Message "SKIPPED (not a recognized batch folder name, left alone): $($batch.FullName)"
        continue
    }

    try {
        $batchDate = [datetime]::ParseExact($batch.Name, 'yyyy-MM-dd_HHmmss', $null)
    }
    catch {
        Write-ActionLine -Level Warn -Message "SKIPPED (could not parse batch timestamp, left alone): $($batch.FullName)"
        continue
    }

    $ageDays = [math]::Round((New-TimeSpan -Start $batchDate -End (Get-Date)).TotalDays, 1)
    if ($ageDays -ge $RetentionDays) {
        $eligible += [PSCustomObject]@{ Folder = $batch; BatchDate = $batchDate; AgeDays = $ageDays }
    }
}

Write-Host "Found $($batches.Count) batch folder(s) total, $($eligible.Count) past the $RetentionDays-day retention window."

$modeText = if ($Execute) { "EXECUTE - expired batches will be PERMANENTLY deleted" } else { "DRY RUN - reporting only, nothing will be touched" }
Write-Host "Mode: $modeText"
Write-Host "Log : $LogPath"

if ($Execute -and $eligible.Count -gt 0) {
    Write-Host ""
    Write-Host "You are about to PERMANENTLY DELETE $($eligible.Count) quarantine batch(es) under $QuarantineRoot." -ForegroundColor Red
    $typed = Read-Host "Type PURGE to confirm and continue"
    if ($typed -ne "PURGE") {
        Write-Host "Confirmation text did not match. Aborting - nothing was touched." -ForegroundColor Yellow
        return
    }
}

Write-PhaseHeader "Phase 2/3: $(if ($Execute) { 'Purging' } else { 'Evaluating' }) $($eligible.Count) expired batch(es)"

$startTime = Get-Date
$i = 0
$totalBytesSoFar = 0
$purgedCount = 0
$statusCounts = @{}

foreach ($entry in $eligible) {
    $i++
    $folder = $entry.Folder
    Write-ScanProgress -Current $i -Total $eligible.Count -StartTime $startTime -CurrentItem $folder.FullName

    $stats = Get-FolderStats -Path $folder.FullName
    $sizeMB = '{0:N1} MB' -f ($stats.SizeBytes / 1MB)
    $rule = "QuarantineAge$($entry.AgeDays)d"

    if (-not $Execute) {
        Write-GovernedLogEntry -LogPath $LogPath -Path $folder.FullName -ItemType Folder `
            -SizeBytes $stats.SizeBytes -FileCount $stats.FileCount -MatchedRule $rule -Action "WouldPurge"
        Write-ActionLine -Level DryRun -Message "WouldPurge  $($folder.FullName)  (batch age $($entry.AgeDays)d, $sizeMB)"
        $statusCounts["WouldPurge"] = 1 + ($(if ($statusCounts.ContainsKey("WouldPurge")) { $statusCounts["WouldPurge"] } else { 0 }))
        $totalBytesSoFar += $stats.SizeBytes
        $purgedCount++
        continue
    }

    try {
        $emptyDir = Get-EmptyMirrorDir
        robocopy $emptyDir $folder.FullName /MIR /R:1 /W:1 /NP /NFL /NDL /LOG+:"$LogPath.robocopy.log" | Out-Null
        if ($LASTEXITCODE -ge 8) { throw "robocopy failed wiping quarantine batch (exit code $LASTEXITCODE) - see $LogPath.robocopy.log" }
        Remove-Item -LiteralPath $folder.FullName -Force -Recurse -ErrorAction Stop

        Write-GovernedLogEntry -LogPath $LogPath -Path $folder.FullName -ItemType Folder `
            -SizeBytes $stats.SizeBytes -FileCount $stats.FileCount -MatchedRule $rule -Action "Purged"
        Write-ActionLine -Level Success -Message "PURGED  $($folder.FullName)  (batch age $($entry.AgeDays)d, $sizeMB)"
        $statusCounts["Purged"] = 1 + ($(if ($statusCounts.ContainsKey("Purged")) { $statusCounts["Purged"] } else { 0 }))
        $totalBytesSoFar += $stats.SizeBytes
        $purgedCount++
    }
    catch {
        Write-GovernedLogEntry -LogPath $LogPath -Path $folder.FullName -ItemType Folder `
            -SizeBytes $stats.SizeBytes -FileCount $stats.FileCount -MatchedRule $rule -Action "Error" -ErrorMessage $_.Exception.Message
        Write-ActionLine -Level Error -Message "ERROR  $($folder.FullName) : $($_.Exception.Message)"
        $statusCounts["Error"] = 1 + ($(if ($statusCounts.ContainsKey("Error")) { $statusCounts["Error"] } else { 0 }))
    }
}

Write-Progress -Activity "File share scan" -Completed

Write-PhaseHeader "Phase 3/3: Summary"
Write-GovernedSummary -LogPath $LogPath -MatchedCount $purgedCount -TotalBytes $totalBytesSoFar -StatusCounts $statusCounts
if (-not $Execute) {
    Write-Host "This was a DRY RUN. Review the CSV output, then re-run with -Execute to permanently purge expired batches." -ForegroundColor Yellow
}
