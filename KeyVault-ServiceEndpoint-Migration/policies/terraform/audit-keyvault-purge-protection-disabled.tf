resource "azurerm_policy_definition" "audit_keyvault_purge_protection_disabled" {
  name                = "audit-keyvault-purge-protection-disabled"
  policy_type         = "Custom"
  mode                = "Indexed"
  display_name        = "Audit Key Vaults without purge protection enabled"
  description         = "Flags any Key Vault where enablePurgeProtection is not true. Bundled into this initiative as a Key Vault baseline hygiene check (Design.md §6.2)."
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
  })

  policy_rule = jsonencode({
    if = {
      allOf = [
        { field = "type", equals = "Microsoft.KeyVault/vaults" },
        {
          not = {
            field  = "Microsoft.KeyVault/vaults/enablePurgeProtection"
            equals = "true"
          }
        }
      ]
    }
    then = {
      effect = "[parameters('effect')]"
    }
  })
}
