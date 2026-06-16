# ─── General ──────────────────────────────────────────────────────────────────
variable "resource_group_name" {
  description = "Name of the Azure Resource Group"
  type        = string
  default     = "rg-azure-vm-demo"
}

variable "location" {
  description = "Azure region for all resources"
  type        = string
  default     = "eastus"
}

variable "prefix" {
  description = "Prefix used for naming all resources"
  type        = string
  default     = "demo"
}

variable "tags" {
  description = "A map of tags to apply to all resources"
  type        = map(string)
  default = {
    Environment = "Demo"
    ManagedBy   = "Terraform"
    Owner       = "naikmaruthi-u"
    CostCenter  = "IT-Infra"
  }
}

# ─── Networking ───────────────────────────────────────────────────────────────
variable "vnet_address_space" {
  description = "Address space for the Virtual Network"
  type        = string
  default     = "10.0.0.0/16"
}

variable "subnet_address_prefix" {
  description = "Address prefix for the Subnet"
  type        = string
  default     = "10.0.1.0/24"
}

variable "allowed_rdp_source" {
  description = "Source IP/CIDR allowed for RDP access (use your public IP)"
  type        = string
  default     = "10.0.0.0/8"
}

variable "create_public_ip" {
  description = "Whether to create and attach a Public IP to the VM"
  type        = bool
  default     = false
}

# ─── Virtual Machine ──────────────────────────────────────────────────────────
variable "vm_size" {
  description = "Azure VM SKU size"
  type        = string
  default     = "Standard_B2s"
}

variable "admin_username" {
  description = "Local administrator username for the Windows VM"
  type        = string
  default     = "azureadmin"
  sensitive   = false
}

variable "admin_password" {
  description = "Local administrator password for the Windows VM"
  type        = string
  sensitive   = true
}

variable "windows_sku" {
  description = "Windows Server marketplace SKU"
  type        = string
  default     = "2022-datacenter-g2"

  validation {
    condition = contains([
      "2016-datacenter-gensecond",
      "2019-datacenter-gensecond",
      "2022-datacenter-g2",
      "2022-datacenter-azure-edition"
    ], var.windows_sku)
    error_message = "windows_sku must be a supported Windows Server Gen2 image SKU."
  }
}

# ─── OS Disk ──────────────────────────────────────────────────────────────────
variable "os_disk_sku" {
  description = "Storage account type for the OS disk"
  type        = string
  default     = "Premium_LRS"

  validation {
    condition     = contains(["Standard_LRS", "StandardSSD_LRS", "Premium_LRS"], var.os_disk_sku)
    error_message = "os_disk_sku must be Standard_LRS, StandardSSD_LRS, or Premium_LRS."
  }
}

variable "os_disk_size_gb" {
  description = "Size in GB for the OS disk (minimum 128 GB for Windows Server)"
  type        = number
  default     = 128
}

# ─── Data Disk ────────────────────────────────────────────────────────────────
variable "data_disk_sku" {
  description = "Storage account type for the managed data disk"
  type        = string
  default     = "Premium_LRS"
}

variable "data_disk_size_gb" {
  description = "Size in GB for the managed data disk"
  type        = number
  default     = 64
}

# ─── Auto-Shutdown ────────────────────────────────────────────────────────────
variable "auto_shutdown_time" {
  description = "Daily auto-shutdown time in HHMM format (e.g. '1900' for 7 PM)"
  type        = string
  default     = "1900"
}

variable "auto_shutdown_timezone" {
  description = "Timezone for the auto-shutdown schedule"
  type        = string
  default     = "UTC"
}

variable "auto_shutdown_notify" {
  description = "Whether to send email notification before auto-shutdown"
  type        = bool
  default     = false
}

variable "auto_shutdown_email" {
  description = "Email address for auto-shutdown notification"
  type        = string
  default     = ""
}
