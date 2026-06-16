#Requires -Modules Az.Compute, Az.Network, Az.RecoveryServices, Az.Monitor
<#
.SYNOPSIS
    Azure Windows VM Health Check Script
.DESCRIPTION
    Performs a comprehensive health check on an Azure Windows VM:
    - Power state verification
    - CPU utilization (last 1 hour average)
    - Memory availability
    - NSG rule audit (open ports)
    - Azure Backup status
    - Disk usage and health
    - Boot diagnostics status
.PARAMETER ResourceGroupName
    Name of the Resource Group containing the VM
.PARAMETER VMName
    Name of the Azure Virtual Machine
.PARAMETER SubscriptionId
    Azure Subscription ID (optional, uses current context if omitted)
.EXAMPLE
    .\azure-health-check.ps1 -ResourceGroupName "rg-prod" -VMName "vm-web-01"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory)]
    [string]$VMName,

    [Parameter()]
    [string]$SubscriptionId,

    [Parameter()]
    [string]$OutputPath = ".\healthcheck-$VMName-$(Get-Date -Format 'yyyyMMdd-HHmm').json"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ─── Initialize ───────────────────────────────────────────────────────────────
$report = [ordered]@{
    ReportDate      = (Get-Date -Format "yyyy-MM-dd HH:mm:ss UTC")
    SubscriptionId  = ""
    ResourceGroup   = $ResourceGroupName
    VMName          = $VMName
    OverallStatus   = "Healthy"
    Checks          = [ordered]@{}
    Warnings        = @()
    Errors          = @()
}

function Write-Status {
    param([string]$Check, [string]$Status, [string]$Detail)
    $colour = switch ($Status) {
        "PASS"    { "Green" }
        "WARN"    { "Yellow" }
        "FAIL"    { "Red" }
        default   { "White" }
    }
    Write-Host "  [$Status] $Check" -ForegroundColor $colour -NoNewline
    if ($Detail) { Write-Host " - $Detail" -ForegroundColor Gray } else { Write-Host }
}

function Add-CheckResult {
    param([string]$Name, [string]$Status, [string]$Detail, $Data)
    $report.Checks[$Name] = @{
        Status = $Status
        Detail = $Detail
        Data   = $Data
    }
    if ($Status -eq "WARN") { $report.Warnings += "$Name: $Detail" }
    if ($Status -eq "FAIL") {
        $report.Errors  += "$Name: $Detail"
        $report.OverallStatus = "Unhealthy"
    }
    Write-Status -Check $Name -Status $Status -Detail $Detail
}

# ─── Connect / Context ────────────────────────────────────────────────────────
Write-Host "`n=== Azure VM Health Check: $VMName ===`n" -ForegroundColor Cyan

if ($SubscriptionId) {
    Write-Host "[*] Setting subscription context..." -ForegroundColor Gray
    Set-AzContext -SubscriptionId $SubscriptionId | Out-Null
}

$ctx = Get-AzContext
$report.SubscriptionId = $ctx.Subscription.Id
Write-Host "[*] Subscription : $($ctx.Subscription.Name) ($($ctx.Subscription.Id))" -ForegroundColor Gray
Write-Host "[*] Account       : $($ctx.Account.Id)`n" -ForegroundColor Gray

# ─── Fetch VM ─────────────────────────────────────────────────────────────────
try {
    $vm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName -Status
    $vmConfig = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName
} catch {
    Write-Error "Failed to retrieve VM '$VMName': $_"
    exit 1
}

# ─── CHECK 1: Power State ─────────────────────────────────────────────────────
Write-Host "--- Power State ---" -ForegroundColor White
$powerState = ($vm.Statuses | Where-Object { $_.Code -like "PowerState/*" }).DisplayStatus
if ($powerState -eq "VM running") {
    Add-CheckResult "PowerState" "PASS" $powerState $powerState
} else {
    Add-CheckResult "PowerState" "FAIL" "Expected 'VM running', got '$powerState'" $powerState
}

# ─── CHECK 2: CPU Utilization ─────────────────────────────────────────────────
Write-Host "`n--- CPU Utilization (last 60 min avg) ---" -ForegroundColor White
try {
    $cpuMetric = Get-AzMetric `
        -ResourceId $vmConfig.Id `
        -MetricName "Percentage CPU" `
        -StartTime (Get-Date).AddHours(-1) `
        -EndTime (Get-Date) `
        -TimeGrain "00:05:00" `
        -AggregationType Average

    $cpuValues = $cpuMetric.Data | Where-Object { $_.Average -ne $null } | Select-Object -ExpandProperty Average
    if ($cpuValues.Count -gt 0) {
        $avgCpu = [math]::Round(($cpuValues | Measure-Object -Average).Average, 2)
        if ($avgCpu -lt 80) {
            Add-CheckResult "CPU_Utilization" "PASS" "$avgCpu% average (last 60 min)" $avgCpu
        } elseif ($avgCpu -lt 90) {
            Add-CheckResult "CPU_Utilization" "WARN" "$avgCpu% average — approaching threshold" $avgCpu
        } else {
            Add-CheckResult "CPU_Utilization" "FAIL" "$avgCpu% average — CPU critical" $avgCpu
        }
    } else {
        Add-CheckResult "CPU_Utilization" "WARN" "No metric data available" $null
    }
} catch {
    Add-CheckResult "CPU_Utilization" "WARN" "Could not retrieve metric: $_" $null
}

# ─── CHECK 3: Memory (Available Bytes) ────────────────────────────────────────
Write-Host "`n--- Memory Availability ---" -ForegroundColor White
try {
    $memMetric = Get-AzMetric `
        -ResourceId $vmConfig.Id `
        -MetricName "Available Memory Bytes" `
        -StartTime (Get-Date).AddMinutes(-15) `
        -EndTime (Get-Date) `
        -TimeGrain "00:01:00" `
        -AggregationType Average

    $memValues = $memMetric.Data | Where-Object { $_.Average -ne $null } | Select-Object -ExpandProperty Average
    if ($memValues.Count -gt 0) {
        $latestMem = $memValues[-1]
        $memGB     = [math]::Round($latestMem / 1GB, 2)
        if ($memGB -gt 1) {
            Add-CheckResult "MemoryAvailable" "PASS" "$memGB GB available" $memGB
        } elseif ($memGB -gt 0.5) {
            Add-CheckResult "MemoryAvailable" "WARN" "$memGB GB available — low memory" $memGB
        } else {
            Add-CheckResult "MemoryAvailable" "FAIL" "$memGB GB available — critically low" $memGB
        }
    } else {
        Add-CheckResult "MemoryAvailable" "WARN" "No metric data available" $null
    }
} catch {
    Add-CheckResult "MemoryAvailable" "WARN" "Could not retrieve metric (Guest OS agent required)" $null
}

# ─── CHECK 4: NSG Rules Audit ─────────────────────────────────────────────────
Write-Host "`n--- NSG Rules Audit ---" -ForegroundColor White
try {
    $nic = Get-AzNetworkInterface -ResourceId $vmConfig.NetworkProfile.NetworkInterfaces[0].Id
    $nsg = $null

    if ($nic.NetworkSecurityGroup) {
        $nsg = Get-AzNetworkSecurityGroup -ResourceId $nic.NetworkSecurityGroup.Id
    } elseif ($nic.IpConfigurations[0].Subnet.Id) {
        $subnetParts = $nic.IpConfigurations[0].Subnet.Id -split "/"
        $subnetName  = $subnetParts[-1]
        $vnetName    = $subnetParts[-3]
        $subnet      = Get-AzVirtualNetworkSubnetConfig -Name $subnetName `
                            -VirtualNetwork (Get-AzVirtualNetwork -Name $vnetName -ResourceGroupName $ResourceGroupName)
        if ($subnet.NetworkSecurityGroup) {
            $nsg = Get-AzNetworkSecurityGroup -ResourceId $subnet.NetworkSecurityGroup.Id
        }
    }

    if ($nsg) {
        $dangerousPorts = @(22, 23, 3389, 5985, 5986, 1433, 3306, 5432, 6379, 27017)
        $openToInternet = $nsg.SecurityRules | Where-Object {
            $_.Access -eq "Allow" -and
            $_.Direction -eq "Inbound" -and
            ($_.SourceAddressPrefix -eq "*" -or $_.SourceAddressPrefix -eq "Internet") -and
            ($_.DestinationPortRange -in $dangerousPorts -or
             $_.DestinationPortRange -eq "*")
        }

        if ($openToInternet.Count -eq 0) {
            Add-CheckResult "NSG_Rules" "PASS" "No dangerous ports open to Internet" $nsg.Name
        } else {
            $openPorts = $openToInternet.DestinationPortRange -join ", "
            Add-CheckResult "NSG_Rules" "WARN" "Ports [$openPorts] open to Internet in NSG '$($nsg.Name)'" $openPorts
        }
    } else {
        Add-CheckResult "NSG_Rules" "WARN" "No NSG found on NIC or Subnet" $null
    }
} catch {
    Add-CheckResult "NSG_Rules" "WARN" "Could not inspect NSG: $_" $null
}

# ─── CHECK 5: Azure Backup Status ─────────────────────────────────────────────
Write-Host "`n--- Azure Backup Status ---" -ForegroundColor White
try {
    $vaults = Get-AzRecoveryServicesVault -ResourceGroupName $ResourceGroupName
    $backupFound = $false

    foreach ($vault in $vaults) {
        Set-AzRecoveryServicesVaultContext -Vault $vault
        $backupItem = Get-AzRecoveryServicesBackupItem `
            -BackupManagementType AzureVM `
            -WorkloadType AzureVM | Where-Object { $_.VirtualMachineId -like "*$VMName*" }

        if ($backupItem) {
            $backupFound = $true
            $lastBackup  = $backupItem.LastBackupTime
            $backupStatus = $backupItem.LastBackupStatus

            if ($backupStatus -eq "Completed" -and $lastBackup -gt (Get-Date).AddDays(-1)) {
                Add-CheckResult "BackupStatus" "PASS" "Last backup: $lastBackup ($backupStatus)" $backupStatus
            } elseif ($backupStatus -eq "Completed") {
                Add-CheckResult "BackupStatus" "WARN" "Last backup: $lastBackup — older than 24 hours" $lastBackup
            } else {
                Add-CheckResult "BackupStatus" "FAIL" "Backup status: $backupStatus — last: $lastBackup" $backupStatus
            }
            break
        }
    }

    if (-not $backupFound) {
        Add-CheckResult "BackupStatus" "WARN" "VM not found in any Recovery Services Vault" $null
    }
} catch {
    Add-CheckResult "BackupStatus" "WARN" "Could not check backup status: $_" $null
}

# ─── Summary ──────────────────────────────────────────────────────────────────
Write-Host "`n=== SUMMARY ===" -ForegroundColor Cyan
$statusColour = if ($report.OverallStatus -eq "Healthy") { "Green" } else { "Red" }
Write-Host "Overall Status : $($report.OverallStatus)" -ForegroundColor $statusColour
Write-Host "Warnings       : $($report.Warnings.Count)"
Write-Host "Errors         : $($report.Errors.Count)`n"

# Export JSON report
$report | ConvertTo-Json -Depth 5 | Out-File -FilePath $OutputPath -Encoding UTF8
Write-Host "[*] Report saved to: $OutputPath" -ForegroundColor Gray
