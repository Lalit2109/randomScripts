# File Share Cleanup - TODO

- [ ] Dry-run `Remove-OldFilesByAge.ps1` and `Remove-FilesFromExcelList.ps1` against a small test folder first, confirm CSV output looks right
- [ ] Confirm current backups actually cover the target shares before any `-Execute` run
- [ ] Get sign-off on a dry-run report (size/count) before running with `-Execute` on production data
- [ ] Decide and document the quarantine purge policy (grace period, e.g. 30 days, and who/what deletes `-QuarantineRoot` after it)
- [ ] Validate robocopy handles the deepest/longest paths on the 2008/2012 shares (long-path edge cases)
- [ ] Confirm the account running the script has rights to read NTFS owner (`Get-Acl`) over the UNC path - may need explicit read permissions on old shares
- [ ] Install `ImportExcel` module on whichever jump host will run `Remove-FilesFromExcelList.ps1`
- [ ] If a target tree has millions of files, `Get-FolderStats`'s recursive `Get-ChildItem` may be slow - consider swapping in a WizTree CLI export (MFT-based, much faster) as the stats source instead
- [ ] Run the age-based script per-server/per-share rather than all at once, so a bad run is easy to isolate and re-check
- [ ] After a few real runs, review whether `-OlderThanYears 7` is the right org-wide default or should vary per share
- [x] Add progress visibility for long unattended runs (Write-Progress bar + periodic console status line + CSV log updates live, so `Get-Content $LogPath -Wait` tails it in real time)
