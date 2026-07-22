<#
.SYNOPSIS
    Restores a Key Vault's firewall (network ACLs) from a snapshot produced
    by Set-KeyVaultFirewall.ps1. This is the rollback mechanism referenced
    throughout Architecture.md §7 and Runbook.md §5 - there is no Terraform
    state to revert against, only these snapshots.

.EXAMPLE
    ./Restore-KeyVaultFirewall.ps1 -VaultName my-vault -SnapshotPath ./snapshots/my-vault-firewall-20260115-101500.json
#>

param(
    [Parameter(Mandatory)] [string] $VaultName,
    [string] $ResourceGroupName,
    [Parameter(Mandatory)] [string] $SnapshotPath,
    [switch] $WhatIf
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $SnapshotPath)) { throw "Snapshot file not found: $SnapshotPath" }
$snapshot = Get-Content -Path $SnapshotPath -Raw | ConvertFrom-Json

if (-not $ResourceGroupName) { $ResourceGroupName = $snapshot.ResourceGroup }

Write-Host "Restoring '$VaultName' firewall from snapshot taken at: $($snapshot.VaultName) / $SnapshotPath"
Write-Host "  Target DefaultAction: $($snapshot.DefaultAction)"
Write-Host "  Target Bypass:        $($snapshot.Bypass)"
Write-Host "  Target VNet rules:    $($snapshot.VNetRuleIds.Count)"
Write-Host "  Target IP rules:      $($snapshot.IpRules.Count)"

if ($WhatIf) {
    Write-Host "[WhatIf] No changes made."
    return
}

# Reset to a known-empty rule set first, then rebuild from the snapshot -
# avoids leaving stale rules that were added after the snapshot was taken.
Update-AzKeyVaultNetworkRuleSet -VaultName $VaultName -ResourceGroupName $ResourceGroupName -DefaultAction Allow -Bypass $snapshot.Bypass | Out-Null

foreach ($vnetRuleId in $snapshot.VNetRuleIds) {
    Add-AzKeyVaultNetworkRule -VaultName $VaultName -ResourceGroupName $ResourceGroupName -VirtualNetworkResourceId $vnetRuleId
}
foreach ($ipRule in $snapshot.IpRules) {
    Add-AzKeyVaultNetworkRule -VaultName $VaultName -ResourceGroupName $ResourceGroupName -IpAddressRange $ipRule
}

Update-AzKeyVaultNetworkRuleSet -VaultName $VaultName -ResourceGroupName $ResourceGroupName -DefaultAction $snapshot.DefaultAction | Out-Null

Write-Host "Firewall restored for '$VaultName' from snapshot."
