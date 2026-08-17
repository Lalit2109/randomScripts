# Azure Policies

Corresponds to `docs/Design.md` §6/§7. Deployed via Terraform (`terraform/`) - see
`terraform/README.md` for usage. Previously deployed via JSON + `Deploy-PolicyInitiative.ps1`;
that path was retired once the Terraform conversion became the source of truth.

## Definitions (`terraform/*.tf`, one file per policy)

| File | Effect | Purpose |
|---|---|---|
| `deny-keyvault-without-default-deny.tf` | Deny | Blocks a Key Vault where `networkAcls.defaultAction != Deny` |
| `deny-keyvault-without-vnet-rules.tf` | Deny | Blocks an in-scope Key Vault with `Deny` but zero VNet rules |
| `deny-private-endpoint-creation-post-migration.tf` | Deny | Blocks new Private Endpoints targeting Key Vault, except the exclusion list |
| `audit-keyvault-public-network-access.tf` | Audit | Flags drift on `publicNetworkAccess` versus expected migration state |
| `audit-keyvault-diagnostic-settings-missing.tf` | AuditIfNotExists | Flags Key Vaults without AuditEvent logging to the target workspace |
| `audit-keyvault-soft-delete-disabled.tf` | Audit | Flags Key Vaults without soft delete |
| `audit-keyvault-purge-protection-disabled.tf` | Audit | Flags Key Vaults without purge protection |

## Initiative (`terraform/keyvault-service-endpoint-initiative.tf`)

Combines all seven above into one assignable Policy Set Definition
(`azurerm_management_group_policy_set_definition`), with parameters for
`denyPolicyEffect`, `excludedVaultIds`, `logAnalyticsWorkspaceId`, and
`migrationScopeTagName` - see `docs/RolloutPlan.md` for how `denyPolicyEffect`
should track one phase behind the migration phase itself (`Audit` → `Deny` only
after the corresponding migration phase completes).

## Important scoping note

`deny-keyvault-without-vnet-rules` and `audit-keyvault-public-network-access` only
evaluate Key Vaults tagged with `migrationScopeTagName` (default
`kv-se-migration-scope`) - tag every Key Vault as its batch is migrated
(`Runbook.md`). Without this tag, both policies would either miss not-yet-migrated
vaults or produce false positives against vaults intentionally still in their
pre-migration state. **As of v2, this is set automatically** by
`scripts/migration/Set-KeyVaultFirewall.ps1 -AddSubnetId` (the step where a vault
enters migration) - pass `-SkipMigrationScopeTag` to opt out. Any vault tagged
under v1 by hand is unaffected; the script is idempotent and won't re-tag or
duplicate an existing `true` value.

## Defined at Management Group scope, assigned per-subscription

The seven definitions and the initiative are defined at a single Management
Group (the individual definitions use the plain `azurerm_policy_definition`
resource with `management_group_id` set directly; the initiative specifically
needs `azurerm_management_group_policy_set_definition` rather than the plain
`azurerm_policy_set_definition` - a provider v5.0 schema change - see
`terraform/README.md`).

The **assignment** is per-subscription, not Management-Group-wide: this org has
30+ subscriptions under that Management Group and only a handful are ever in
scope for this migration, so `var.in_scope_subscription_ids` is an explicit
include-list (one `azurerm_subscription_policy_assignment` per entry) rather than
assigning broadly and excluding the rest. See `terraform/README.md`'s "Why
per-subscription assignment" section. This in-scope list is a different
mechanism from `excludedVaultIds` (individual Key Vaults staying on Private
Endpoint within an otherwise in-scope subscription, Design.md §4.4) and from the
phase-based per-subscription "exemptions" concept described in Design.md §7
(temporary, not yet implemented).
