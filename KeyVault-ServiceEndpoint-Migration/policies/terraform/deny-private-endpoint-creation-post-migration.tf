resource "azurerm_policy_definition" "deny_private_endpoint_creation_post_migration" {
  name                = "deny-private-endpoint-creation-post-migration"
  policy_type         = "Custom"
  mode                = "All"
  display_name        = "Deny new Private Endpoint creation targeting Key Vault (post-migration)"
  description         = "Denies creation of a new Private Endpoint targeting Microsoft.KeyVault/vaults, scoped to resource groups/subscriptions that have completed migration. Excludes the documented exclusion list (Design.md §4.4) where Private Endpoint remains the intended pattern."
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
        description = "Private Endpoints targeting these Key Vault IDs are permitted"
      }
      defaultValue = []
    }
  })

  policy_rule = jsonencode({
    if = {
      allOf = [
        { field = "type", equals = "Microsoft.Network/privateEndpoints" },
        {
          field = "Microsoft.Network/privateEndpoints/privateLinkServiceConnections[*].privateLinkServiceId"
          notIn = "[parameters('excludedVaultIds')]"
        },
        {
          count = {
            field = "Microsoft.Network/privateEndpoints/privateLinkServiceConnections[*]"
            where = {
              field    = "Microsoft.Network/privateEndpoints/privateLinkServiceConnections[*].privateLinkServiceId"
              contains = "Microsoft.KeyVault/vaults"
            }
          }
          greater = 0
        }
      ]
    }
    then = {
      effect = "[parameters('effect')]"
    }
  })
}
