<#
.SYNOPSIS
    Modifies a Key Vault's firewall (network ACLs), snapshotting the prior
    configuration first. Supports adding a VNet rule, setting the default
    action, or both - used across every stage of the migration (add rule
    alongside existing PE, tighten to Deny, or break-glass widen for rollback).

.EXAMPLE
    # Add a VNet rule, leave default_action untouched (mid-migration, PE still present)
    ./Set-KeyVaultFirewall.ps1 -VaultName my-vault -AddSubnetId /subscriptions/.../subnets/int-subnet-01

.EXAMPLE
    # Tighten to Deny once the VNet rule is validated
    ./Set-KeyVaultFirewall.ps1 -VaultName my-vault -DefaultAction Deny

.EXAMPLE
    # Break-glass rollback: temporarily widen (expect the Activity Log Alert to fire)
    ./Set-KeyVaultFirewall.ps1 -VaultName my-vault -DefaultAction Allow
#>

param(
    [Parameter(Mandatory)] [string] $VaultName,
    [string] $ResourceGroupName,
    [string] $AddSubnetId,
    [ValidateSet("Allow", "Deny")] [string] $DefaultAction,
    [ValidateSet("AzureServices", "None")] [string] $Bypass,
    [string] $SnapshotDir = ".\snapshots",
    [switch] $WhatIf
)

$ErrorActionPreference = "Stop"

if (-not $ResourceGroupName) {
    $vaultResource = Get-AzKeyVault -VaultName $VaultName
    if (-not $vaultResource) { throw "Key Vault '$VaultName' not found in current subscription context." }
    $ResourceGroupName = $vaultResource.ResourceGroupName
}

$vault = Get-AzKeyVault -VaultName $VaultName -ResourceGroupName $ResourceGroupName

if (-not (Test-Path $SnapshotDir)) { New-Item -ItemType Directory -Path $SnapshotDir -Force | Out-Null }
$snapshotPath = Join-Path $SnapshotDir "$VaultName-firewall-$(Get-Date -Format yyyyMMdd-HHmmss).json"
[PSCustomObject]@{
    VaultName     = $VaultName
    ResourceGroup = $ResourceGroupName
    DefaultAction = $vault.NetworkAcls.DefaultAction
    Bypass        = $vault.NetworkAcls.Bypass
    VNetRuleIds   = $vault.NetworkAcls.VirtualNetworkResourceIds
    IpRules       = $vault.NetworkAcls.IpAddressRanges
} | ConvertTo-Json -Depth 10 | Out-File -FilePath $snapshotPath -Encoding utf8
Write-Host "Snapshot written: $snapshotPath"

if ($WhatIf) {
    Write-Host "[WhatIf] Current state snapshotted. Requested changes:"
    if ($AddSubnetId)   { Write-Host "  + Add VNet rule: $AddSubnetId" }
    if ($DefaultAction) { Write-Host "  + Set DefaultAction: $DefaultAction" }
    if ($Bypass)        { Write-Host "  + Set Bypass: $Bypass" }
    return
}

if ($AddSubnetId) {
    $existingRuleIds = @($vault.NetworkAcls.VirtualNetworkResourceIds)
    if ($existingRuleIds -contains $AddSubnetId) {
        Write-Host "VNet rule for '$AddSubnetId' already present on '$VaultName' - skipping add."
    }
    else {
        Add-AzKeyVaultNetworkRule -VaultName $VaultName -ResourceGroupName $ResourceGroupName -VirtualNetworkResourceId $AddSubnetId
        Write-Host "Added VNet rule for subnet '$AddSubnetId' to '$VaultName'."
    }
}

if ($DefaultAction) {
    Update-AzKeyVaultNetworkRuleSet -VaultName $VaultName -ResourceGroupName $ResourceGroupName -DefaultAction $DefaultAction
    Write-Host "Set DefaultAction = $DefaultAction on '$VaultName'."
    if ($DefaultAction -eq "Allow") {
        Write-Warning "DefaultAction is now 'Allow' - this is a break-glass state. Revert to 'Deny' as soon as root cause is resolved (same day)."
    }
}

if ($Bypass) {
    Update-AzKeyVaultNetworkRuleSet -VaultName $VaultName -ResourceGroupName $ResourceGroupName -Bypass $Bypass
    Write-Host "Set Bypass = $Bypass on '$VaultName'."
}
