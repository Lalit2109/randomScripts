variable "management_group_id" {
  type        = string
  description = "Management Group resource ID (e.g. azurerm_management_group.example.id, or a literal /providers/Microsoft.Management/managementGroups/<id>) where every policy definition, the initiative, and the assignment are created/scoped."
}

variable "log_analytics_workspace_id" {
  type        = string
  description = "Log Analytics workspace resource ID that audit-keyvault-diagnostic-settings-missing checks Key Vaults are sending AuditEvent logs to."
}

variable "excluded_vault_ids" {
  type        = list(string)
  description = "Key Vault resource IDs deliberately kept on Private Endpoint (Design.md §4.4) - excluded from every Deny policy in this initiative."
  default     = []
}

variable "in_scope_subscription_ids" {
  type        = set(string)
  description = "Subscription resource IDs (e.g. /subscriptions/<sub-id>) to assign the initiative to - one azurerm_subscription_policy_assignment per entry. Deliberately an explicit include-list, not the whole management_group_id assigned with exclusions: this org has 30+ subscriptions under that Management Group and only a handful are ever in scope for this migration, so assigning narrowly to just the in-scope subscriptions is far less to maintain than excluding everything else. The definitions and initiative still live at management_group_id - only the assignment is per-subscription; Azure Policy allows assigning a higher-scope definition down to an individual subscription."
}

variable "deny_policy_effect" {
  type        = string
  description = "Effect for the three Deny-category policies (deny-keyvault-without-default-deny, deny-keyvault-without-vnet-rules, deny-private-endpoint-creation-post-migration). Start at Audit during pilot (RolloutPlan.md Phase 1), move to Deny as rollout matures - it should always track one phase behind the migration phase itself."
  default     = "Audit"

  validation {
    condition     = contains(["Deny", "Audit", "Disabled"], var.deny_policy_effect)
    error_message = "deny_policy_effect must be one of: Deny, Audit, Disabled."
  }
}

variable "migration_scope_tag_name" {
  type        = string
  description = "Tag key used to mark a Key Vault as in-scope for this migration. deny-keyvault-without-vnet-rules and audit-keyvault-public-network-access only evaluate vaults carrying tags[migration_scope_tag_name] = \"true\" (see policies/README.md 'Important scoping note'). No script currently sets this tag automatically - it's applied manually as each vault is migrated."
  default     = "kv-se-migration-scope"
}

variable "enforce" {
  type        = bool
  description = "Whether the assignment actually blocks (true, equivalent to the old PowerShell script's -EnforcementMode Default) or only evaluates without blocking (false, equivalent to -EnforcementMode DoNotEnforce). Keep this false through the Phase 1 pilot (RolloutPlan.md)."
  default     = false
}

variable "assignment_name" {
  type        = string
  description = "Name used for every per-subscription policy assignment (azurerm_subscription_policy_assignment caps this at 64 characters - name uniqueness is per-scope, so reusing the same name across each in-scope subscription's own assignment is fine, no collision)."
  default     = "assign-kv-se-migration"

  validation {
    condition     = length(var.assignment_name) <= 64
    error_message = "assignment_name must be 64 characters or fewer (azurerm_subscription_policy_assignment constraint)."
  }
}
