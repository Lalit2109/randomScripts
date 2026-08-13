# One assignment per in-scope subscription (azurerm_subscription_policy_assignment),
# not one management-group-wide assignment - this org has 30+ subscriptions under
# management_group_id and only var.in_scope_subscription_ids are ever in scope for
# this migration, so assigning narrowly beats assigning broadly + excluding the rest.
# The definition/initiative referenced below still lives at management_group_id -
# Azure Policy allows assigning a higher-scope definition down to an individual
# subscription, so this doesn't require duplicating the initiative per subscription.
#
# No identity block: none of the seven policies use Modify/DeployIfNotExists (which
# need a managed identity to remediate) - AuditIfNotExists only reads, it doesn't
# need one.
resource "azurerm_subscription_policy_assignment" "keyvault_service_endpoint_migration" {
  for_each = var.in_scope_subscription_ids

  name                 = var.assignment_name
  display_name         = "Key Vault Service Endpoint Migration Initiative"
  subscription_id      = each.value
  policy_definition_id = azurerm_management_group_policy_set_definition.keyvault_service_endpoint_migration.id
  enforce              = var.enforce

  parameters = jsonencode({
    denyPolicyEffect        = { value = var.deny_policy_effect }
    excludedVaultIds        = { value = var.excluded_vault_ids }
    logAnalyticsWorkspaceId = { value = var.log_analytics_workspace_id }
    migrationScopeTagName   = { value = var.migration_scope_tag_name }
  })
}
