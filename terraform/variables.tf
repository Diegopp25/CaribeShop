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