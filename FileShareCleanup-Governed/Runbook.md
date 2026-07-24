---
title: "File Share Cleanup — Governed: Operator Runbook"
author: "IT Infrastructure"
date: "2026-07-24"
---

# 1. Purpose

This runbook explains how to run the **Governed File Share Cleanup** scripts —
the PowerShell package that quarantines or permanently deletes file-share
content as part of the Data Lifecycle Management cleanup, with a full audit
trail written back into Excel.

It is written for an engineer who has not touched these scripts before. If
you already know the package, the `README.md` and `TODO.md` in the same
folder are the quicker reference.

This package implements Phases 2–4 of the agreed governance flow:

- **Phase 2 — Technical Candidate Identification**: either the ManageEngine
  tool, or `Find-GovernedCandidatesByScan.ps1` in this package.
- **Phase 3 — Governance Approval**: a human reviews the candidate Excel
  before anything runs for real.
- **Phase 4 — Execution**: `Invoke-GovernedDeletionFromExcel.ps1` performs the
  approved action and writes the result back into that same Excel file as the
  audit record.

A fourth script, `Remove-ExpiredQuarantine.ps1`, handles the follow-up step:
permanently purging anything that was quarantined once it has sat for the
retention period (30 days by default).

# 2. The golden rule: one script ever touches a file

Only **`Invoke-GovernedDeletionFromExcel.ps1`** ever quarantines or deletes
anything. Every other script either produces the Excel it reads, or cleans up
after it. Keep this mental model and the rest of the package is easy to
reason about:

```
  ManageEngine tool  ──────────┐
                                ├──►  candidates.xlsx
  Find-GovernedCandidatesByScan.ps1  ──┘         │
                                                  ▼
                                   [ Human reviews / approves ]
                                                  │
                                                  ▼
                          Invoke-GovernedDeletionFromExcel.ps1
                          (dry run first, then -Execute)
                                                  │
                                                  ▼
                          quarantine (-QuarantineRoot\<batch>\...)
                          or permanent delete
                                                  │
                                                  ▼ (30+ days later)
                          Remove-ExpiredQuarantine.ps1
                          (permanently purges the batch)
```

# 3. Prerequisites

Before running anything, confirm on the host you'll run from:

1. **PowerShell** — run from a modern admin/jump host against the share's
   UNC path (e.g. `\\FS01\Projects`), **not** locally on an old Windows
   Server 2008/2012 file server. Those ship PowerShell versions too old for
   this package and for robocopy's long-path handling.
2. **ImportExcel module**
   ```powershell
   Install-Module ImportExcel -Scope CurrentUser
   ```
   Required by `Find-GovernedCandidatesByScan.ps1` and
   `Invoke-GovernedDeletionFromExcel.ps1`.
3. **ActiveDirectory module (RSAT)** — required by
   `Find-GovernedCandidatesByScan.ps1` unless you pass
   `-SkipInactiveOwnerCheck`. Not needed by the other two scripts.
4. **Permissions** — the account running the scripts needs:
   - Read access to the target share (and read access to NTFS ACLs, for
     owner lookups — `Get-Acl`).
   - Write/modify/delete access to the target share (for quarantine moves
     and permanent deletes).
   - Read access to Active Directory (for the owner-inactive check).
5. **A small test folder** — always dry-run against a small test area first,
   the first time you use these scripts or after any change to them. See
   §8 (Testing before a real run).

# 4. The action model — read this before running anything

Every script that can act on files uses the same two independent controls.
Understanding these is the single most important thing in this runbook.

| Flag | Controls | Default |
|---|---|---|
| `-ActivityType` | **What** happens: `Quarantine` (move, reversible) or `Delete` (permanent) | Prompted interactively if you don't pass it — this is the only prompt |
| `-Execute` | **Whether** it actually happens | **Off.** Without `-Execute`, nothing on disk is ever touched. |

Note what's **not** in this table: `-TargetDrive` on `Invoke-GovernedDeletionFromExcel.ps1`
is optional and is never prompted for — every Excel row already carries its own full path,
so there's nothing to ask up front. Passing it just adds an extra safety-net scope check
and gives quarantine a single common root to anchor relative paths to; omitting it means
each item quarantines relative to its own share/drive root instead. See §7.1.

**Dry run is always the default, with no exceptions.** Without `-Execute`,
`Invoke-GovernedDeletionFromExcel.ps1` still fully evaluates every row and
writes `WouldQuarantine` / `WouldDelete` into the log and the Excel file —
including, for quarantine, the exact folder it *would* move to — so a dry
run is a complete, trustworthy preview of a real run, not a guess.

When you do pass `-Execute` with `-ActivityType Delete`, the script will
still stop and ask you to type a confirmation phrase before it proceeds.
There is no `-Force`/`-Confirm:$false` way to skip this.

# 5. Getting a candidate Excel — two ways

## 5a. From the ManageEngine tool

If the team already has a ManageEngine-produced Excel export, skip straight
to §6. The file just needs a column of full paths (default column name
`Path` — see `-PathColumn` if it's named differently).

## 5b. By running a direct scan (`Find-GovernedCandidatesByScan.ps1`)

Use this when a ManageEngine export isn't available. It never touches a
file — it only scans and reports.

**What it looks for:**

- Any file **7+ years old** (configurable via `-OlderThanYears`) **whose
  NTFS owner's AD account is disabled**.
- Any **0-byte file**, regardless of age (skip with `-SkipZeroByteFiles`).
- It does **not** look for duplicates — that rule is deliberately parked
  (see §10).

**Example — scan a share and write a candidate list:**

```powershell
.\Find-GovernedCandidatesByScan.ps1 `
    -TargetPath "\\FS01\Projects" `
    -OutputExcelPath ".\candidates-2026-07-24.xlsx"
```

**If RSAT/ActiveDirectory isn't installed on this host**, add
`-SkipInactiveOwnerCheck` — the age and 0-byte rules still run, just without
the owner-activity check:

```powershell
.\Find-GovernedCandidatesByScan.ps1 `
    -TargetPath "\\FS01\Projects" `
    -SkipInactiveOwnerCheck `
    -OutputExcelPath ".\candidates-2026-07-24.xlsx"
```

**What you get:** an Excel file with `Path`, `Owner`, `MatchedRule`,
`SizeBytes`, `LastWriteTime` columns — plus a CSV log with the same
information, written live as the scan runs (so nothing is lost even if the
scan is interrupted before the Excel is written).

The script prints a suggested next command at the end, using the exact
`-TargetPath` you gave it as the (optional) `-TargetDrive` for step 6 — copy
that line rather than retyping it if you want that extra scope check.

# 6. Governance review

Before running anything with `-Execute`, the candidate Excel (from either
5a or 5b) should go through the same review your team already does for
ManageEngine output — business owner review, legal hold check, whatever your
process requires. This package doesn't automate that step; it's a manual
gate by design.

# 7. Acting on the candidate list (`Invoke-GovernedDeletionFromExcel.ps1`)

This is the only script that quarantines or deletes anything.

## 7.1 Dry run (always do this first)

```powershell
.\Invoke-GovernedDeletionFromExcel.ps1 `
    -ExcelPath ".\candidates-2026-07-24.xlsx" `
    -ActivityType Quarantine `
    -QuarantineRoot "\\FS01\_Quarantine"
```

`-TargetDrive` is not required — each row's own path is already in the Excel.
Add `-TargetDrive "\\FS01\Projects"` only if you want the extra safety net of
skipping any row that isn't under that root, and a single common anchor for
quarantine's relative paths instead of each item using its own share/drive
root.

The **only** prompt you'll see is for `-ActivityType`, since it wasn't passed
above — type `Quarantine` or `Delete` when asked. If you passed `-ActivityType`
already (as in this example), there's no prompt at all — the run starts
immediately.

You'll see, per row: a live colored console line (`WouldQuarantine`, yellow),
a running progress count, and a final summary. Open the Excel afterward —
every row now has `CleanupStatus`, `CleanupDetail` (the would-be quarantine
path), `CleanupTimestamp`, and `CleanupBy` columns. Review this output.

## 7.2 Real run

Once the dry run looks right, add `-Execute`:

```powershell
.\Invoke-GovernedDeletionFromExcel.ps1 `
    -ExcelPath ".\candidates-2026-07-24.xlsx" `
    -ActivityType Quarantine `
    -QuarantineRoot "\\FS01\_Quarantine" `
    -Execute
```

Quarantined items move to
`\\FS01\_Quarantine\<run-timestamp>\<original relative path>` — the
timestamped subfolder is what `Remove-ExpiredQuarantine.ps1` later uses to
know what's eligible to purge (§9).

For a **permanent delete** instead, use `-ActivityType Delete` (dry run
first, exactly the same way) — with `-Execute`, you'll be asked to type a
confirmation phrase before anything is deleted: the target drive back, if
you passed `-TargetDrive`, otherwise the literal word `DELETE`.

## 7.3 If a run is interrupted

Just re-run the exact same command. Rows already marked `Deleted` or
`Quarantined` in the Excel are automatically skipped — only rows that
weren't finished yet (blank, `Error`, or a `WouldX` from a prior dry run)
are (re)evaluated. It is always safe to re-run this script against the same
Excel file.

## 7.4 If the Excel write-back fails

If someone has the Excel file open, the write-back retries a few times
with a short delay, then gives up with a clear warning — but **the CSV log
next to it always has the complete, real result**, even if the Excel didn't
get updated. Close the file and re-run the same command; already-completed
rows will be skipped per §7.3.

## 7.5 If the Excel file has multiple sheets

Without `-WorksheetName`, the script reads whichever sheet is **first by
position** in the workbook, and writes the results back into that exact
same sheet — it resolves the sheet name once at the start of the run and
reuses it, so read and write can never end up targeting two different
sheets even if the first sheet isn't named `Sheet1`.

Still, if your workbook has more than one sheet, **pass `-WorksheetName`
explicitly** naming the one with your candidate list. It removes any
ambiguity about which sheet is "first," and it's the only way to point the
script at a sheet that isn't the first one:

```powershell
.\Invoke-GovernedDeletionFromExcel.ps1 -ExcelPath ".\export.xlsx" -WorksheetName "Candidates" `
    -TargetDrive "\\FS01\Projects" -ActivityType Quarantine -QuarantineRoot "\\FS01\_Quarantine"
```

# 8. Testing before a real run

The first time you use these scripts — or after any change to them — dry-run
against a small local/test folder with a handful of files (mix in a folder
path as well as file paths) before pointing anything at production data.
Confirm:

- The console output is readable and each row's outcome makes sense.
- The Excel gets the four new columns without losing any original column.
- Quarantine (with a throwaway `-QuarantineRoot`) preserves the relative
  folder structure correctly.

# 9. Purging expired quarantine (`Remove-ExpiredQuarantine.ps1`)

Quarantined batches should not sit forever. This script permanently deletes
whole batches once they're older than the retention window (30 days by
default), regardless of whether they came from a ManageEngine-sourced run or
a scan-sourced run — both use the same batch-folder convention.

**Dry run:**

```powershell
.\Remove-ExpiredQuarantine.ps1 -QuarantineRoot "\\FS01\_Quarantine"
```

**Real purge:**

```powershell
.\Remove-ExpiredQuarantine.ps1 -QuarantineRoot "\\FS01\_Quarantine" -Execute
```

You'll be asked to type `PURGE` to confirm before anything is deleted. Any
subfolder under `-QuarantineRoot` that isn't named in the
`yyyy-MM-dd_HHmmss` batch format is skipped and left alone — this script
only ever touches folders it recognizes as its own batches.

There is currently no automated schedule for this — run it manually, or ask
to have it wired into a scheduled task once the 30-day default has been
validated against your actual retention requirement.

# 10. Known limitations (by design, not oversight)

- **Duplicate detection is not implemented.** The technical flowchart's
  "same filename + size + modified date" rule is deliberately left out of
  `Find-GovernedCandidatesByScan.ps1` — checking that across a
  petabyte-scale share risks the script running out of time or memory. If
  you need duplicates identified, that still goes through the ManageEngine
  tool for now.
- **No whole-folder rule in the scan script.** Unlike some other cleanup
  scripts, `Find-GovernedCandidatesByScan.ps1` only evaluates individual
  files, not whole aged folders.
- **Backup/recovery is not covered by this package.** Confirm separately
  with your solution architect where/how backups of this data are kept.
  Quarantine — rather than an immediate delete — is the interim safety net
  until that's settled.

# 11. Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| `ImportExcel module not found` | Run `Install-Module ImportExcel -Scope CurrentUser` on this host. |
| `ActiveDirectory module not found` | Install RSAT, or add `-SkipInactiveOwnerCheck` to `Find-GovernedCandidatesByScan.ps1`. |
| Excel write-back warning, "file may be open" | Close the Excel file on whoever has it open, then re-run the same command — already-completed rows are skipped automatically. |
| `robocopy failed ... exit code N` | Check the referenced `.robocopy.log` file next to the CSV log for the specific file that failed (often a locked/in-use file). Re-running is usually safe — completed items are skipped. |
| A quarantine batch folder isn't being purged | Confirm its name matches `yyyy-MM-dd_HHmmss` exactly — anything else is intentionally skipped. |
| Excel workbook has multiple sheets and you're not sure which one got read/updated | Always pass `-WorksheetName` explicitly on a multi-sheet workbook — see §7.5. |
| Console output stops right after "Read N rows..." with no errors and nothing new appearing | The script is waiting at the `-ActivityType` prompt — it's the only prompt left in this script, and it's easy to miss if you're watching a redirected log file instead of the live console (the prompt goes to the console host, not to stdout). Look for "Choose action for matched candidates..." and type `Quarantine` or `Delete`. For any unattended/scheduled run, always pass `-ActivityType` explicitly so there's no prompt to wait on. |
| Confirmation prompt won't accept my answer | It requires an exact, case-sensitive match (the target drive text, `DELETE`, or `PURGE`, depending on the script) — retype it exactly as shown on screen. |

# 12. Parameter reference

## `Find-GovernedCandidatesByScan.ps1`

| Parameter | Required | Default | Notes |
|---|---|---|---|
| `-TargetPath` | Yes | — | Single UNC/drive root to scan |
| `-OutputExcelPath` | Yes | — | Where the candidate Excel is written |
| `-OlderThanYears` | No | 7 | Age threshold for the inactive-owner rule |
| `-SkipInactiveOwnerCheck` | No | Off | Skip the AD lookup; age+0-byte rules still run |
| `-SkipZeroByteFiles` | No | Off | Disable the 0-byte rule |
| `-PathFilter` / `-OwnerFilter` | No | — | Extra wildcard AND-filters |
| `-MaxExcelExportRows` | No | 50000 | Above this, the Excel export is skipped (CSV log still has everything) |
| `-LogPath` | No | timestamped `.csv` in the current folder | |

## `Invoke-GovernedDeletionFromExcel.ps1`

| Parameter | Required | Default | Notes |
|---|---|---|---|
| `-ExcelPath` | Yes | — | The candidate Excel to read AND write back into |
| `-TargetDrive` | No (never prompted) | none — each row anchors to its own share/drive root | Optional safety-net scope filter + common quarantine anchor |
| `-ActivityType` | Prompted if omitted | — | `Quarantine` or `Delete` |
| `-QuarantineRoot` | Required if `-ActivityType Quarantine` | — | |
| `-Execute` | No | Off (dry run) | |
| `-WorksheetName` / `-PathColumn` | No | first sheet / `Path` | Set `-WorksheetName` explicitly on any multi-sheet workbook — see §7.5 |
| `-PathFilter` / `-OwnerFilter` / `-OlderThanYears` | No | — | Extra safety-net AND-filters |
| `-LogPath` | No | timestamped `.csv` | |

## `Remove-ExpiredQuarantine.ps1`

| Parameter | Required | Default | Notes |
|---|---|---|---|
| `-QuarantineRoot` | Yes | — | |
| `-RetentionDays` | No | 30 | |
| `-Execute` | No | Off (dry run) | |
| `-LogPath` | No | timestamped `.csv` | |
