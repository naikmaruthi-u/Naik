terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
  }
}

# ─── Variables ────────────────────────────────────────────────────────────────
variable "resource_group_name" { type = string }
variable "location"            { type = string }
variable "prefix"              { type = string; default = "demo" }
variable "vm_resource_id"      { type = string; description = "Resource ID of the VM to monitor" }
variable "alert_email"         { type = string; description = "Email for alert notifications" }
variable "tags"                { type = map(string); default = {} }

# ─── Log Analytics Workspace ──────────────────────────────────────────────────
resource "azurerm_log_analytics_workspace" "law" {
  name                = "${var.prefix}-law"
  location            = var.location
  resource_group_name = var.resource_group_name
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = var.tags
}

# ─── Action Group (email alerts) ──────────────────────────────────────────────
resource "azurerm_monitor_action_group" "ag" {
  name                = "${var.prefix}-alert-ag"
  resource_group_name = var.resource_group_name
  short_name          = "alertag"

  email_receiver {
    name          = "ops-team"
    email_address = var.alert_email
  }

  tags = var.tags
}

# ─── CPU Alert ────────────────────────────────────────────────────────────────
resource "azurerm_monitor_metric_alert" "cpu_alert" {
  name                = "${var.prefix}-alert-cpu-high"
  resource_group_name = var.resource_group_name
  scopes              = [var.vm_resource_id]
  description         = "Alert when CPU exceeds 85% for 5 minutes"
  severity            = 2
  frequency           = "PT1M"
  window_size         = "PT5M"
  tags                = var.tags

  criteria {
    metric_namespace = "Microsoft.Compute/virtualMachines"
    metric_name      = "Percentage CPU"
    aggregation      = "Average"
    operator         = "GreaterThan"
    threshold        = 85
  }

  action {
    action_group_id = azurerm_monitor_action_group.ag.id
  }
}

# ─── Memory Alert ─────────────────────────────────────────────────────────────
resource "azurerm_monitor_metric_alert" "memory_alert" {
  name                = "${var.prefix}-alert-memory-high"
  resource_group_name = var.resource_group_name
  scopes              = [var.vm_resource_id]
  description         = "Alert when available memory drops below 500 MB"
  severity            = 2
  frequency           = "PT1M"
  window_size         = "PT5M"
  tags                = var.tags

  criteria {
    metric_namespace = "Microsoft.Compute/virtualMachines"
    metric_name      = "Available Memory Bytes"
    aggregation      = "Average"
    operator         = "LessThan"
    threshold        = 524288000  # 500 MB in bytes
  }

  action {
    action_group_id = azurerm_monitor_action_group.ag.id
  }
}

# ─── OS Disk Read Latency Alert ───────────────────────────────────────────────
resource "azurerm_monitor_metric_alert" "disk_latency_alert" {
  name                = "${var.prefix}-alert-disk-latency"
  resource_group_name = var.resource_group_name
  scopes              = [var.vm_resource_id]
  description         = "Alert when OS disk read latency exceeds 50ms"
  severity            = 3
  frequency           = "PT5M"
  window_size         = "PT15M"
  tags                = var.tags

  criteria {
    metric_namespace = "Microsoft.Compute/virtualMachines"
    metric_name      = "OS Disk Read Operations/Sec"
    aggregation      = "Average"
    operator         = "GreaterThan"
    threshold        = 50
  }

  action {
    action_group_id = azurerm_monitor_action_group.ag.id
  }
}

# ─── VM Availability Alert ────────────────────────────────────────────────────
resource "azurerm_monitor_metric_alert" "availability_alert" {
  name                = "${var.prefix}-alert-vm-availability"
  resource_group_name = var.resource_group_name
  scopes              = [var.vm_resource_id]
  description         = "Alert when VM availability drops below 1 (VM is down)"
  severity            = 1
  frequency           = "PT1M"
  window_size         = "PT5M"
  tags                = var.tags

  criteria {
    metric_namespace = "Microsoft.Compute/virtualMachines"
    metric_name      = "VmAvailabilityMetric"
    aggregation      = "Average"
    operator         = "LessThan"
    threshold        = 1
  }

  action {
    action_group_id = azurerm_monitor_action_group.ag.id
  }
}

# ─── Outputs ──────────────────────────────────────────────────────────────────
output "law_workspace_id" {
  description = "Log Analytics Workspace ID"
  value       = azurerm_log_analytics_workspace.law.workspace_id
}

output "law_resource_id" {
  description = "Resource ID of the Log Analytics Workspace"
  value       = azurerm_log_analytics_workspace.law.id
}

output "action_group_id" {
  description = "Resource ID of the Monitor Action Group"
  value       = azurerm_monitor_action_group.ag.id
}
