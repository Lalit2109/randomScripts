<#
.SYNOPSIS
    Deploys the shared Action Group and the eight Activity Log Alerts from
    Design.md §5.2/§5.3, scoped to a subscription. Idempotent - run once per
    subscription as it onboards to the migration; safe to re-run.

.EXAMPLE
    ./Deploy-Monitoring.ps1 -SubscriptionId <sub-id> -ActionGroupEmail platform-team@contoso.com
#>

param(
    [Parameter(Mandatory)] [string] $SubscriptionId,
    [Parameter(Mandatory)] [string] $ActionGroupEmail,
    [string] $ActionGroupName = "ag-keyvault-migration",
    [string] $ActionGroupShortName = "kvmigrate"
)

$ErrorActionPreference = "Stop"
Set-AzContext -SubscriptionId $SubscriptionId | Out-Null

# --- Action Group ---
$emailReceiver = New-AzActionGroupReceiver -Name "PlatformTeamEmail" -EmailReceiver -EmailAddress $ActionGroupEmail
$actionGroup = Set-AzActionGroup `
    -ResourceGroupName "rg-platform-monitoring" `
    -Name $ActionGroupName `
    -ShortName $ActionGroupShortName `
    -Receiver $emailReceiver
Write-Host "Action Group '$ActionGroupName' deployed/updated."

$scope = "/subscriptions/$SubscriptionId"

# --- Activity Log Alerts (Design.md §5.2) ---
$alertDefinitions = @(
    @{ Name = "kv-deleted";              Operation = "Microsoft.KeyVault/vaults/delete";                Severity = 0 }
    @{ Name = "kv-firewall-changed";     Operation = "Microsoft.KeyVault/vaults/write";                  Severity = 1 }
    @{ Name = "kv-access-policy-changed";Operation = "Microsoft.KeyVault/vaults/accessPolicies/write";   Severity = 1 }
    @{ Name = "kv-rbac-write-changed";   Operation = "Microsoft.Authorization/roleAssignments/write";    Severity = 1 }
    @{ Name = "kv-rbac-delete-changed";  Operation = "Microsoft.Authorization/roleAssignments/delete";   Severity = 1 }
    @{ Name = "kv-diagnostics-removed";  Operation = "Microsoft.Insights/diagnosticSettings/delete";     Severity = 1 }
    @{ Name = "kv-private-endpoint-created"; Operation = "Microsoft.Network/privateEndpoints/write";     Severity = 1 }
)

foreach ($def in $alertDefinitions) {
    $condition = New-AzActivityLogAlertCondition -Field "operationName" -Equal $def.Operation
    $actionGroupObj = New-AzActivityLogAlertActionGroupObject -Id $actionGroup.Id

    Set-AzActivityLogAlert `
        -Location "Global" `
        -ResourceGroupName "rg-platform-monitoring" `
        -Name "alert-$($def.Name)" `
        -Scope $scope `
        -Condition $condition `
        -Action $actionGroupObj `
        -Description "Key Vault migration monitoring: $($def.Operation)" | Out-Null

    Write-Host "Activity Log Alert 'alert-$($def.Name)' deployed for $($def.Operation)."
}

Write-Host ""
Write-Host "Note: 'Firewall changed' and 'Network ACL modified' both key off Microsoft.KeyVault/vaults/write (see Design.md §5.2 note - Key Vault has no separate operation for network ACL changes specifically)."
Write-Host "Note: 'Public network access enabled' is primarily monitored via Azure Policy audit (Design.md §6.2), not a dedicated Activity Log Alert - Activity Log alone can't cleanly diff property values."
Write-Host ""
Write-Host "Test the Action Group's routing before relying on it:"
Write-Host "  az monitor action-group test-notifications create --action-group-name $ActionGroupName --resource-group rg-platform-monitoring --notification-type email --receivers PlatformTeamEmail"
