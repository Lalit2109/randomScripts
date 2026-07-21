<#
.SYNOPSIS
    Reports actual Azure cost per AVD user for a Personal (dedicated) host pool.

.DESCRIPTION
    Personal host pools assign exactly one VM to one user, so cost can be
    attributed accurately (unlike pooled host pools, which need session-duration
    based allocation instead).

    Pipeline:
      1. Get-AzWvdSessionHost -> map each session host VM to its AssignedUser.
      2. Invoke-AzCostManagementQuery -> actual/amortized billed cost per
         ResourceId for the date range.
      3. Roll up VM + OS disk cost per user (VMs and managed disks are billed
         as separate resources) and export to CSV.

    This uses Azure Cost Management (not KQL / Log Analytics / Resource Graph),
    because $ cost data does not exist in either of those - only resource
    metadata does.

.NOTES
    Required modules : Az.DesktopVirtualization, Az.CostManagement, Az.Compute
    Required RBAC     : Cost Management Reader (subscription scope)

    Caveats:
      - Cost Management data has ~24-48h ingestion latency; very recent days may be incomplete.
      - Use -CostType AmortizedCost instead of ActualCost if you have Reserved
        Instances or Savings Plans, otherwise per-user cost will be skewed by
        when the RI was purchased rather than when it was consumed.
      - Windows/M365 per-user licensing (E3/E5, RDS CAL) is NOT billed through
        Azure Compute and will not appear here - track that separately if your
        laptop-vs-AVD comparison needs to include it.
      - Only VM + OS disk cost is rolled up. A NIC, extra data disks, or a
        backup vault attached to a session host will not be included unless
        added to the resource lookup in the report step below.
#>

param(
    [Parameter(Mandatory)] [string] $SubscriptionId,
    [Parameter(Mandatory)] [string] $ResourceGroupName,            # RG containing the session host VMs
    [Parameter(Mandatory)] [string] $HostPoolName,
    [Parameter(Mandatory)] [string] $HostPoolResourceGroupName,     # RG containing the host pool object (may differ from above)

    [datetime] $From = (Get-Date).AddMonths(-1).Date,
    [datetime] $To   = (Get-Date).Date,

    [ValidateSet("ActualCost", "AmortizedCost")]
    [string] $CostType = "ActualCost",

    [string] $OutCsv = "./avd-cost-per-user.csv"
)

Set-AzContext -SubscriptionId $SubscriptionId | Out-Null

# 1. Map each session host VM to its assigned user
$sessionHosts = Get-AzWvdSessionHost -ResourceGroupName $HostPoolResourceGroupName -HostPoolName $HostPoolName
$vmUserMap = @{}
foreach ($sh in $sessionHosts) {
    if (-not $sh.AssignedUser) { continue }
    $vmName = ($sh.Name -split '/')[-1]
    $vmUserMap[$vmName] = $sh.AssignedUser
}
Write-Host "Found $($vmUserMap.Count) session hosts with an assigned user."

# 2. Query actual billed cost per resource for the date range
$scope = "/subscriptions/$SubscriptionId"
$result = Invoke-AzCostManagementQuery `
    -Scope $scope `
    -Type $CostType `
    -Timeframe Custom `
    -TimePeriodFrom $From `
    -TimePeriodTo $To `
    -DatasetGranularity None `
    -DatasetAggregation @{ totalCost = @{ name = "Cost"; function = "Sum" } } `
    -DatasetGrouping @(@{ type = "Dimension"; name = "ResourceId" })

$columns = $result.Column.Name
$costByResource = @{}
foreach ($row in $result.Row) {
    $obj = @{}
    for ($i = 0; $i -lt $columns.Count; $i++) { $obj[$columns[$i]] = $row[$i] }
    $costByResource[$obj.ResourceId.ToLower()] = [double]$obj.Cost
}

# 3. Roll up VM + OS disk cost per user
$report = foreach ($vmName in $vmUserMap.Keys) {
    $vm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $vmName -ErrorAction SilentlyContinue
    if (-not $vm) { continue }

    $vmCost = 0.0
    if ($costByResource.ContainsKey($vm.Id.ToLower())) { $vmCost = $costByResource[$vm.Id.ToLower()] }

    $diskCost = 0.0
    $diskId = $vm.StorageProfile.OsDisk.ManagedDisk.Id
    if ($diskId -and $costByResource.ContainsKey($diskId.ToLower())) { $diskCost = $costByResource[$diskId.ToLower()] }

    [PSCustomObject]@{
        User        = $vmUserMap[$vmName]
        VMName      = $vmName
        ComputeCost = [math]::Round($vmCost, 2)
        DiskCost    = [math]::Round($diskCost, 2)
        TotalCost   = [math]::Round($vmCost + $diskCost, 2)
        From        = $From.ToString("yyyy-MM-dd")
        To          = $To.ToString("yyyy-MM-dd")
    }
}

$report | Sort-Object TotalCost -Descending | Format-Table -AutoSize
$report | Export-Csv -Path $OutCsv -NoTypeInformation
Write-Host "`nReport written to $OutCsv"
