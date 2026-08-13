resource "azurerm_policy_definition" "audit_keyvault_public_network_access" {
  name                = "audit-keyvault-public-network-access"
  policy_type         = "Custom"
  mode                = "Indexed"
  display_name        = "Audit Key Vault public network access state"
  description         = "Flags Key Vaults whose publicNetworkAccess setting doesn't match the expected value for their migration state. For migrated vaults (tagged in-scope), publicNetworkAccess=Enabled is EXPECTED under this design (Service Endpoints require it - Design.md §4.2); this policy's value is catching drift on NOT-yet-migrated vaults where it should still be Disabled, or catching an unexpected Disabled on a migrated vault (which would silently break Service Endpoint access)."
  management_group_id = var.management_group_id

  metadata = jsonencode({
    category = "Key Vault"
    source   = "KeyVault-ServiceEndpoint-Migration"
  })

  parameters = jsonencode({
    effect = {
      type          = "String"
      metadata      = { displayName = "Effect" }
      allowedValues = ["Audit", "Disabled"]
      defaultValue  = "Audit"
    }
    migrationScopeTagName = {
      type         = "String"
      defaultValue = "kv-se-migration-scope"
    }
    expectedPublicNetworkAccessForMigrated = {
      type          = "String"
      allowedValues = ["Enabled", "Disabled"]
      defaultValue  = "Enabled"
    }
  })

  policy_rule = jsonencode({
    if = {
      allOf = [
        { field = "type", equals = "Microsoft.KeyVault/vaults" },
        { field = "[concat('tags[', parameters('migrationScopeTagName'), ']')]", equals = "true" },
        {
          not = {
            field  = "Microsoft.KeyVault/vaults/publicNetworkAccess"
            equals = "[parameters('expectedPublicNetworkAccessForMigrated')]"
          }
        }
      ]
    }
    then = {
      effect = "[parameters('effect')]"
    }
  })
}
