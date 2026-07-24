# File Share Cleanup — Governed: TODO

- [ ] Dry-run all three scripts against a small test folder/share first, confirm CSV + Excel output looks right before anything touches production data
- [ ] Get sign-off on a dry-run report before running any script with `-Execute` on production data
- [ ] Install `ImportExcel` and (for the scan-based script) `ActiveDirectory`/RSAT on whichever jump host will run these
- [ ] Confirm the account running the scripts has rights to read NTFS owner (`Get-Acl`) over the UNC path, and to query AD for owner-enabled status
- [ ] Validate robocopy quarantine moves (`/MOVE /E`) and purge wipes (`/MIR`) handle the deepest/longest paths on the 2008/2012 shares (long-path edge cases)
- [ ] **Backup/recovery verification is parked** — need to confirm with the solution architect where/how backups are stored before any restore tooling can be designed. Quarantine (not straight-to-delete) is the interim safety net.
- [ ] **Duplicate detection is parked** — the flowchart's "same filename+size+modified" rule is not implemented in `Find-GovernedCandidatesByScan.ps1`. Checking that across a petabyte-scale share risks breaking the script (runtime/memory cost); revisit only with a bounded/sampled approach if this becomes a real gap.
- [ ] `Find-GovernedCandidatesByScan.ps1` currently only evaluates individual files (age+inactive-owner, or 0-byte) — no whole-folder rule like the age-based logic elsewhere in this repo. Revisit if folder-level candidates turn out to matter for this workflow.
- [ ] `Find-GovernedCandidatesByScan.ps1` takes a single `-TargetPath`, matching `Invoke-GovernedDeletionFromExcel.ps1`'s single `-TargetDrive` — if multi-root scans turn out to be needed, run one identify+approve+execute cycle per root rather than widening either script to accept an array, to keep the "approved list == executed list" guarantee intact for each root independently.
- [ ] Confirm `-QuarantineRoot` is placed on the same volume/share as the source paths being quarantined, so `robocopy /MOVE` is a fast rename rather than a slow copy+delete that also needs matching free space
- [ ] Decide on a real cadence for running `Remove-ExpiredQuarantine.ps1` (manual, or a scheduled task) once the 30-day default has been validated against actual retention requirements
