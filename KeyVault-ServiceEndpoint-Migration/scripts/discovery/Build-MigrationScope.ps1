<#
.SYNOPSIS
    Joins the consolidated discovery inventory (from Discover-Inventory.ps1)
    into one row per Key Vault, resolving its Function App, integration
    subnet, and current Private Endpoint - the exact scope list used for a
    migration batch (CAB submission, migration script -BatchInventory input).

.DESCRIPTION
    Join strategy: a Function App's Managed Identity (identityPrincipalId)
    is cross-referenced against BOTH rbacAssignments AND keyVaultAccessPolicies
    scoped to each Key Vault to find which Function App is the intended caller
    for which vault - this is more reliable than assuming naming-convention
    matches in a large estate. Checking both matters because a Key Vault can
    use either authorization model (RBAC or the older classic Access Policies)
    independent of the other - a vault using only Access Policies would
    otherwise show zero RBAC matches and get wrongly flagged as having no
    access, when the Function App actually has working access.

    For an Access Policy match, the entry must actually grant 'get' (or
    'all', which implies every secret permission including 'get') on
    secrets - an identity merely listed in a vault's access policies without
    that permission does NOT have working access, and is called out
    separately (AccessPolicyInsufficientPermissions) rather than silently
    treated the same as "no entry at all" or "has access." The match is
    case-insensitive and tolerates secretsPermissions coming back either as
    a plain string array or as an array of objects exposing the string via
    a .value/.Value property - both shapes have been observed from
    Search-AzGraph depending on module version/environment.

    A Key Vault with zero matching Function Apps is flagged for manual
    review. Multiple matching Function Apps are only flagged if they sit in
    DIFFERENT subnets - that's the actual ambiguity that matters (which
    subnet gets the Service Endpoint/VNet rule), not the raw count of
    identities with access. Multiple apps sharing one subnet resolve cleanly
    (any of them is an equally correct answer) and are not blocked; every
    candidate is still listed in CandidateFunctionApps regardless.

.EXAMPLE
    ./Build-MigrationScope.ps1 -InventoryPath ./inventory.json -OutputCsv ./migration-scope.csv
#>

param(
    [Parameter(Mandatory)] [string] $InventoryPath,
    [string] $OutputCsv = ".\migration-scope-$(Get-Date -Format yyyyMMdd-HHmmss).csv"
)

function Get-KeyVaultPermissionValues {
    # Normalizes a Key Vault access policy permission list to a flat, lowercase
    # string array. Search-AzGraph results for dynamic/array columns have been
    # observed both as plain strings (["get","list"]) and as an array of
    # wrapper objects exposing the string via .value/.Value instead - handle
    # both rather than assume one shape.
    param($Permissions)
    if (-not $Permissions) { return @() }
    $raw = foreach ($item in @($Permissions)) {
        if ($null -eq $item) { continue }
        elseif ($item -is [string]) { $item }
        elseif ($item.PSObject.Properties.Match('value').Count -gt 0) { $item.value }
        elseif ($item.PSObject.Properties.Match('Value').Count -gt 0) { $item.Value }
        else { $item.ToString() }
    }
    return @($raw | ForEach-Object { $_.ToString().ToLowerInvariant() })
}

function Test-KeyVaultSecretGetPermission {
    # 'all' grants every secret permission, including 'get' - must count as a match.
    param($SecretsPermissions)
    $values = Get-KeyVaultPermissionValues -Permissions $SecretsPermissions
    return ($values -contains 'get') -or ($values -contains 'all')
}

$inventory = Get-Content -Path $InventoryPath -Raw | ConvertFrom-Json

$scope = foreach ($kv in $inventory.keyVaults) {
    $kvId = "/subscriptions/$($kv.subscriptionId)/resourceGroups/$($kv.resourceGroup)/providers/Microsoft.KeyVault/vaults/$($kv.name)"

    $matchingRoles = $inventory.rbacAssignments | Where-Object { $_.scope -eq $kvId }
    $rbacApps = foreach ($role in $matchingRoles) {
        $inventory.functionApps | Where-Object { $_.identityPrincipalId -eq $role.principalId }
    }

    $vaultAccessPolicies = $inventory.keyVaultAccessPolicies | Where-Object {
        $_.subscriptionId -eq $kv.subscriptionId -and $_.resourceGroup -eq $kv.resourceGroup -and $_.vaultName -eq $kv.name
    }
    $accessPolicyApps = @()
    $insufficientPermissionApps = @()
    foreach ($policy in $vaultAccessPolicies) {
        $app = $inventory.functionApps | Where-Object { $_.identityPrincipalId -eq $policy.objectId } | Select-Object -First 1
        if (-not $app) { continue }
        $hasSecretGet = Test-KeyVaultSecretGetPermission -SecretsPermissions $policy.secretsPermissions
        if ($hasSecretGet) { $accessPolicyApps += $app }
        else { $insufficientPermissionApps += $app }
    }

    $matchingApps = @($rbacApps) + @($accessPolicyApps) | Where-Object { $_ } | Sort-Object name -Unique
    $accessMechanism = if ($rbacApps) { "RBAC" } elseif ($accessPolicyApps) { "AccessPolicy" } else { $null }

    # Multiple matching apps only matters if they disagree on which SUBNET needs the
    # Service Endpoint / VNet rule - if they all sit in the same subnet, any one of
    # them is an equally correct answer for migration-scoping purposes and this is
    # not actually ambiguous, even though more than one identity has access.
    $distinctSubnetIds = @($matchingApps.vnetSubnetId | Where-Object { $_ } | Sort-Object -Unique)

    $existingPe = $inventory.privateEndpoints | Where-Object { $_.targetVaultId -eq $kvId }

    $reviewReason = if ($matchingApps.Count -eq 0 -and $insufficientPermissionApps.Count -gt 0) {
                        "Function App identity found in Key Vault Access Policy but missing 'get' on secrets - access will not actually work"
                    }
                    elseif ($matchingApps.Count -eq 0) { "No matching Function App identity found (checked both RBAC and Access Policies) - manual review required" }
                    elseif ($distinctSubnetIds.Count -gt 1) { "Multiple Function App identities match in DIFFERENT subnets ($($matchingApps.name -join ', ')) - see CandidateFunctionApps, pick the correct one manually before batching" }
                    else { $null }

    # Representative app for subnet-derived fields below - when $distinctSubnetIds.Count
    # is 0 or 1 this choice doesn't affect correctness (no match, or all candidates agree
    # on subnet); when it's >1 (still flagged for review above) this is only a preview,
    # not a decision - CandidateFunctionApps lists everyone so it's never silently hidden.
    $representativeApp = if ($matchingApps.Count -ge 1) { $matchingApps[0] } else { $null }
    $subnet = if ($representativeApp) { $inventory.subnets | Where-Object { $_.subnetId -eq $representativeApp.vnetSubnetId } | Select-Object -First 1 } else { $null }

    [PSCustomObject]@{
        VaultName              = $kv.name
        VaultResourceGroup     = $kv.resourceGroup
        SubscriptionId         = $kv.subscriptionId
        DefaultAction          = $kv.defaultAction
        PublicNetworkAccess    = $kv.publicNetworkAccess
        SoftDelete             = $kv.softDelete
        PurgeProtection        = $kv.purgeProtection
        FunctionAppSubnetId    = $representativeApp.vnetSubnetId
        AccessMechanism        = $accessMechanism
        AccessPolicyInsufficientPermissions = [bool]$insufficientPermissionApps
        CandidateFunctionApps  = ($matchingApps.name -join ";")
        CandidateFunctionAppCount = $matchingApps.Count
        OutboundVnetRouting    = $representativeApp.outboundVnetRouting
        SubnetExistingSE       = ($subnet.existingServiceEndpoints -join ";")
        ExistingPrivateEndpoint = $existingPe.peName
        ExistingPrivateEndpointSubnet = $existingPe.subnetId
        ReviewRequired         = [bool]$reviewReason
        ReviewReason           = $reviewReason
    }
}

$scope | Export-Csv -Path $OutputCsv -NoTypeInformation

$reviewCount = ($scope | Where-Object { $_.ReviewRequired }).Count
$rbacCount = ($scope | Where-Object { $_.AccessMechanism -eq 'RBAC' }).Count
$accessPolicyCount = ($scope | Where-Object { $_.AccessMechanism -eq 'AccessPolicy' }).Count
Write-Host "Migration scope written to: $OutputCsv"
Write-Host "  Total Key Vaults:      $($scope.Count)"
Write-Host "  Clean (1:1 resolved):  $($scope.Count - $reviewCount)"
Write-Host "  Needs manual review:   $reviewCount"
Write-Host "  Resolved via RBAC:          $rbacCount"
Write-Host "  Resolved via Access Policy: $accessPolicyCount"
if ($reviewCount -gt 0) {
    Write-Warning "Resolve all 'ReviewRequired' rows before including them in a migration batch - do not guess the Function App/subnet mapping."
}
