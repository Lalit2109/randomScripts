# File Share Cleanup — Governed (Quarantine + Excel Audit Trail)

Governance-driven file share cleanup that plugs into the Phase 1–4 process flow
(scoping → technical candidate identification → approval chain → execution).
Two ways to arrive at a candidate Excel, one script that ever acts on one, one
script that retires quarantined data afterward.

This package is fully self-contained — nothing here depends on or shares code
with any other script package in this repo.

**Every script can be run with no parameters at all.** Just run
`.\ScriptName.ps1` and answer the plain-language questions it asks — no
PowerShell parameter knowledge required. Passing a `-Parameter` on the
command line simply skips that question. See `Runbook.docx` (source:
`Runbook.md`) for a full step-by-step walkthrough with example sessions.

## Prerequisites

- `ImportExcel` module: `Install-Module ImportExcel -Scope CurrentUser`
  (required by both `Find-GovernedCandidatesByScan.ps1` and
  `Invoke-GovernedDeletionFromExcel.ps1`)
- `ActiveDirectory` module (RSAT): required by `Find-GovernedCandidatesByScan.ps1`
  unless you pass `-SkipInactiveOwnerCheck`
- Run from a modern admin/jump host against the share's UNC path, not locally
  on an old 2008/2012 file server — those ship PowerShell versions too old for
  this package, and for robocopy's long-path handling

## Two ways in, one script that acts

There is exactly **one** script in this package that ever quarantines or
deletes anything: `Invoke-GovernedDeletionFromExcel.ps1`. It always acts on an
Excel candidate list. There are two ways to produce that list:

```
  ManageEngine tool  ──┐
                       ├──►  candidates.xlsx  ──►  Invoke-GovernedDeletionFromExcel.ps1  ──►  quarantine / delete
  Find-GovernedCandidatesByScan.ps1  ──┘
```

- **From ManageEngine**: the team's existing process already produces an
  Excel export — hand it straight to `Invoke-GovernedDeletionFromExcel.ps1`.
- **From a direct scan**: run `Find-GovernedCandidatesByScan.ps1` against a
  drive/share instead. It only *identifies* candidates (Phase 2 rules) and
  writes them to a new Excel file in the same shape ManageEngine's export
  would be — it never touches a file on disk itself.

Either way, the Excel gets reviewed/approved (Phase 3), and only then is it
fed to `Invoke-GovernedDeletionFromExcel.ps1` for the actual run. This
guarantees whatever gets approved is exactly what gets acted on — a second
scan at execute time could see a share that's already changed, which is the
gap a single "identify and act in the same run" script would have.

## The action model (`Invoke-GovernedDeletionFromExcel.ps1`)

| Flag | Meaning |
|---|---|
| `-ActivityType Quarantine` \| `Delete` | **What** would happen to a match. Prompted interactively if omitted. |
| `-Execute` | **Whether** it actually happens. Omitted = dry run (default): every candidate is fully evaluated and logged/written back exactly as a real run would (`WouldQuarantine`/`WouldDelete`), nothing on disk is touched. |

Dry run is always the default, no matter what. `-Execute` is intentionally the
one thing never asked interactively — running for real always means
reviewing a dry run's output first, then consciously re-running the same
command with `-Execute` added (the script prints that exact command for you
at the end of a dry run). A real `-ActivityType Delete -Execute` run also
requires typing a confirmation phrase before it proceeds.

## Scripts

### 1. `Find-GovernedCandidatesByScan.ps1` — identify only
Scans a target path itself and finds candidates: files 7+ years old
(configurable) whose NTFS owner is a disabled AD account, plus 0-byte files
regardless of age. **Duplicate detection is out of scope** (same-filename+
size+modified checking across a petabyte-scale share risks breaking the
script on runtime/memory alone — parked, see `TODO.md`). Never quarantines or
deletes anything — writes a `Path`/`Owner`/`MatchedRule`/`SizeBytes`/
`LastWriteTime` Excel (capped at `-MaxExcelExportRows` to bound memory) meant
to be reviewed and then handed to `Invoke-GovernedDeletionFromExcel.ps1`.

### 2. `Invoke-GovernedDeletionFromExcel.ps1` — the one script that acts
Reads an Excel candidate list (from either source above) row by row with
live progress — not a single opaque `Import-Excel` call, which on a
100,000+ row workbook can otherwise sit silent for minutes — acts on each
row (file **or** folder — both are handled), and writes the outcome back
into **that same Excel file** as `CleanupStatus` / `CleanupDetail` /
`CleanupTimestamp` / `CleanupBy` columns, alongside every original column.
Safe to re-run — rows already `Deleted`/`Quarantined` are skipped on a
subsequent run. Both the read and the write-back go through
`Open-ExcelPackage`/`Close-ExcelPackage` directly rather than
`Import-Excel`/`Export-Excel`'s whole-sheet materialization, so every
other column keeps its original Excel formatting untouched.

### 3. `Remove-ExpiredQuarantine.ps1` — retention purge
Quarantine lands in `-QuarantineRoot` under a run-dated batch folder
(`yyyy-MM-dd_HHmmss`). This script ages those batches out — default 30 days —
and permanently deletes whole expired batches. Ignores any subfolder that
doesn't match the expected naming pattern.

## What's deliberately not built yet

- **Backup/recovery verification** — pending confirmation from the solution
  architect on where/how backups are stored. Until that's settled, quarantine
  (rather than defaulting straight to delete) is the safety net.
- **Duplicate detection** — parked, see above.
