output "policy_definition_ids" {
  description = "Resource IDs of all seven Key Vault policy definitions, keyed by definition name."
  value = {
    deny_keyvault_without_default_deny            = azurerm_policy_definition.deny_keyvault_without_default_deny.id
    deny_keyvault_without_vnet_rules              = azurerm_policy_definition.deny_keyvault_without_vnet_rules.id
    deny_private_endpoint_creation_post_migration = azurerm_policy_definition.deny_private_endpoint_creation_post_migration.id
    audit_keyvault_public_network_access          = azurerm_policy_definition.audit_keyvault_public_network_access.id
    audit_keyvault_diagnostic_settings_missing    = azurerm_policy_definition.audit_keyvault_diagnostic_settings_missing.id
    audit_keyvault_soft_delete_disabled           = azurerm_policy_definition.audit_keyvault_soft_delete_disabled.id
    audit_keyvault_purge_protection_disabled      = azurerm_policy_definition.audit_keyvault_purge_protection_disabled.id
  }
}

output "policy_set_definition_id" {
  description = "Resource ID of the combined Key Vault Service Endpoint Migration initiative."
  value       = azurerm_management_group_policy_set_definition.keyvault_service_endpoint_migration.id
}

output "policy_assignment_ids" {
  description = "Resource IDs of the initiative assignment, keyed by subscription ID (one assignment per in-scope subscription)."
  value = {
    for sub_id, assignment in azurerm_subscription_policy_assignment.keyvault_service_endpoint_migration :
    sub_id => assignment.id
  }
}
