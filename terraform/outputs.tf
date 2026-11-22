output "resource_group_name" {
  value = azurerm_resource_group.main.name
}

output "resource_group_location" {
  value = azurerm_resource_group.main.location
}

output "key_vault_name" {
  value = azurerm_key_vault.app.name
}

output "secret_check_url" {
  value = "http://${azurerm_public_ip.lb.ip_address}/secret-check"
}