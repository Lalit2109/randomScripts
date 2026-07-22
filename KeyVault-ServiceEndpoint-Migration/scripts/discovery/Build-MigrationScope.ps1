<#
.SYNOPSIS
    Joins the consolidated discovery inventory (from Discover-Inventory.ps1)
    into one row per Key Vault, resolving its Function App, integration
    subnet, and current Private Endpoint - the exact scope list used for a
    migration batch (CAB submission, migration script -BatchInventory input).

.DESCRIPTION
    Join strategy: a Function App's Managed Identity (identityPrincipalId)
    is cross-referenced against rbacAssignments scoped to each Key Vault to
    find which Function App is the intended caller for which vault - this is
    more reliable than assuming naming-convention matches in a large estate.
    Any Key Vault with zero or more than one matching Function App is
    flagged for manual review rather than guessed at.

.EXAMPLE
    ./Build-MigrationScope.ps1 -InventoryPath ./inventory.json -OutputCsv ./migration-scope.csv
#>

param(
    [Parameter(Mandatory)] [string] $InventoryPath,
    [string] $OutputCsv = ".\migration-scope-$(Get-Date -Format yyyyMMdd-HHmmss).csv"
)

$inventory = Get-Content -Path $InventoryPath -Raw | ConvertFrom-Json

$scope = foreach ($kv in $inventory.keyVaults) {
    $kvId = "/subscriptions/$($kv.subscriptionId)/resourceGroups/$($kv.resourceGroup)/providers/Microsoft.KeyVault/vaults/$($kv.name)"

    $matchingRoles = $inventory.rbacAssignments | Where-Object { $_.scope -eq $kvId }
    $matchingApps = foreach ($role in $matchingRoles) {
        $inventory.functionApps | Where-Object { $_.identityPrincipalId -eq $role.principalId }
    }
    $matchingApps = $matchingApps | Sort-Object name -Unique

    $existingPe = $inventory.privateEndpoints | Where-Object { $_.targetVaultId -eq $kvId }

    $reviewReason = if ($matchingApps.Count -eq 0) { "No matching Function App identity found - manual review required" }
                    elseif ($matchingApps.Count -gt 1) { "Multiple Function App identities match - manual review required" }
                    else { $null }

    $functionApp = if ($matchingApps.Count -eq 1) { $matchingApps[0] } else { $null }
    $subnet = if ($functionApp) { $inventory.subnets | Where-Object { $_.subnetId -eq $functionApp.vnetSubnetId } | Select-Object -First 1 } else { $null }

    [PSCustomObject]@{
        VaultName              = $kv.name
        VaultResourceGroup     = $kv.resourceGroup
        SubscriptionId         = $kv.subscriptionId
        DefaultAction          = $kv.defaultAction
        PublicNetworkAccess    = $kv.publicNetworkAccess
        SoftDelete             = $kv.softDelete
        PurgeProtection        = $kv.purgeProtection
        FunctionAppName        = $functionApp.name
        FunctionAppSubnetId    = $functionApp.vnetSubnetId
        OutboundVnetRouting    = $functionApp.outboundVnetRouting
        SubnetExistingSE       = ($subnet.existingServiceEndpoints -join ";")
        ExistingPrivateEndpoint = $existingPe.peName
        ExistingPrivateEndpointSubnet = $existingPe.subnetId
        ReviewRequired         = [bool]$reviewReason
        ReviewReason           = $reviewReason
    }
}

$scope | Export-Csv -Path $OutputCsv -NoTypeInformation

$reviewCount = ($scope | Where-Object { $_.ReviewRequired }).Count
Write-Host "Migration scope written to: $OutputCsv"
Write-Host "  Total Key Vaults:      $($scope.Count)"
Write-Host "  Clean (1:1 resolved):  $($scope.Count - $reviewCount)"
Write-Host "  Needs manual review:   $reviewCount"
if ($reviewCount -gt 0) {
    Write-Warning "Resolve all 'ReviewRequired' rows before including them in a migration batch - do not guess the Function App/subnet mapping."
}
