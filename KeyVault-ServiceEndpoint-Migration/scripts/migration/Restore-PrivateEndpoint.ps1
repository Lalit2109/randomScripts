<#
.SYNOPSIS
    Recreates a Key Vault's Private Endpoint and Private DNS Zone record
    from a snapshot produced by Remove-PrivateEndpoint.ps1. Full rollback
    path per Architecture.md §7 - use when Service Endpoints prove
    unworkable for a specific Key Vault (e.g. an undiscovered on-prem
    dependency surfaces).

.EXAMPLE
    ./Restore-PrivateEndpoint.ps1 -SnapshotPath ./snapshots/my-vault-pe-20260115-101500.json
#>

param(
    [Parameter(Mandatory)] [string] $SnapshotPath,
    [switch] $WhatIf
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $SnapshotPath)) { throw "Snapshot file not found: $SnapshotPath" }
$snapshot = Get-Content -Path $SnapshotPath -Raw | ConvertFrom-Json

Write-Host "Restoring Private Endpoint for '$($snapshot.VaultName)' from snapshot: $SnapshotPath"
Write-Host "  Private Endpoint name: $($snapshot.PrivateEndpointName)"
Write-Host "  Subnet:                $($snapshot.SubnetId)"
Write-Host "  Prior private IP:      $($snapshot.PrivateIpAddress) (not guaranteed to be reassigned - Azure allocates the next available IP in the subnet)"

if ($WhatIf) {
    Write-Host "[WhatIf] No changes made."
    return
}

$privateLinkServiceConnection = New-AzPrivateLinkServiceConnection `
    -Name "$($snapshot.PrivateEndpointName)-connection" `
    -PrivateLinkServiceId $snapshot.VaultResourceId `
    -GroupId "vault"

$pe = New-AzPrivateEndpoint `
    -ResourceGroupName $snapshot.ResourceGroup `
    -Name $snapshot.PrivateEndpointName `
    -Location $snapshot.Location `
    -Subnet @{ Id = $snapshot.SubnetId } `
    -PrivateLinkServiceConnection $privateLinkServiceConnection

if ($snapshot.DnsZoneGroupName -and $snapshot.PrivateDnsZoneConfigs) {
    $zoneConfigs = $snapshot.PrivateDnsZoneConfigs | ForEach-Object {
        New-AzPrivateDnsZoneConfig -Name (Split-Path $_ -Leaf) -PrivateDnsZoneId $_
    }
    New-AzPrivateDnsZoneGroup `
        -ResourceGroupName $snapshot.ResourceGroup `
        -PrivateEndpointName $snapshot.PrivateEndpointName `
        -Name $snapshot.DnsZoneGroupName `
        -PrivateDnsZoneConfig $zoneConfigs
}

Write-Host "Private Endpoint '$($snapshot.PrivateEndpointName)' restored for '$($snapshot.VaultName)'."
Write-Host "Next: run Restore-KeyVaultFirewall.ps1 to also revert the firewall to its pre-migration Deny-with-no-VNet-rule state (PE traffic doesn't need a VNet rule)."
Write-Host "Confirm DNS resolution returns to the private IP: Resolve-DnsName $($snapshot.VaultName).vault.azure.net"
