resource "azurerm_policy_definition" "deny_keyvault_without_vnet_rules" {
  name                = "deny-keyvault-without-vnet-rules"
  policy_type         = "Custom"
  mode                = "Indexed"
  display_name        = "Key Vault with Default Deny must have at least one VNet rule"
  description         = "Denies a Key Vault that has networkAcls.defaultAction = Deny but zero virtualNetworkRules - effectively unreachable, or a sign the migration wasn't completed correctly (missing Set-KeyVaultFirewall.ps1 -AddSubnetId step). Only evaluates vaults tagged as in-scope for this migration to avoid false positives on genuinely public/no-VNet-dependency vaults."
  management_group_id = var.management_group_id

  metadata = jsonencode({
    category = "Key Vault"
    source   = "KeyVault-ServiceEndpoint-Migration"
  })

  parameters = jsonencode({
    effect = {
      type = "String"
      metadata = {
        displayName = "Effect"
        description = "Deny, Audit, or Disabled"
      }
      allowedValues = ["Deny", "Audit", "Disabled"]
      defaultValue  = "Audit"
    }
    migrationScopeTagName = {
      type = "String"
      metadata = {
        displayName = "Migration scope tag name"
        description = "Tag key used to mark a Key Vault as in-scope for this migration"
      }
      defaultValue = "kv-se-migration-scope"
    }
    excludedVaultIds = {
      type = "Array"
      metadata = {
        displayName = "Excluded Key Vault resource IDs"
      }
      defaultValue = []
    }
  })

  policy_rule = jsonencode({
    if = {
      allOf = [
        { field = "type", equals = "Microsoft.KeyVault/vaults" },
        { field = "[concat('tags[', parameters('migrationScopeTagName'), ']')]", equals = "true" },
        {
          not = {
            field = "id"
            in    = "[parameters('excludedVaultIds')]"
          }
        },
        { field = "Microsoft.KeyVault/vaults/networkAcls.defaultAction", equals = "Deny" },
        {
          count = {
            field = "Microsoft.KeyVault/vaults/networkAcls.virtualNetworkRules[*]"
          }
          equals = 0
        }
      ]
    }
    then = {
      effect = "[parameters('effect')]"
    }
  })
}
