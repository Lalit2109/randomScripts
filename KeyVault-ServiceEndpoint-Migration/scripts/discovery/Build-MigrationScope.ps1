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

function ConvertTo-FlatStringArray {
    # Normalizes a Resource Graph dynamic/array column to a flat array of plain
    # strings. Multiple shapes have been observed from Search-AzGraph (in addition
    # to plain arrays like ["get","list"]), confirmed against a real tenant, not
    # assumed:
    #   (a) an array of wrapper objects, each exposing its string via .value/.Value
    #       e.g. [ {value:"get"}, {value:"list"} ]
    #   (b) a SINGLE wrapper object (not an array) whose own .value/.Value holds
    #       the entire real array - e.g. { value: ["Microsoft.KeyVault"], Count: 1 }
    #   (c) the real ARM shape for subnet.properties.serviceEndpoints - an array
    #       of objects with .service (not .value), e.g.
    #       [ {service:"Microsoft.KeyVault", locations:[...], provisioningState:...} ]
    # Handle all three, plus the plain-array case, rather than assume one shape.
    param($Values)
    if ($null -eq $Values) { return @() }

    $items = @($Values)

    # Shape (b): a single non-string wrapper object whose .value/.Value is itself
    # a collection - unwrap it to that inner collection before the main pass.
    if ($items.Count -eq 1 -and $items[0] -isnot [string]) {
        $candidate = $items[0]
        $inner = $null
        if ($candidate.PSObject.Properties.Match('value').Count -gt 0) { $inner = $candidate.value }
        elseif ($candidate.PSObject.Properties.Match('Value').Count -gt 0) { $inner = $candidate.Value }
        if ($inner -is [array] -or ($inner -is [System.Collections.IEnumerable] -and $inner -isnot [string])) {
            $items = @($inner)
        }
    }

    $raw = foreach ($item in $items) {
        if ($null -eq $item) { continue }
        elseif ($item -is [string]) { $item }
        elseif ($item.PSObject.Properties.Match('value').Count -gt 0) { $item.value }
        elseif ($item.PSObject.Properties.Match('Value').Count -gt 0) { $item.Value }
        elseif ($item.PSObject.Properties.Match('service').Count -gt 0) { $item.service }
        else {
            # Unrecognized object shape - PSCustomObject.ToString() silently
            # returns "" rather than a useful representation, and joining blank
            # entries together (e.g. "" -join ";" across 2 items) produces a
            # bare ";" with no visible content, which looks like a bug rather
            # than missing data. Skip it instead so it's cleanly absent.
            $str = $item.ToString()
            if (-not [string]::IsNullOrWhiteSpace($str)) { $str }
        }
    }
    return @($raw | Where-Object { $_ } | ForEach-Object { $_.ToString() })
}

function Test-KeyVaultSecretGetPermission {
    # 'all' grants every secret permission, including 'get' - must count as a match.
    param($SecretsPermissions)
    $values = ConvertTo-FlatStringArray -Values $SecretsPermissions | ForEach-Object { $_.ToLowerInvariant() }
    return ($values -contains 'get') -or ($values -contains 'all')
}

$inventory = Get-Content -Path $InventoryPath -Raw | ConvertFrom-Json

# @() forces $scope to stay an array even when exactly one Key Vault is in
# scope - same collapse risk as $matchingApps below, this time affecting the
# summary counts (Total/Clean/Needs review) rather than a per-row field.
$scope = @(foreach ($kv in $inventory.keyVaults) {
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

    # @() around the WHOLE pipeline (not just the two inputs) is required: piping
    # through Where-Object/Sort-Object -Unique collapses a single surviving result
    # to a bare scalar. On Windows PowerShell 5.1 (and PowerShell Core < 6.1.0),
    # a scalar PSCustomObject - exactly what ConvertFrom-Json produces for each
    # entry - has NO .Count property at all, so $matchingApps.Count silently
    # returns $null instead of 1, which fails every "-ge 1"/"-eq 0" check below
    # and blanks FunctionAppSubnetId/OutboundVnetRouting/SubnetExistingSE for any
    # vault with exactly one matching Function App. (PowerShell 7+ added an
    # intrinsic Count/Length to all objects, which is why this doesn't reproduce
    # under pwsh.)
    $matchingApps = @(@($rbacApps) + @($accessPolicyApps) | Where-Object { $_ } | Sort-Object name -Unique)
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
        SubnetExistingSE       = (ConvertTo-FlatStringArray -Values $subnet.existingServiceEndpoints) -join ";"
        ExistingPrivateEndpoint = $existingPe.peName
        ExistingPrivateEndpointSubnet = $existingPe.subnetId
        ReviewRequired         = [bool]$reviewReason
        ReviewReason           = $reviewReason
    }
})

$scope | Export-Csv -Path $OutputCsv -NoTypeInformation

# @() around each filtered pipeline for the same reason as $matchingApps/$scope
# above - plain parens don't force array-ness, so a single matching row would
# otherwise make .Count return $null instead of 1 on Windows PowerShell 5.1.
$reviewCount = @($scope | Where-Object { $_.ReviewRequired }).Count
$rbacCount = @($scope | Where-Object { $_.AccessMechanism -eq 'RBAC' }).Count
$accessPolicyCount = @($scope | Where-Object { $_.AccessMechanism -eq 'AccessPolicy' }).Count
Write-Host "Migration scope written to: $OutputCsv"
Write-Host "  Total Key Vaults:      $($scope.Count)"
Write-Host "  Clean (1:1 resolved):  $($scope.Count - $reviewCount)"
Write-Host "  Needs manual review:   $reviewCount"
Write-Host "  Resolved via RBAC:          $rbacCount"
Write-Host "  Resolved via Access Policy: $accessPolicyCount"
if ($reviewCount -gt 0) {
    Write-Warning "Resolve all 'ReviewRequired' rows before including them in a migration batch - do not guess the Function App/subnet mapping."
}
