# Monthly Patching Runbook - Azure Windows VMs

| Field | Value |
|-------|-------|
| **Document Owner** | Cloud Infrastructure Team |
| **Review Cadence** | Quarterly |
| **Last Updated** | June 2026 |
| **Applies To** | Azure Windows Server 2016 / 2019 / 2022 VMs |
| **ServiceNow Process** | Change Management - Standard Change |

---

## Table of Contents

1. [Overview](#overview)
2. [Pre-Patching Checklist](#pre-patching-checklist)
3. [ServiceNow Change Request](#servicenow-change-request)
4. [Patching Procedure](#patching-procedure)
5. [Post-Patching Validation](#post-patching-validation)
6. [Rollback Procedure](#rollback-procedure)
7. [Escalation Matrix](#escalation-matrix)

---

## 1. Overview

This runbook defines the end-to-end procedure for applying monthly security patches to Azure Windows VMs using **Azure Update Manager**. Patches are applied during the approved maintenance window on the **2nd Saturday of each month, 11 PM - 3 AM UTC**.

### Patching Strategy

| Tier | Servers | Window | Approach |
|------|---------|--------|----------|
| **Dev/Test** | Non-prod VMs | Week 1 - any weeknight | Automated (no approval) |
| **Staging** | Pre-prod VMs | Week 2 - Saturday 11 PM | Semi-automated (approval required) |
| **Production** | Prod VMs | Week 3 - Saturday 11 PM | Manual + automated with approval |

---

## 2. Pre-Patching Checklist

Complete **all** items at least **48 hours before** the maintenance window.

### 2.1 Infrastructure Pre-Checks

- [ ] Verify Azure Update Manager patch assessment is up to date (< 24 hours old)
- [ ] Review and triage identified patches - defer P0 critical patches to emergency window if needed
- [ ] Confirm VM backup job completed successfully within the last 24 hours
```powershell
# Verify backup and health status
.\powershell\azure-health-check.ps1 -ResourceGroupName "rg-prod" -VMName "vm-web-01"
```
- [ ] Run health check script and resolve any WARN/FAIL findings
- [ ] Verify VM CPU and memory are within normal thresholds (< 80%)
- [ ] Ensure no active deployments or releases are scheduled during the window
- [ ] Confirm monitoring alerts are active and on-call engineer is aware

### 2.2 Application Pre-Checks

- [ ] Notify application owners 48 hours in advance via email/Teams
- [ ] Confirm application health endpoints return HTTP 200
- [ ] Record baseline metrics: response time, error rate, active sessions
- [ ] Verify application gracefully handles VM restart (session persistence, etc.)
- [ ] Confirm database connections will auto-reconnect after reboot

### 2.3 Snapshot / Backup Verification

- [ ] Azure VM Backup - confirm latest restore point < 24 hours
- [ ] OS Disk snapshot (optional for critical VMs):
```powershell
$vm  = Get-AzVM -ResourceGroupName "rg-prod" -Name "vm-web-01"
$diskId = $vm.StorageProfile.OsDisk.ManagedDisk.Id
New-AzSnapshot -ResourceGroupName "rg-prod" -SnapshotName "vm-web-01-pre-patch-$(Get-Date -Format yyyyMMdd)" \
  -Snapshot (New-AzSnapshotConfig -SourceResourceId $diskId -Location "eastus" -CreateOption Copy)
```

---

## 3. ServiceNow Change Request

### 3.1 Opening a Standard Change

1. Navigate to **ServiceNow > Change Management > Create New**
2. Select template: `STD-CHG-AZURE-MONTHLY-PATCH`
3. Fill in required fields:

| Field | Value |
|-------|-------|
| **Short Description** | Monthly Azure VM Patching - [Month Year] |
| **Category** | Infrastructure |
| **Type** | Standard |
| **Risk** | Low |
| **Impact** | Medium |
| **Assignment Group** | Cloud Infrastructure |
| **Planned Start** | [Maintenance window start time] |
| **Planned End** | [Maintenance window end time] |
| **CIs Affected** | List all VM names from CMDB |

4. Attach the patch assessment report (CSV from `patch-report.ps1`)
5. Submit for **CAB auto-approval** (Standard Change templates skip full CAB review)

### 3.2 Change State Flow

```
Draft -> Scheduled -> In Progress -> Review -> Closed (Complete/Failed)
```

---

## 4. Patching Procedure

### 4.1 Using Azure Update Manager (Recommended)

1. Open **Azure Portal > Azure Update Manager > Machines**
2. Filter by Resource Group and select target VMs
3. Click **One-time update** > Select patches:
   - Classification: Critical, Security
   - Reboot: **IfRequired**
   - Max patch time: **120 minutes**
4. Schedule for maintenance window or trigger immediately
5. Monitor progress in **Update Manager > History**

### 4.2 Using PowerShell (Alternative)

```powershell
# Trigger assessment first
Invoke-AzVMPatchAssessment -ResourceGroupName "rg-prod" -VMName "vm-web-01"

# Apply Critical + Security patches
$patchResult = Start-AzVMGuestPatchInstallation \
  -ResourceGroupName "rg-prod" \
  -VMName "vm-web-01" \
  -Mode "IfRequired" \
  -MaximumDuration "PT2H" \
  -ClassificationToInclude @("Critical","Security") \
  -RebootSetting "IfRequired"

$patchResult | Select-Object Status, PatchesInstalled, RebootStatus
```

---

## 5. Post-Patching Validation

Complete within **30 minutes of maintenance window close**.

### 5.1 System Validation

- [ ] VM is in **Running** state in Azure Portal
- [ ] Boot diagnostics show clean startup (no STOP errors)
- [ ] Run post-patch health check:
```powershell
.\powershell\azure-health-check.ps1 -ResourceGroupName "rg-prod" -VMName "vm-web-01"
```
- [ ] Verify all expected Windows Services are in Running state
- [ ] Confirm no pending Windows Update requiring additional reboot

### 5.2 Application Validation

- [ ] Application health endpoint returns HTTP 200
- [ ] Response times within 10% of pre-patch baseline
- [ ] Error rate is at or below pre-patch levels
- [ ] Verify application logs show no new errors post-restart
- [ ] Notify application owners - patching complete

### 5.3 Documentation

- [ ] Generate final patch compliance report:
```powershell
.\powershell\patch-report.ps1 -SubscriptionId "xxxx" -ResourceGroupName "rg-prod"
```
- [ ] Attach report to ServiceNow Change Request
- [ ] Update Change state to **Review**
- [ ] Close Change as **Successful** or **Partially Successful**

---

## 6. Rollback Procedure

Use the rollback procedure if post-patch validation fails and the issue cannot be resolved within **30 minutes**.

### 6.1 Decision Criteria for Rollback

Trigger rollback if any of the following occur:
- Application health checks fail and cannot be resolved
- VM fails to boot or becomes unreachable
- Critical services fail to start after reboot
- Data corruption or database connectivity loss

### 6.2 Rollback Steps

**Option A - Azure Backup Restore (Recommended)**

1. Navigate to **Azure Portal > Recovery Services Vault**
2. Select the VM backup item
3. Click **Restore VM** > **Replace existing disk**
4. Select the restore point taken **before** the patch window
5. Confirm restore (VM will be unavailable for 15-45 minutes)

**Option B - OS Disk Snapshot Restore**

```powershell
# 1. Stop the VM
Stop-AzVM -ResourceGroupName "rg-prod" -Name "vm-web-01" -Force

# 2. Get pre-patch snapshot
$snapshot = Get-AzSnapshot -ResourceGroupName "rg-prod" -SnapshotName "vm-web-01-pre-patch-20260615"

# 3. Create new managed disk from snapshot
$diskConfig = New-AzDiskConfig -Location "eastus" -CreateOption Copy -SourceResourceId $snapshot.Id -SkuName Premium_LRS
$newDisk = New-AzDisk -ResourceGroupName "rg-prod" -DiskName "vm-web-01-restored-osdisk" -Disk $diskConfig

# 4. Swap OS disk
$vm = Get-AzVM -ResourceGroupName "rg-prod" -Name "vm-web-01"
Set-AzVMOSDisk -VM $vm -ManagedDiskId $newDisk.Id -Name $newDisk.Name
Update-AzVM -ResourceGroupName "rg-prod" -VM $vm

# 5. Start VM
Start-AzVM -ResourceGroupName "rg-prod" -Name "vm-web-01"
```

### 6.3 Post-Rollback Actions

- [ ] Validate application health after rollback
- [ ] Document rollback in ServiceNow Change Request
- [ ] Update Change state to **Review > Closed (Unsuccessful)**
- [ ] Create Problem record to track root cause
- [ ] Schedule investigation before next patch cycle

---

## 7. Escalation Matrix

| Severity | Scenario | Primary Contact | Escalate To | Response SLA |
|----------|----------|-----------------|-------------|--------------|
| **P1** | VM down, application unavailable | On-Call Engineer | Cloud Lead + App Owner | 15 minutes |
| **P2** | Degraded performance post-patch | On-Call Engineer | Cloud Lead | 30 minutes |
| **P3** | Non-critical service failure | On-Call Engineer | Cloud Lead (next business day) | 2 hours |

---

*Document maintained by the Cloud Infrastructure Team. For questions, open a ServiceNow ticket with category: Cloud Infrastructure.*
