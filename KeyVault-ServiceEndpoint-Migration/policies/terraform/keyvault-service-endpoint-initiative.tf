# reference_id on each policy_definition_reference block below is kept identical to the
# original JSON's policyDefinitionReferenceId purely for traceability. policy_definition_id
# is a real Terraform resource reference (not a name lookup like ARM's policyDefinitionName) -
# that's the one necessary translation, everything else here is a 1:1 port of
# policies/initiative/keyvault-service-endpoint-initiative.json.
resource "azurerm_management_group_policy_set_definition" "keyvault_service_endpoint_migration" {
  name                = "keyvault-service-endpoint-migration-initiative"
  policy_type         = "Custom"
  display_name        = "Key Vault Service Endpoint Migration - Governance Initiative"
  description         = "Combines all Deny and Audit policies for the Key Vault Private Endpoint -> Service Endpoint migration (Design.md §6/§7) into a single assignable initiative."
  management_group_id = var.management_group_id

  metadata = jsonencode({
    category = "Key Vault"
    source   = "KeyVault-ServiceEndpoint-Migration"
    version  = "1.0.0"
  })

  parameters = jsonencode({
    denyPolicyEffect = {
      type = "String"
      metadata = {
        displayName = "Effect for Deny-category policies"
        description = "Applies to deny-keyvault-without-default-deny, deny-keyvault-without-vnet-rules, deny-private-endpoint-creation-post-migration. Start at 'Audit' during pilot (RolloutPlan.md Phase 1), move to 'Deny' as rollout matures."
      }
      allowedValues = ["Deny", "Audit", "Disabled"]
      defaultValue  = "Audit"
    }
    excludedVaultIds = {
      type = "Array"
      metadata = {
        displayName = "Excluded Key Vault resource IDs"
        description = "The documented exclusion list from Design.md §4.4 - Key Vaults deliberately remaining on Private Endpoint"
      }
      defaultValue = []
    }
    logAnalyticsWorkspaceId = {
      type = "String"
      metadata = {
        displayName = "Log Analytics workspace resource ID"
        description = "Target workspace for the diagnostic-settings-missing check"
        strongType  = "Microsoft.OperationalInsights/workspaces"
      }
    }
    migrationScopeTagName = {
      type = "String"
      metadata = {
        displayName = "Migration scope tag name"
        description = "Tag key used to mark a Key Vault as in-scope for this migration - avoids false positives from vaults not yet part of the rollout"
      }
      defaultValue = "kv-se-migration-scope"
    }
  })

  policy_definition_reference {
    reference_id         = "deny-keyvault-without-default-deny"
    policy_definition_id = azurerm_policy_definition.deny_keyvault_without_default_deny.id
    parameter_values = jsonencode({
      effect           = { value = "[parameters('denyPolicyEffect')]" }
      excludedVaultIds = { value = "[parameters('excludedVaultIds')]" }
    })
  }

  policy_definition_reference {
    reference_id         = "deny-keyvault-without-vnet-rules"
    policy_definition_id = azurerm_policy_definition.deny_keyvault_without_vnet_rules.id
    parameter_values = jsonencode({
      effect                = { value = "[parameters('denyPolicyEffect')]" }
      excludedVaultIds      = { value = "[parameters('excludedVaultIds')]" }
      migrationScopeTagName = { value = "[parameters('migrationScopeTagName')]" }
    })
  }

  policy_definition_reference {
    reference_id         = "deny-private-endpoint-creation-post-migration"
    policy_definition_id = azurerm_policy_definition.deny_private_endpoint_creation_post_migration.id
    parameter_values = jsonencode({
      effect           = { value = "[parameters('denyPolicyEffect')]" }
      excludedVaultIds = { value = "[parameters('excludedVaultIds')]" }
    })
  }

  policy_definition_reference {
    reference_id         = "audit-keyvault-public-network-access"
    policy_definition_id = azurerm_policy_definition.audit_keyvault_public_network_access.id
    parameter_values = jsonencode({
      migrationScopeTagName = { value = "[parameters('migrationScopeTagName')]" }
    })
  }

  policy_definition_reference {
    reference_id         = "audit-keyvault-diagnostic-settings-missing"
    policy_definition_id = azurerm_policy_definition.audit_keyvault_diagnostic_settings_missing.id
    parameter_values = jsonencode({
      logAnalyticsWorkspaceId = { value = "[parameters('logAnalyticsWorkspaceId')]" }
    })
  }

  # No parameter_values - these two definitions expose no initiative-level parameter
  # mapping in the original JSON either, so they always use their own defaultValue ("Audit").
  policy_definition_reference {
    reference_id         = "audit-keyvault-soft-delete-disabled"
    policy_definition_id = azurerm_policy_definition.audit_keyvault_soft_delete_disabled.id
  }

  policy_definition_reference {
    reference_id         = "audit-keyvault-purge-protection-disabled"
    policy_definition_id = azurerm_policy_definition.audit_keyvault_purge_protection_disabled.id
  }
}
