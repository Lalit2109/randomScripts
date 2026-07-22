<#
.SYNOPSIS
    Deletes exactly the paths listed in an Excel file - e.g. the duplicate-
    file list your team has already identified.

.DESCRIPTION
    Reads a column of paths from an Excel worksheet using the ImportExcel
    PowerShell module (Install-Module ImportExcel - no Excel/Office
    installation required, it reads the .xlsx directly) and runs each path
    through the same dry-run / delete engine used by Remove-OldFilesByAge.ps1,
    so both scripts behave identically and log to the same CSV format.

    Two modes only: dry run (default - no -Execute) and delete (-Execute).
    There is no quarantine/soft-delete step - -Execute permanently removes
    the matched paths. Every row is written to the CSV log as it's
    evaluated - "WouldDelete" in a dry run, "Deleted"/"Error"/"SkippedByFilter"
    once you run with -Execute - so the dry-run CSV is a complete, reviewable
    list before you ever pass -Execute.

    Optional narrowing filters (all combined with AND) act as a safety net
    on top of the Excel list - e.g. only act on rows that are ALSO under a
    given path, owned by a given user, or older than N years:
      -PathFilter     wildcard match against the full path, e.g. "*\Archive\*"
      -OwnerFilter    wildcard match against the NTFS owner, e.g. "CONTOSO\jsmith"
      -OlderThanYears require the file/folder's newest content to predate this

.EXAMPLE
    # Dry run - produces a report only, nothing is touched
    .\Remove-FilesFromExcelList.ps1 -ExcelPath ".\duplicates.xlsx" -PathColumn "FilePath"

.EXAMPLE
    # Real run - permanently deletes what matched
    .\Remove-FilesFromExcelList.ps1 -ExcelPath ".\duplicates.xlsx" -PathColumn "FilePath" -Execute

.EXAMPLE
    # Extra safety net: only delete Excel rows that are also 7+ years old
    .\Remove-FilesFromExcelList.ps1 -ExcelPath ".\duplicates.xlsx" -PathColumn "FilePath" `
        -OlderThanYears 7 -Execute
#>

param(
    [Parameter(Mandatory)] [string] $ExcelPath,
    [string] $WorksheetName,
    [string] $PathColumn = "Path",

    [string] $PathFilter,
    [string] $OwnerFilter,
    [int] $OlderThanYears,

    [switch] $Execute,
    [string] $LogPath = ".\cleanup-from-excel-$(Get-Date -Format yyyyMMdd-HHmmss).csv"
)

. (Join-Path $PSScriptRoot "FileShareCleanup.Common.ps1")

if (-not (Get-Module -ListAvailable -Name ImportExcel)) {
    throw "ImportExcel module not found. Install it first: Install-Module ImportExcel -Scope CurrentUser"
}
Import-Module ImportExcel

$rows = if ($WorksheetName) {
    Import-Excel -Path $ExcelPath -WorksheetName $WorksheetName
}
else {
    Import-Excel -Path $ExcelPath
}

$cutoff = if ($OlderThanYears) { (Get-Date).AddYears(-$OlderThanYears) } else { $null }

Write-Host "Read $($rows.Count) rows from $ExcelPath."
Write-Host "Execute: $($Execute.IsPresent) $(if (-not $Execute) { '(dry run - nothing will be deleted)' } else { '(files will be PERMANENTLY deleted)' }) | Log: $LogPath"

$startTime = Get-Date
$rowIndex = 0
$totalBytesSoFar = 0
$matchedCount = 0

foreach ($row in $rows) {
    $rowIndex++
    $path = $row.$PathColumn
    if ([string]::IsNullOrWhiteSpace($path)) { continue }

    if (-not (Test-Path -LiteralPath $path)) {
        Write-CleanupLogEntry -LogPath $LogPath -Path $path -ItemType File `
            -MatchedRule "ExcelList" -Action "Error" -ErrorMessage "Path not found"
        Write-CleanupProgress -Current $rowIndex -Total $rows.Count -StartTime $startTime -CurrentItem $path
        continue
    }

    if (Test-ExcludedPath -Path $path) {
        Write-CleanupLogEntry -LogPath $LogPath -Path $path -ItemType File `
            -MatchedRule "ExcelList" -Action "SkippedByFilter" -ErrorMessage "System-reserved path"
        Write-CleanupProgress -Current $rowIndex -Total $rows.Count -StartTime $startTime -CurrentItem $path
        continue
    }

    $item = Get-Item -LiteralPath $path -Force
    $itemType = if ($item.PSIsContainer) { "Folder" } else { "File" }
    $owner = Get-ItemOwner -Path $path
    $newestFile = if ($itemType -eq "Folder") { (Get-FolderStats -Path $path).NewestFile } else { $item.LastWriteTime }

    $matches = Test-MatchesFilters -Path $path -NewestFile $newestFile -Owner $owner `
        -PathFilter $PathFilter -OwnerFilter $OwnerFilter -OlderThanDate $cutoff
    if (-not $matches) {
        Write-CleanupLogEntry -LogPath $LogPath -Path $path -ItemType $itemType -Owner $owner `
            -MatchedRule "ExcelList" -Action "SkippedByFilter"
        Write-CleanupProgress -Current $rowIndex -Total $rows.Count -StartTime $startTime -CurrentItem $path
        continue
    }

    $result = Invoke-CleanupAction -Path $path -ItemType $itemType `
        -MatchedRule "ExcelList" -Owner $owner -LogPath $LogPath -Execute:$Execute
    $totalBytesSoFar += $result.SizeBytes
    $matchedCount++
    Write-CleanupProgress -Current $rowIndex -Total $rows.Count -StartTime $startTime -CurrentItem $path -BytesSoFar $totalBytesSoFar
}

Write-Progress -Activity "File share cleanup" -Completed
Write-CleanupSummary -LogPath $LogPath -MatchedCount $matchedCount -TotalBytes $totalBytesSoFar
if (-not $Execute) {
    Write-Host "This was a DRY RUN. Review $LogPath, and re-run with -Execute to actually delete."
}
