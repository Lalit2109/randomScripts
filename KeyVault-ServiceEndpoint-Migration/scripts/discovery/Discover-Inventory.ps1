<#
.SYNOPSIS
    Runs all Resource Graph queries for the Key Vault Service Endpoint
    migration and consolidates the results into one JSON inventory file.

.DESCRIPTION
    Equivalent to discover-inventory.sh, for teams standardized on
    PowerShell/Az instead of Azure CLI. Requires the Az.ResourceGraph module:
        Install-Module Az.ResourceGraph -Scope CurrentUser

.EXAMPLE
    ./Discover-Inventory.ps1 -SubscriptionId sub-1,sub-2 -OutputPath ./inventory.json
#>

param(
    [Parameter(Mandatory)] [string[]] $SubscriptionId,
    [string] $OutputPath = ".\inventory-$(Get-Date -Format yyyyMMdd-HHmmss).json"
)

if (-not (Get-Module -ListAvailable -Name Az.ResourceGraph)) {
    throw "Az.ResourceGraph module not found. Install it first: Install-Module Az.ResourceGraph -Scope CurrentUser"
}
Import-Module Az.ResourceGraph

$queryDir = Join-Path $PSScriptRoot "queries"

function Invoke-DiscoveryQuery {
    param([string] $QueryFile)
    $query = Get-Content -Path (Join-Path $queryDir $QueryFile) -Raw
    $results = @()
    $skipToken = $null
    do {
        $page = if ($skipToken) {
            Search-AzGraph -Query $query -Subscription $SubscriptionId -First 1000 -SkipToken $skipToken
        } else {
            Search-AzGraph -Query $query -Subscription $SubscriptionId -First 1000
        }
        $results += $page
        $skipToken = $page.SkipToken
    } while ($skipToken)
    return $results
}

Write-Host "Running discovery queries against $($SubscriptionId.Count) subscription(s)..."

$keyVaults             = Invoke-DiscoveryQuery -QueryFile "keyvaults.kql"
$functionApps          = Invoke-DiscoveryQuery -QueryFile "function-apps.kql"
$privateEndpoints      = Invoke-DiscoveryQuery -QueryFile "private-endpoints.kql"
$subnets               = Invoke-DiscoveryQuery -QueryFile "subnets.kql"
$rbacAssignments       = Invoke-DiscoveryQuery -QueryFile "rbac-assignments.kql"
$keyVaultAccessPolicies = Invoke-DiscoveryQuery -QueryFile "keyvault-access-policies.kql"

$inventory = [PSCustomObject]@{
    generatedAt            = (Get-Date).ToUniversalTime().ToString("o")
    keyVaults              = $keyVaults
    functionApps           = $functionApps
    privateEndpoints       = $privateEndpoints
    subnets                = $subnets
    rbacAssignments        = $rbacAssignments
    keyVaultAccessPolicies = $keyVaultAccessPolicies
}

$inventory | ConvertTo-Json -Depth 10 | Out-File -FilePath $OutputPath -Encoding utf8

Write-Host "Discovery complete. Consolidated inventory written to: $OutputPath"
Write-Host "  Key Vaults:            $($keyVaults.Count)"
Write-Host "  Function Apps:         $($functionApps.Count)"
Write-Host "  Private Endpoints:     $($privateEndpoints.Count)"
Write-Host "  Subnets:               $($subnets.Count)"
Write-Host "  RBAC Assignments:      $($rbacAssignments.Count)"
Write-Host "  Access Policy entries: $($keyVaultAccessPolicies.Count)"
