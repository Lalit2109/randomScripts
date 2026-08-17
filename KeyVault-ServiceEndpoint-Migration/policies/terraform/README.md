# Key Vault Service Endpoint Migration - Policies (Terraform)

Terraform port of the seven Custom policy definitions, the initiative that combines
them, and the initiative assignment - previously deployed via the JSON files under
`policies/definitions/` + `policies/initiative/` and `scripts/migration/Deploy-PolicyInitiative.ps1`
(now removed; this package is the source of truth). Definitions and the initiative
are defined at a single Management Group; the assignment is per-subscription (see
"Why per-subscription assignment" below) - not parameterized for a single
management-group-wide assignment.

## Files

| File | Resource |
|---|---|
| `deny-keyvault-without-default-deny.tf` | `azurerm_policy_definition` |
| `deny-keyvault-without-vnet-rules.tf` | `azurerm_policy_definition` |
| `deny-private-endpoint-creation-post-migration.tf` | `azurerm_policy_definition` |
| `audit-keyvault-public-network-access.tf` | `azurerm_policy_definition` |
| `audit-keyvault-diagnostic-settings-missing.tf` | `azurerm_policy_definition` |
| `audit-keyvault-soft-delete-disabled.tf` | `azurerm_policy_definition` |
| `audit-keyvault-purge-protection-disabled.tf` | `azurerm_policy_definition` |
| `keyvault-service-endpoint-initiative.tf` | `azurerm_management_group_policy_set_definition` |
| `keyvault-service-endpoint-assignment.tf` | `azurerm_subscription_policy_assignment` (one per `in_scope_subscription_ids` entry, via `for_each`) |
| `variables.tf` / `outputs.tf` / `versions.tf` | Plumbing |

All resources live in one flat root module (not split into child modules) - the
initiative directly references each definition's `.id` and each assignment
directly references the initiative's `.id`, which only works simply when
everything shares one Terraform state.

## Why per-subscription assignment, not one Management-Group-wide assignment

This org has 30+ subscriptions under `management_group_id`, and only a handful are
ever in scope for this migration. Assigning once at the Management Group and
excluding the rest (`not_scopes`) would mean maintaining an exclusion list of
25+ subscriptions that grows every time a new, unrelated subscription is added to
the org - the wrong default for this ratio. Assigning narrowly instead
(`azurerm_subscription_policy_assignment`, one per entry in
`var.in_scope_subscription_ids` via `for_each`) means the *in-scope* list - the
short, deliberately-curated one - is what's maintained.

The definitions and initiative still live at `management_group_id` - Azure Policy
allows assigning a definition/initiative down to any subscription at or below the
scope it was defined at, so this doesn't require duplicating the initiative per
subscription, only the assignment.

Adding a subscription to scope later (RolloutPlan.md's phases) is a one-line change
to `in_scope_subscription_ids`, not a new resource block - `for_each` over a `set`
handles it.

## Why `azurerm_management_group_policy_set_definition`, not `azurerm_policy_definition` + `management_group_id`

Provider v5.0 removed the `management_group_id` argument from the plain
`azurerm_policy_set_definition` resource entirely, in favor of this dedicated
resource - using it here (even though we're pinned to `~> 4.0`, where the old
attribute still technically works) avoids inheriting that forced-replacement
problem on a future provider bump. This does **not** apply to the individual
policy *definitions* - `azurerm_policy_definition` kept `management_group_id`
unchanged through v5.0 (no dedicated management-group resource exists for plain
definitions), so those seven use the plain resource with `management_group_id`
set directly.

## Usage

```bash
cd policies/terraform
cp terraform.tfvars.example terraform.tfvars   # fill in real management group / subscription / workspace IDs
terraform init
terraform plan
terraform apply
```

`deny_policy_effect` and `enforce` default to `Audit` / `false` (Phase 1 pilot, per
`../../docs/RolloutPlan.md`) - move `deny_policy_effect` to `"Deny"` and `enforce` to
`true` only as each phase's exit criteria are met, never both flipped from day one.

**Assignment name length**: `azurerm_subscription_policy_assignment.name` is capped
at 64 characters (unlike the management-group-scoped resource's 24-character cap).
`var.assignment_name` defaults to `assign-kv-se-migration`, reused identically across
every in-scope subscription's own assignment - name uniqueness is per-scope, so this
doesn't collide.

## Excluding an individual vault within an in-scope subscription

Still handled by `excluded_vault_ids` (Design.md §4.4) - unrelated to the
per-subscription assignment change above. A vault deliberately staying on Private
Endpoint inside an otherwise in-scope subscription goes here, not into
`in_scope_subscription_ids`.
