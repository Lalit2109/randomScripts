<#
.SYNOPSIS
    Deploys the individual policy definitions (policies/definitions/*.json),
    combines them into the initiative (policies/initiative/*.json), and
    assigns it at a given management group or subscription scope.
    Idempotent - creates or updates definitions/initiative/assignment by name.

.EXAMPLE
    ./Deploy-PolicyInitiative.ps1 -ManagementGroupId mg-keyvault-migration `
        -LogAnalyticsWorkspaceId /subscriptions/.../workspaces/law-platform `
        -EnforcementMode DoNotEnforce
#>

param(
    [string] $ManagementGroupId,
    [string] $SubscriptionId,
    [Parameter(Mandatory)] [string] $LogAnalyticsWorkspaceId,
    [string[]] $ExcludedVaultIds = @(),
    [ValidateSet("Default", "DoNotEnforce")] [string] $EnforcementMode = "DoNotEnforce",
    [ValidateSet("Deny", "Audit", "Disabled")] [string] $DenyPolicyEffect = "Audit"
)

$ErrorActionPreference = "Stop"

if (-not $ManagementGroupId -and -not $SubscriptionId) {
    throw "Provide either -ManagementGroupId or -SubscriptionId as the assignment scope."
}

$definitionsDir = Join-Path (Split-Path $PSScriptRoot -Parent) "..\policies\definitions" | Resolve-Path
$initiativeFile = Join-Path (Split-Path $PSScriptRoot -Parent) "..\policies\initiative\keyvault-service-endpoint-initiative.json" | Resolve-Path

$scopeParam = if ($ManagementGroupId) { @{ ManagementGroupName = $ManagementGroupId } } else { @{ SubscriptionId = $SubscriptionId } }

# --- Deploy individual policy definitions ---
$definitionRefs = @()
Get-ChildItem -Path $definitionsDir -Filter "*.json" | ForEach-Object {
    $def = Get-Content $_.FullName -Raw | ConvertFrom-Json
    $policyDef = New-AzPolicyDefinition `
        -Name $def.name `
        -DisplayName $def.properties.displayName `
        -Description $def.properties.description `
        -Policy ($def.properties.policyRule | ConvertTo-Json -Depth 20) `
        -Parameter ($def.properties.parameters | ConvertTo-Json -Depth 20) `
        @scopeParam
    $definitionRefs += $policyDef
    Write-Host "Policy definition deployed: $($def.name)"
}

# --- Deploy the initiative (policy set definition) referencing all of the above ---
$initiativeSource = Get-Content $initiativeFile -Raw | ConvertFrom-Json
$policyDefinitionsJson = ($definitionRefs | ForEach-Object {
    @{ policyDefinitionId = $_.PolicyDefinitionId; policyDefinitionReferenceId = $_.Name }
}) | ConvertTo-Json -Depth 10

$initiative = New-AzPolicySetDefinition `
    -Name $initiativeSource.name `
    -DisplayName $initiativeSource.properties.displayName `
    -Description $initiativeSource.properties.description `
    -Parameter ($initiativeSource.properties.parameters | ConvertTo-Json -Depth 20) `
    -PolicyDefinition $policyDefinitionsJson `
    @scopeParam

Write-Host "Policy initiative deployed: $($initiativeSource.name)"

# --- Assign the initiative ---
$assignmentParams = @{
    denyPolicyEffect        = @{ value = $DenyPolicyEffect }
    excludedVaultIds         = @{ value = $ExcludedVaultIds }
    logAnalyticsWorkspaceId = @{ value = $LogAnalyticsWorkspaceId }
}

$assignmentScope = if ($ManagementGroupId) { "/providers/Microsoft.Management/managementGroups/$ManagementGroupId" } else { "/subscriptions/$SubscriptionId" }

New-AzPolicyAssignment `
    -Name "assign-keyvault-se-migration" `
    -DisplayName "Key Vault Service Endpoint Migration Initiative" `
    -PolicySetDefinition $initiative `
    -Scope $assignmentScope `
    -PolicyParameterObject $assignmentParams `
    -EnforcementMode $EnforcementMode | Out-Null

Write-Host "Initiative assigned at scope '$assignmentScope' with EnforcementMode = $EnforcementMode, DenyPolicyEffect = $DenyPolicyEffect."
Write-Host "Excluded vaults: $($ExcludedVaultIds.Count)"
