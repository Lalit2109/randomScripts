<#
.SYNOPSIS
    Deletes/quarantines exactly the paths listed in an Excel file - e.g. the
    duplicate-file list your team has already identified.

.DESCRIPTION
    Reads a column of paths from an Excel worksheet using the ImportExcel
    PowerShell module (Install-Module ImportExcel - no Excel/Office
    installation required, it reads the .xlsx directly) and runs each path
    through the same dry-run / quarantine / hard-delete engine used by
    Remove-OldFilesByAge.ps1, so both scripts behave identically and log to
    the same CSV format.

    Safe by default: without -Execute, this ONLY writes a CSV report - every
    path is left untouched until you pass -Execute.

    Optional narrowing filters (all combined with AND) act as a safety net
    on top of the Excel list - e.g. only act on rows that are ALSO under a
    given path, owned by a given user, or older than N years:
      -PathFilter     wildcard match against the full path, e.g. "*\Archive\*"
      -OwnerFilter    wildcard match against the NTFS owner, e.g. "CONTOSO\jsmith"
      -OlderThanYears require the file/folder's newest content to predate this

.EXAMPLE
    .\Remove-FilesFromExcelList.ps1 -ExcelPath ".\duplicates.xlsx" -PathColumn "FilePath"

.EXAMPLE
    .\Remove-FilesFromExcelList.ps1 -ExcelPath ".\duplicates.xlsx" -PathColumn "FilePath" `
        -QuarantineRoot "\\FS01\_ToBeDeleted" -Execute

.EXAMPLE
    # Extra safety net: only delete Excel rows that are also 7+ years old
    .\Remove-FilesFromExcelList.ps1 -ExcelPath ".\duplicates.xlsx" -PathColumn "FilePath" `
        -OlderThanYears 7 -QuarantineRoot "\\FS01\_ToBeDeleted" -Execute
#>

param(
    [Parameter(Mandatory)] [string] $ExcelPath,
    [string] $WorksheetName,
    [string] $PathColumn = "Path",

    [string] $PathFilter,
    [string] $OwnerFilter,
    [int] $OlderThanYears,

    [ValidateSet("HardDelete", "Quarantine")]
    [string] $Mode = "Quarantine",
    [string] $QuarantineRoot,

    [switch] $Execute,
    [string] $LogPath = ".\cleanup-from-excel-$(Get-Date -Format yyyyMMdd-HHmmss).csv"
)

. (Join-Path $PSScriptRoot "FileShareCleanup.Common.ps1")

if ($Mode -eq "Quarantine" -and -not $QuarantineRoot) {
    throw "-QuarantineRoot is required when -Mode is Quarantine."
}

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
Write-Host "Mode: $Mode | Execute: $($Execute.IsPresent) | Log: $LogPath"

$startTime = Get-Date
$rowIndex = 0

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

    $item = Get-Item -LiteralPath $path -Force
    $itemType = if ($item.PSIsContainer) { "Folder" } else { "File" }
    $sourceRoot = Split-Path $path -Qualifier   # e.g. "\\FS01\Share", used for relative-path math under quarantine
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

    Invoke-CleanupAction -Path $path -ItemType $itemType `
        -MatchedRule "ExcelList" -Mode $Mode `
        -QuarantineRoot $QuarantineRoot -SourceRoot $sourceRoot -Owner $owner `
        -LogPath $LogPath -Execute:$Execute | Out-Null
    Write-CleanupProgress -Current $rowIndex -Total $rows.Count -StartTime $startTime -CurrentItem $path
}

Write-Progress -Activity "File share cleanup" -Completed
Write-CleanupSummary -LogPath $LogPath
if (-not $Execute) {
    Write-Host "This was a DRY RUN. Re-run with -Execute after reviewing the log to actually delete/quarantine."
}
