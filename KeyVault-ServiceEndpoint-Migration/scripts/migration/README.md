# Migration Scripts

Idempotent PowerShell scripts, each snapshotting the resource's prior configuration to `snapshots/` before making a change — the snapshot is the rollback point (see `docs/Architecture.md` §7). Run in order per `docs/Runbook.md` §2.

| Script | Purpose |
|---|---|
| `Enable-ServiceEndpoint.ps1` | Add `Microsoft.KeyVault` service endpoint to a subnet |
| `Set-KeyVaultFirewall.ps1` | Add a VNet rule and/or change `DefaultAction`/`Bypass` on a Key Vault |
| `Remove-PrivateEndpoint.ps1` | Snapshot + remove a Key Vault's Private Endpoint and DNS zone record |
| `Restore-KeyVaultFirewall.ps1` | Rollback: reapply a firewall snapshot |
| `Restore-PrivateEndpoint.ps1` | Rollback: recreate a Private Endpoint + DNS record from a snapshot |
| `Set-DiagnosticSettings.ps1` | Ensure a Key Vault has AuditEvent + Metrics flowing to Log Analytics |
| `Deploy-Monitoring.ps1` | Deploy the shared Action Group + 8 Activity Log Alerts, once per subscription |
| `Deploy-PolicyInitiative.ps1` | Deploy policy definitions + initiative + assignment from `policies/` |

All scripts support `-WhatIf` where a change is destructive or hard to undo (`Enable-ServiceEndpoint.ps1`, `Set-KeyVaultFirewall.ps1`, `Remove-PrivateEndpoint.ps1`, `Restore-*.ps1`) — always dry-run against a non-critical resource first when using a script for the first time.

**Snapshots are the rollback mechanism** in place of Terraform state (see `docs/Architecture.md` §2/§7 for why there's no Terraform here). Never delete `snapshots/` for a Key Vault until `docs/RolloutPlan.md`'s exit criteria for that phase confirm it's safe to archive them.
