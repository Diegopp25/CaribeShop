variable "subscription_id" {
  description = "Azure Subscription ID"
  type        = string
}

variable "location" {
  description = "Azure Region"
  type        = string
  default     = "eastus"
}

variable "resource_group_name" {
  description = "Resource Group"
  type        = string
  default     = "rg-caribeshop"
}

variable "operator_ipv4_cidr" {
  description = "Public IPv4 address of the Terraform operator in /32 CIDR notation"
  type        = string

  validation {
    condition = can(regex("^([0-9]{1,3}\\.){3}[0-9]{1,3}/32$", var.operator_ipv4_cidr)) && can(
      cidrhost(var.operator_ipv4_cidr, 0)
    )
    error_message = "operator_ipv4_cidr must be a public IPv4 host address in /32 notation."
  }
}

variable "demo_secret_value" {
  description = "Demo secret written to Key Vault; inject locally and never commit it"
  type        = string
  sensitive   = true

  validation {
    condition     = length(trimspace(var.demo_secret_value)) >= 16
    error_message = "demo_secret_value must contain at least 16 non-whitespace characters."
  }
}

variable "demo_secret_expires_at" {
  description = "Expiration timestamp for the Key Vault demo secret in RFC3339 format"
  type        = string

  validation {
    condition     = can(timeadd(var.demo_secret_expires_at, "0s"))
    error_message = "demo_secret_expires_at must be a valid RFC3339 timestamp."
  }
}