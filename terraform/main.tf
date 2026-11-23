resource "azurerm_resource_group" "main" {
  name     = var.resource_group_name
  location = var.location
}

data "azurerm_client_config" "current" {}

resource "azurerm_virtual_network" "main" {
  name                = "vnet-caribeshop"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  address_space       = ["10.0.0.0/16"]
}

resource "azurerm_subnet" "app" {
  name                 = "subnet-app"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["10.0.1.0/24"]
  service_endpoints    = ["Microsoft.KeyVault"]
}

resource "azurerm_network_security_group" "app" {
  name                = "nsg-caribeshop"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
}

resource "azurerm_network_security_rule" "load_balancer_probe" {
  name                        = "allow-load-balancer-probe"
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "80"
  source_address_prefix       = "AzureLoadBalancer"
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.main.name
  network_security_group_name = azurerm_network_security_group.app.name
}

resource "azurerm_network_security_rule" "http" {
  name                        = "allow-http"
  priority                    = 110
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "80"
  source_address_prefix       = "Internet"
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.main.name
  network_security_group_name = azurerm_network_security_group.app.name
}

resource "azurerm_public_ip" "lb" {
  name                = "pip-caribeshop"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name

  allocation_method = "Static"
  sku               = "Standard"
}

resource "azurerm_lb" "main" {
  name                = "lb-caribeshop"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  sku                 = "Standard"

  frontend_ip_configuration {
    name                 = "public-ip"
    public_ip_address_id = azurerm_public_ip.lb.id
  }
}

resource "azurerm_lb_backend_address_pool" "main" {
  loadbalancer_id = azurerm_lb.main.id
  name            = "backend-pool"
}

resource "azurerm_lb_probe" "health" {
  loadbalancer_id = azurerm_lb.main.id
  name            = "health-probe"

  protocol            = "Http"
  port                = 80
  request_path        = "/health"
  interval_in_seconds = 5
  number_of_probes    = 2
}

resource "azurerm_lb_rule" "http" {
  loadbalancer_id                = azurerm_lb.main.id
  name                           = "http-rule"
  protocol                       = "Tcp"
  frontend_port                  = 80
  backend_port                   = 80
  frontend_ip_configuration_name = "public-ip"
  backend_address_pool_ids       = [azurerm_lb_backend_address_pool.main.id]
  probe_id                       = azurerm_lb_probe.health.id
}

resource "azurerm_subnet_network_security_group_association" "app" {
  subnet_id                 = azurerm_subnet.app.id
  network_security_group_id = azurerm_network_security_group.app.id
}

resource "azurerm_key_vault" "app" {
  name                = "kv-caribeshop-${substr(replace(var.subscription_id, "-", ""), 0, 8)}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tenant_id           = data.azurerm_client_config.current.tenant_id
  sku_name            = "standard"

  rbac_authorization_enabled    = true
  purge_protection_enabled      = true
  soft_delete_retention_days    = 7
  public_network_access_enabled = true

  network_acls {
    bypass                     = "None"
    default_action             = "Deny"
    ip_rules                   = [var.operator_ipv4_cidr]
    virtual_network_subnet_ids = [azurerm_subnet.app.id]
  }
}

resource "azurerm_policy_definition" "key_vault_controls" {
  name         = "deny-kv-without-security-controls"
  policy_type  = "Custom"
  mode         = "All"
  display_name = "Deny Key Vaults without RBAC and purge protection"
  description  = "Requires RBAC authorization and purge protection on Key Vaults."
  metadata     = jsonencode({ category = "Key Vault" })

  policy_rule = jsonencode({
    if = {
      allOf = [
        {
          field  = "type"
          equals = "Microsoft.KeyVault/vaults"
        },
        {
          anyOf = [
            {
              field     = "Microsoft.KeyVault/vaults/enableRbacAuthorization"
              notEquals = true
            },
            {
              field     = "Microsoft.KeyVault/vaults/enablePurgeProtection"
              notEquals = true
            }
          ]
        }
      ]
    }
    then = {
      effect = "Deny"
    }
  })
}

resource "azurerm_resource_group_policy_assignment" "key_vault_controls" {
  name                 = "deny-kv-without-controls"
  display_name         = "Deny Key Vaults without required security controls"
  description          = "Requires RBAC authorization and purge protection on Key Vaults."
  resource_group_id    = azurerm_resource_group.main.id
  policy_definition_id = azurerm_policy_definition.key_vault_controls.id
  enforce              = true
}

resource "azurerm_log_analytics_workspace" "main" {
  name                = "law-caribeshop"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
}

resource "azurerm_monitor_diagnostic_setting" "key_vault" {
  name                           = "diag-kv-caribeshop"
  target_resource_id             = azurerm_key_vault.app.id
  log_analytics_workspace_id     = azurerm_log_analytics_workspace.main.id
  log_analytics_destination_type = "Dedicated"

  enabled_log {
    category = "AuditEvent"
  }
}

resource "azurerm_role_assignment" "terraform_secrets_officer" {
  scope                = azurerm_key_vault.app.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

resource "azurerm_role_assignment" "vmss_secrets_user" {
  scope                = azurerm_key_vault.app.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_linux_virtual_machine_scale_set.app.identity[0].principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_key_vault_secret" "app" {
  name             = "caribeshop-demo"
  key_vault_id     = azurerm_key_vault.app.id
  value_wo         = var.demo_secret_value
  value_wo_version = 1
  expiration_date  = var.demo_secret_expires_at

  depends_on = [azurerm_role_assignment.terraform_secrets_officer]
}



resource "azurerm_linux_virtual_machine_scale_set" "app" {
  name                = "vmss-caribeshop"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name

  sku             = "Standard_D2s_v7" # La más económica de la región East US 2 (East US 2)
  instances       = 2
  zones           = ["1", "2", "3"]
  zone_balance    = true
  health_probe_id = azurerm_lb_probe.health.id

  automatic_instance_repair {
    enabled      = true
    grace_period = "PT10M"
    action       = "Replace"
  }

  admin_username = "azureuser"

  disable_password_authentication = true
  identity {
    type = "SystemAssigned"
  }

  admin_ssh_key {
    username   = "azureuser"
    public_key = file("~/.ssh/id_rsa.pub")
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  network_interface {
    name    = "vmssnic"
    primary = true

    ip_configuration {
      name      = "internal"
      primary   = true
      subnet_id = azurerm_subnet.app.id

      load_balancer_backend_address_pool_ids = [
        azurerm_lb_backend_address_pool.main.id
      ]
    }
  }

  custom_data = base64encode(templatefile("${path.module}/cloud-init.yaml.tftpl", {
    key_vault_uri        = azurerm_key_vault.app.vault_uri
    secret_name          = azurerm_key_vault_secret.app.name
    secret_status_script = file("${path.module}/../app/secret_status.py")
  }))

  lifecycle {
    ignore_changes = [instances]
  }
}

resource "azurerm_monitor_autoscale_setting" "app" {
  name                = "autoscale-vmss-caribeshop"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  target_resource_id  = azurerm_linux_virtual_machine_scale_set.app.id
  enabled             = true

  profile {
    name = "cpu-default"

    capacity {
      minimum = 1
      maximum = 2
      default = 1
    }

    rule {
      metric_trigger {
        metric_name        = "Percentage CPU"
        metric_resource_id = azurerm_linux_virtual_machine_scale_set.app.id
        metric_namespace   = "Microsoft.Compute/virtualMachineScaleSets"
        time_grain         = "PT1M"
        statistic          = "Average"
        time_window        = "PT5M"
        time_aggregation   = "Average"
        operator           = "GreaterThan"
        threshold          = 70
      }

      scale_action {
        direction = "Increase"
        type      = "ChangeCount"
        value     = 1
        cooldown  = "PT5M"
      }
    }

    rule {
      metric_trigger {
        metric_name        = "Percentage CPU"
        metric_resource_id = azurerm_linux_virtual_machine_scale_set.app.id
        metric_namespace   = "Microsoft.Compute/virtualMachineScaleSets"
        time_grain         = "PT1M"
        statistic          = "Average"
        time_window        = "PT10M"
        time_aggregation   = "Average"
        operator           = "LessThan"
        threshold          = 30
      }

      scale_action {
        direction = "Decrease"
        type      = "ChangeCount"
        value     = 1
        cooldown  = "PT10M"
      }
    }
  }
}

