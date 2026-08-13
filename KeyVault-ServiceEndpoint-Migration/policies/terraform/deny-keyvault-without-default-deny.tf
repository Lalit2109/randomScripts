resource "azurerm_policy_definition" "deny_keyvault_without_default_deny" {
  name                = "deny-keyvault-without-default-deny"
  policy_type         = "Custom"
  mode                = "Indexed"
  display_name        = "Key Vault must have network ACL default action of Deny"
  description         = "Denies creation or update of a Key Vault whose networkAcls.defaultAction is not 'Deny'. Enforces the deny-by-default firewall posture required by the Service Endpoint migration design (Design.md §4.1). Excludes vaults tagged with the migration-exclusion tag."
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
    excludedVaultIds = {
      type = "Array"
      metadata = {
        displayName = "Excluded Key Vault resource IDs"
        description = "Key Vaults deliberately kept on Private Endpoint (Design.md §4.4) - not subject to this policy"
      }
      defaultValue = []
    }
  })

  policy_rule = jsonencode({
    if = {
      allOf = [
        { field = "type", equals = "Microsoft.KeyVault/vaults" },
        {
          not = {
            field = "id"
            in    = "[parameters('excludedVaultIds')]"
          }
        },
        {
          not = {
            field  = "Microsoft.KeyVault/vaults/networkAcls.defaultAction"
            equals = "Deny"
          }
        }
      ]
    }
    then = {
      effect = "[parameters('effect')]"
    }
  })
}
