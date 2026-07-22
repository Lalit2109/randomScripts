# File Share Cleanup - TODO

- [ ] Dry-run `Remove-OldFilesByAge.ps1` and `Remove-FilesFromExcelList.ps1` against a small test folder first, confirm CSV output looks right
- [ ] Confirm current backups actually cover the target shares before any `-Execute` run
- [ ] Get sign-off on a dry-run report (size/count) before running with `-Execute` on production data
- [ ] Validate robocopy handles the deepest/longest paths on the 2008/2012 shares (long-path edge cases)
- [ ] Confirm the account running the script has rights to read NTFS owner (`Get-Acl`) over the UNC path - may need explicit read permissions on old shares
- [ ] Install `ImportExcel` module on whichever jump host will run `Remove-FilesFromExcelList.ps1`
- [x] Memory: `Get-FolderStats`, the main file-level scan, and the end-of-run summary no longer materialize full file lists into memory (streamed via `ForEach-Object` / running counters instead of `@()` arrays or re-reading the whole CSV log) - was a real OOM risk on shares with millions of matching files
- [ ] If a target tree has millions of files, the recursive `Get-ChildItem` walk itself is still slow (I/O-bound, not memory-bound now) - consider swapping in a WizTree CLI export (MFT-based, much faster) as the stats source instead
- [ ] Run the age-based script per-server/per-share rather than all at once, so a bad run is easy to isolate and re-check
- [ ] After a few real runs, review whether `-OlderThanYears 7` is the right org-wide default or should vary per share
- [x] Add progress visibility for long unattended runs (Write-Progress bar + periodic console status line + CSV log updates live, so `Get-Content $LogPath -Wait` tails it in real time)
- [x] Fix: plain `-OlderThanYears` with no `-Extensions` now flags individual old files, not just whole folders where every file is old
- [x] Add more deletion scenarios: `-MinSizeMB` (space hogs), `-IncludeEmptyFolders`, `-RemoveJunkFiles` (Thumbs.db/desktop.ini/.DS_Store/Office lock files)
- [x] Safety: exclude `$RECYCLE.BIN` and `System Volume Information` from all scans
- [x] Remove quarantine/soft-delete mode entirely - now just two modes: dry run (default) and permanent delete (`-Execute`). Dry run writes one CSV row per matched item ("WouldDelete") as it's found, for team review before anyone passes `-Execute`
- [ ] Dry-run the new `-IncludeEmptyFolders` / `-RemoveJunkFiles` / `-MinSizeMB` criteria on a test folder before relying on them for real
- [ ] Decide whether Rule 1 (whole-folder age) and the new plain-age file rule should be de-duplicated in dry-run reporting (currently a fully-old folder is double-counted: once as a folder, once per file inside) - flagged in the script's docstring for now, not fixed
- [ ] Consider a duplicate-file finder based on content hash (`Get-FileHash`) as a built-in alternative to the manual Excel-curated list - not implemented; hashing TBs of data has a real performance cost, so this is deliberately still Excel-driven for now
