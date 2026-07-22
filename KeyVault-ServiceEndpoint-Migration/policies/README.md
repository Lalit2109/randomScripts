# Azure Policies

Corresponds to `docs/Design.md` §6/§7. Deployed via `scripts/migration/Deploy-PolicyInitiative.ps1`.

## Definitions (`definitions/`)

| File | Effect | Purpose |
|---|---|---|
| `deny-keyvault-without-default-deny.json` | Deny | Blocks a Key Vault where `networkAcls.defaultAction != Deny` |
| `deny-keyvault-without-vnet-rules.json` | Deny | Blocks an in-scope Key Vault with `Deny` but zero VNet rules |
| `deny-private-endpoint-creation-post-migration.json` | Deny | Blocks new Private Endpoints targeting Key Vault, except the exclusion list |
| `audit-keyvault-public-network-access.json` | Audit | Flags drift on `publicNetworkAccess` versus expected migration state |
| `audit-keyvault-diagnostic-settings-missing.json` | AuditIfNotExists | Flags Key Vaults without AuditEvent logging to the target workspace |
| `audit-keyvault-soft-delete-disabled.json` | Audit | Flags Key Vaults without soft delete |
| `audit-keyvault-purge-protection-disabled.json` | Audit | Flags Key Vaults without purge protection |

## Initiative (`initiative/`)

`keyvault-service-endpoint-initiative.json` combines all seven above into one assignable Policy Set Definition, with parameters for `denyPolicyEffect`, `excludedVaultIds`, `logAnalyticsWorkspaceId`, and `migrationScopeTagName` — see `docs/RolloutPlan.md` for how `denyPolicyEffect` should track one phase behind the migration phase itself (`Audit` → `Deny` only after the corresponding migration phase completes).

## Important scoping note

`deny-keyvault-without-vnet-rules` and `audit-keyvault-public-network-access` only evaluate Key Vaults tagged with `migrationScopeTagName` (default `kv-se-migration-scope`) — tag every Key Vault as its batch is migrated (`Runbook.md`). Without this tag, both policies would either miss not-yet-migrated vaults or produce false positives against vaults intentionally still in their pre-migration state.

## A note on JSON correctness

These definitions are written to the real Azure Policy schema (aliases, `field`/`count`/`AuditIfNotExists` structures) and are intended to be deployable as-is, but — like any policy JSON — validate them against a live tenant (`az policy definition create --mode Indexed` or `New-AzPolicyDefinition -Policy <path>`) before relying on them in an enforced state. Complex array-based conditions (e.g. `deny-private-endpoint-creation-post-migration`'s connection-array matching) are the most likely to need a small adjustment once tested against real resource payloads.
