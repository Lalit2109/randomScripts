resource "azurerm_policy_definition" "audit_keyvault_soft_delete_disabled" {
  name                = "audit-keyvault-soft-delete-disabled"
  policy_type         = "Custom"
  mode                = "Indexed"
  display_name        = "Audit Key Vaults without soft delete enabled"
  description         = "Flags any Key Vault where enableSoftDelete is not true. Unrelated to this migration's networking change, but bundled into the same initiative since it's a Key Vault baseline hygiene check worth enforcing alongside it (Design.md §6.2)."
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
            field  = "Microsoft.KeyVault/vaults/enableSoftDelete"
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
