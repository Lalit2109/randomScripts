<#
.SYNOPSIS
    Ensures a Key Vault has a Diagnostic Setting sending AuditEvent logs and
    all metrics to Log Analytics (and optionally Event Hub / Storage).
    Idempotent - updates the existing setting if one already exists under
    the given name rather than creating a duplicate.

.EXAMPLE
    ./Set-DiagnosticSettings.ps1 -VaultName my-vault `
        -LogAnalyticsWorkspaceId /subscriptions/.../workspaces/law-platform
#>

param(
    [Parameter(Mandatory)] [string] $VaultName,
    [string] $ResourceGroupName,
    [Parameter(Mandatory)] [string] $LogAnalyticsWorkspaceId,
    [string] $EventHubAuthorizationRuleId,
    [string] $StorageAccountId,
    [string] $SettingName = "keyvault-migration-diagnostics"
)

$ErrorActionPreference = "Stop"

if (-not $ResourceGroupName) {
    $vault = Get-AzKeyVault -VaultName $VaultName
    if (-not $vault) { throw "Key Vault '$VaultName' not found in current subscription context." }
    $ResourceGroupName = $vault.ResourceGroupName
}
$vaultResource = Get-AzResource -ResourceGroupName $ResourceGroupName -ResourceType "Microsoft.KeyVault/vaults" -ResourceName $VaultName

$logParams = @{
    ResourceId              = $vaultResource.ResourceId
    Name                    = $SettingName
    WorkspaceId             = $LogAnalyticsWorkspaceId
    Enabled                 = $true
    Category                = @("AuditEvent")
    MetricCategory          = @("AllMetrics")
}
if ($EventHubAuthorizationRuleId) { $logParams["EventHubAuthorizationRuleId"] = $EventHubAuthorizationRuleId }
if ($StorageAccountId)            { $logParams["StorageAccountId"] = $StorageAccountId }

$existing = Get-AzDiagnosticSetting -ResourceId $vaultResource.ResourceId -Name $SettingName -ErrorAction SilentlyContinue
if ($existing) {
    Write-Host "Diagnostic setting '$SettingName' already exists on '$VaultName' - updating."
}

New-AzDiagnosticSetting @logParams | Out-Null

Write-Host "Diagnostic setting '$SettingName' active on '$VaultName' -> Log Analytics workspace $LogAnalyticsWorkspaceId"
