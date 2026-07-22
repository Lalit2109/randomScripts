<#
.SYNOPSIS
    Adds the Microsoft.KeyVault service endpoint to a subnet, snapshotting
    the subnet's prior configuration first. Idempotent and non-destructive -
    safe to re-run; does nothing if the service endpoint is already present.

.EXAMPLE
    ./Enable-ServiceEndpoint.ps1 -SubnetId /subscriptions/.../subnets/int-subnet-01 -SnapshotDir ./snapshots
#>

param(
    [Parameter(Mandatory)] [string] $SubnetId,
    [string] $SnapshotDir = ".\snapshots",
    [switch] $WhatIf
)

$ErrorActionPreference = "Stop"

# Parse the subnet resource ID into its parts
if ($SubnetId -notmatch '/subscriptions/(?<sub>[^/]+)/resourceGroups/(?<rg>[^/]+)/providers/Microsoft.Network/virtualNetworks/(?<vnet>[^/]+)/subnets/(?<subnet>[^/]+)$') {
    throw "SubnetId does not look like a valid subnet resource ID: $SubnetId"
}
$subscriptionId = $Matches.sub
$resourceGroup   = $Matches.rg
$vnetName        = $Matches.vnet
$subnetName      = $Matches.subnet

Set-AzContext -SubscriptionId $subscriptionId | Out-Null

$vnet = Get-AzVirtualNetwork -Name $vnetName -ResourceGroupName $resourceGroup
$subnet = $vnet.Subnets | Where-Object { $_.Name -eq $subnetName }
if (-not $subnet) { throw "Subnet '$subnetName' not found in VNet '$vnetName'." }

if (-not (Test-Path $SnapshotDir)) { New-Item -ItemType Directory -Path $SnapshotDir -Force | Out-Null }
$snapshotPath = Join-Path $SnapshotDir "$vnetName-$subnetName-subnet-$(Get-Date -Format yyyyMMdd-HHmmss).json"
$subnet | ConvertTo-Json -Depth 10 | Out-File -FilePath $snapshotPath -Encoding utf8
Write-Host "Snapshot written: $snapshotPath"

$existingEndpoints = @($subnet.ServiceEndpoints | ForEach-Object { $_.Service })
if ($existingEndpoints -contains "Microsoft.KeyVault") {
    Write-Host "Subnet '$subnetName' already has Microsoft.KeyVault service endpoint - nothing to do."
    return
}

if ($WhatIf) {
    Write-Host "[WhatIf] Would add Microsoft.KeyVault service endpoint to subnet '$subnetName'."
    return
}

$serviceEndpointList = @($subnet.ServiceEndpoints | ForEach-Object { @{ Service = $_.Service } })
$serviceEndpointList += @{ Service = "Microsoft.KeyVault" }

Set-AzVirtualNetworkSubnetConfig `
    -VirtualNetwork $vnet `
    -Name $subnetName `
    -AddressPrefix $subnet.AddressPrefix `
    -ServiceEndpoint ($serviceEndpointList | ForEach-Object { $_.Service }) `
    | Out-Null
$vnet | Set-AzVirtualNetwork | Out-Null

Write-Host "Microsoft.KeyVault service endpoint added to subnet '$subnetName'."
