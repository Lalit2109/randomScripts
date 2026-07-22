<#
.SYNOPSIS
    Removes a Key Vault's Private Endpoint and its associated Private DNS
    Zone record, after snapshotting full detail (subnet, private IP, DNS
    zone group) for restore. Only run this AFTER Set-KeyVaultFirewall.ps1
    has added and validated the VNet rule (see Testing.md) - this script
    does not check that for you.

.EXAMPLE
    ./Remove-PrivateEndpoint.ps1 -VaultName my-vault -SnapshotDir ./snapshots
#>

param(
    [Parameter(Mandatory)] [string] $VaultName,
    [string] $ResourceGroupName,
    [string] $SnapshotDir = ".\snapshots",
    [switch] $WhatIf
)

$ErrorActionPreference = "Stop"

if (-not $ResourceGroupName) {
    $vault = Get-AzKeyVault -VaultName $VaultName
    if (-not $vault) { throw "Key Vault '$VaultName' not found in current subscription context." }
    $ResourceGroupName = $vault.ResourceGroupName
}
$vaultResource = Get-AzResource -ResourceGroupName $ResourceGroupName -ResourceType "Microsoft.KeyVault/vaults" -ResourceName $VaultName

$privateEndpoints = Get-AzPrivateEndpoint | Where-Object {
    $_.PrivateLinkServiceConnections.PrivateLinkServiceId -eq $vaultResource.ResourceId
}

if (-not $privateEndpoints) {
    Write-Host "No Private Endpoint found targeting '$VaultName' - nothing to remove."
    return
}
if ($privateEndpoints.Count -gt 1) {
    throw "Found $($privateEndpoints.Count) Private Endpoints targeting '$VaultName' - expected 0 or 1 for this 1:1 estate. Resolve manually before proceeding."
}
$pe = $privateEndpoints[0]

# Find the DNS zone group attached to this PE, if any
$dnsZoneGroup = Get-AzPrivateDnsZoneGroup -ResourceGroupName $pe.ResourceGroupName -PrivateEndpointName $pe.Name -ErrorAction SilentlyContinue

if (-not (Test-Path $SnapshotDir)) { New-Item -ItemType Directory -Path $SnapshotDir -Force | Out-Null }
$snapshotPath = Join-Path $SnapshotDir "$VaultName-pe-$(Get-Date -Format yyyyMMdd-HHmmss).json"
[PSCustomObject]@{
    VaultName            = $VaultName
    VaultResourceId      = $vaultResource.ResourceId
    PrivateEndpointName  = $pe.Name
    ResourceGroup        = $pe.ResourceGroupName
    Location             = $pe.Location
    SubnetId             = $pe.Subnet.Id
    PrivateIpAddress     = $pe.NetworkInterfaces[0].IpConfigurations[0].PrivateIpAddress
    DnsZoneGroupName     = $dnsZoneGroup.Name
    PrivateDnsZoneConfigs = $dnsZoneGroup.PrivateDnsZoneConfigs | ForEach-Object { $_.PrivateDnsZoneId }
} | ConvertTo-Json -Depth 10 | Out-File -FilePath $snapshotPath -Encoding utf8
Write-Host "Snapshot written: $snapshotPath"
Write-Warning "This snapshot is the ONLY restore point for this Private Endpoint - retain it per RolloutPlan.md's snapshot retention guidance."

if ($WhatIf) {
    Write-Host "[WhatIf] Would remove Private Endpoint '$($pe.Name)' and its DNS zone group."
    return
}

if ($dnsZoneGroup) {
    Remove-AzPrivateDnsZoneGroup -ResourceGroupName $pe.ResourceGroupName -PrivateEndpointName $pe.Name -Name $dnsZoneGroup.Name -Force
}
Remove-AzPrivateEndpoint -ResourceGroupName $pe.ResourceGroupName -Name $pe.Name -Force

Write-Host "Private Endpoint '$($pe.Name)' removed for '$VaultName'."
Write-Host "Confirm DNS resolution now returns the public IP: Resolve-DnsName $($VaultName).vault.azure.net"
