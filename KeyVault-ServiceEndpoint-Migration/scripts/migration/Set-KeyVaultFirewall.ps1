<#
.SYNOPSIS
    Modifies a Key Vault's firewall (network ACLs), snapshotting the prior
    configuration first. Supports adding a VNet rule, setting the default
    action, or both - used across every stage of the migration (add rule
    alongside existing PE, tighten to Deny, or break-glass widen for rollback).

    -AddSubnetId also sets the migration-scope tag (kv-se-migration-scope=true
    by default) - this is the moment a vault actually enters migration, and
    the tag-gated policies (deny-keyvault-without-vnet-rules,
    audit-keyvault-public-network-access - see policies/README.md "Important
    scoping note") need it set to evaluate the vault at all. Previously a
    manual step; pass -SkipMigrationScopeTag to opt out.

.EXAMPLE
    # Add a VNet rule, leave default_action untouched (mid-migration, PE still present)
    # - also tags the vault kv-se-migration-scope=true
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
    [string] $MigrationScopeTagName = "kv-se-migration-scope",
    [switch] $SkipMigrationScopeTag,
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
    if ($AddSubnetId -and -not $SkipMigrationScopeTag) { Write-Host "  + Set tag: $MigrationScopeTagName=true" }
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

    if (-not $SkipMigrationScopeTag) {
        # Merge into existing tags rather than overwrite - Update-AzKeyVault -Tag replaces
        # the full tag set, so a naive assignment here would silently wipe every other tag.
        $currentTags = if ($vault.Tags) { @{} + $vault.Tags } else { @{} }
        if ($currentTags[$MigrationScopeTagName] -eq "true") {
            Write-Host "Migration-scope tag '$MigrationScopeTagName' already set on '$VaultName' - skipping."
        }
        else {
            $currentTags[$MigrationScopeTagName] = "true"
            Update-AzKeyVault -VaultName $VaultName -ResourceGroupName $ResourceGroupName -Tag $currentTags | Out-Null
            Write-Host "Set migration-scope tag '$MigrationScopeTagName=true' on '$VaultName'."
        }
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
