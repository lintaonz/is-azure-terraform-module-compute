module "os" {
  source       = "./os"
  vm_os_simple = var.vm_os_simple
}

data "azurerm_resource_group" "vm" {
  name = var.resource_group_name
}

locals {
  ssh_keys = compact(concat([var.ssh_key], var.extra_ssh_keys))
}

resource "random_id" "vm-sa" {
  keepers = {
    vm_hostname = var.vm_hostname
  }

  byte_length = 6
}

resource "azurerm_storage_account" "vm-sa" {
  count                    = var.boot_diagnostics ? 1 : 0
  name                     = "bootdiag${lower(random_id.vm-sa.hex)}"
  resource_group_name      = data.azurerm_resource_group.vm.name
  location                 = coalesce(var.location, data.azurerm_resource_group.vm.location)
  account_tier             = element(split("_", var.boot_diagnostics_sa_type), 0)
  account_replication_type = element(split("_", var.boot_diagnostics_sa_type), 1)
  min_tls_version          = "TLS1_2"
  tags                     = merge(var.tags, { "name" : "bootdiag${lower(random_id.vm-sa.hex)}" })
}

resource "azurerm_virtual_machine" "vm-linux" {
  count               = !contains(tolist([var.vm_os_simple, var.vm_os_offer]), "WindowsServer") && !var.is_windows_image ? var.nb_instances : 0
  name                = "${var.vm_hostname}-0${count.index + 1}"
  resource_group_name = data.azurerm_resource_group.vm.name
  location            = coalesce(var.location, data.azurerm_resource_group.vm.location)
  //availability_set_id           = azurerm_availability_set.vm.id
  vm_size                       = var.vm_size
  network_interface_ids         = [element(azurerm_network_interface.vm.*.id, count.index)]
  delete_os_disk_on_termination = var.delete_os_disk_on_termination

  dynamic "identity" {
    for_each = length(var.identity_ids) == 0 && var.identity_type == "SystemAssigned" ? [var.identity_type] : []
    content {
      type = var.identity_type
    }
  }

  dynamic "identity" {
    for_each = length(var.identity_ids) > 0 || var.identity_type == "UserAssigned" ? [var.identity_type] : []
    content {
      type         = var.identity_type
      identity_ids = length(var.identity_ids) > 0 ? var.identity_ids : []
    }
  }

  storage_image_reference {
    id        = var.vm_os_id
    publisher = var.vm_os_id == "" ? coalesce(var.vm_os_publisher, module.os.calculated_value_os_publisher) : ""
    offer     = var.vm_os_id == "" ? coalesce(var.vm_os_offer, module.os.calculated_value_os_offer) : ""
    sku       = var.vm_os_id == "" ? coalesce(var.vm_os_sku, module.os.calculated_value_os_sku) : ""
    version   = var.vm_os_id == "" ? var.vm_os_version : ""
  }

  storage_os_disk {
    name              = "osdisk-${var.vm_hostname}-0${count.index + 1}"
    create_option     = "FromImage"
    caching           = "ReadWrite"
    managed_disk_type = var.storage_account_type
  }

  dynamic "storage_data_disk" {
    for_each = range(var.nb_data_disk)
    content {
      name              = "${var.vm_hostname}-datadisk-0${count.index + 1}-${storage_data_disk.value}"
      create_option     = "Empty"
      lun               = storage_data_disk.value
      disk_size_gb      = var.data_disk_size_gb
      managed_disk_type = var.data_sa_type
    }
  }

  dynamic "storage_data_disk" {
    for_each = var.extra_disks
    content {
      name              = "${var.vm_hostname}-extradisk-0${count.index + 1}-${storage_data_disk.value.name}"
      create_option     = "Empty"
      lun               = storage_data_disk.key + var.nb_data_disk
      disk_size_gb      = storage_data_disk.value.size
      managed_disk_type = var.data_sa_type
    }
  }

  os_profile {
    computer_name  = "${var.vm_hostname}-0${count.index + 1}"
    admin_username = var.admin_username
    admin_password = var.admin_password
    custom_data    = var.custom_data
  }

  os_profile_linux_config {
    disable_password_authentication = var.enable_ssh_key

    dynamic "ssh_keys" {
      for_each = var.enable_ssh_key ? local.ssh_keys : []
      content {
        path     = "/home/${var.admin_username}/.ssh/authorized_keys"
        key_data = file(ssh_keys.value)
      }
    }

    dynamic "ssh_keys" {
      for_each = var.enable_ssh_key ? var.ssh_key_values : []
      content {
        path     = "/home/${var.admin_username}/.ssh/authorized_keys"
        key_data = ssh_keys.value
      }
    }

  }

  dynamic "os_profile_secrets" {
    for_each = var.os_profile_secrets
    content {
      source_vault_id = os_profile_secrets.value["source_vault_id"]

      vault_certificates {
        certificate_url = os_profile_secrets.value["certificate_url"]
      }
    }
  }

  tags = var.tags

  boot_diagnostics {
    enabled     = var.boot_diagnostics
    storage_uri = var.boot_diagnostics ? join(",", azurerm_storage_account.vm-sa.*.primary_blob_endpoint) : ""
  }
}

resource "azurerm_virtual_machine" "vm-windows" {
  count                         = local.windows_server_count
  name                          = "${var.vm_hostname}-0${count.index + 1}"
  resource_group_name           = data.azurerm_resource_group.vm.name
  location                      = coalesce(var.location, data.azurerm_resource_group.vm.location)
  vm_size                       = var.vm_size
  network_interface_ids         = [element(azurerm_network_interface.vm.*.id, count.index)]
  delete_os_disk_on_termination = var.delete_os_disk_on_termination
  license_type                  = var.license_type

  dynamic "identity" {
    for_each = length(var.identity_ids) == 0 && var.identity_type == "SystemAssigned" ? [var.identity_type] : []
    content {
      type = var.identity_type
    }
  }

  dynamic "identity" {
    for_each = length(var.identity_ids) > 0 || var.identity_type == "UserAssigned" ? [var.identity_type] : []
    content {
      type         = var.identity_type
      identity_ids = length(var.identity_ids) > 0 ? var.identity_ids : []
    }
  }

  storage_image_reference {
    id        = var.vm_os_id
    publisher = var.vm_os_id == "" ? coalesce(var.vm_os_publisher, module.os.calculated_value_os_publisher) : ""
    offer     = var.vm_os_id == "" ? coalesce(var.vm_os_offer, module.os.calculated_value_os_offer) : ""
    sku       = var.vm_os_id == "" ? coalesce(var.vm_os_sku, module.os.calculated_value_os_sku) : ""
    version   = var.vm_os_id == "" ? var.vm_os_version : ""
  }

  storage_os_disk {
    name              = "${var.vm_hostname}-osdisk-0${count.index + 1}"
    create_option     = "FromImage"
    caching           = "ReadWrite"
    managed_disk_type = var.storage_account_type
  }

  dynamic "storage_data_disk" {
    for_each = range(var.nb_data_disk)
    content {
      name              = "${var.vm_hostname}-datadisk-0${count.index + 1}-${storage_data_disk.value}"
      create_option     = "Empty"
      lun               = storage_data_disk.value
      disk_size_gb      = var.data_disk_size_gb
      managed_disk_type = var.data_sa_type
    }
  }

  dynamic "storage_data_disk" {
    for_each = var.extra_disks
    content {
      name              = "${var.vm_hostname}-extradisk-0${count.index + 1}-${storage_data_disk.value.name}"
      create_option     = "Empty"
      lun               = storage_data_disk.key + var.nb_data_disk
      disk_size_gb      = storage_data_disk.value.size
      managed_disk_type = var.data_sa_type
    }
  }

  os_profile {
    computer_name  = "${var.vm_hostname}-0${count.index + 1}"
    admin_username = var.admin_username
    admin_password = var.admin_password
  }
  tags = merge(var.tags, { "name" : "${var.vm_hostname}-0${count.index + 1}" })

  os_profile_windows_config {
    enable_automatic_upgrades = var.enable_automatic_upgrades
    provision_vm_agent        = true
    timezone                  = "New Zealand Standard Time"
  }

  dynamic "os_profile_secrets" {
    for_each = var.os_profile_secrets
    content {
      source_vault_id = os_profile_secrets.value["source_vault_id"]

      vault_certificates {
        certificate_url   = os_profile_secrets.value["certificate_url"]
        certificate_store = os_profile_secrets.value["certificate_store"]
      }
    }
  }

  boot_diagnostics {
    enabled     = var.boot_diagnostics
    storage_uri = var.boot_diagnostics ? join(",", azurerm_storage_account.vm-sa.*.primary_blob_endpoint) : ""
  }
}

/*resource "azurerm_availability_set" "vm" {
  name                         = "${var.vm_hostname}-avset"
  resource_group_name          = data.azurerm_resource_group.vm.name
  location                     = coalesce(var.location, data.azurerm_resource_group.vm.location)
  platform_fault_domain_count  = 2
  platform_update_domain_count = 2
  managed                      = true
  tags                         = var.tags
}*/

resource "azurerm_public_ip" "vm" {
  count               = var.nb_public_ip
  name                = "${var.vm_hostname}-pip-0${count.index + 1}"
  resource_group_name = data.azurerm_resource_group.vm.name
  location            = coalesce(var.location, data.azurerm_resource_group.vm.location)
  allocation_method   = var.allocation_method
  sku                 = var.public_ip_sku
  domain_name_label   = element(var.public_ip_dns, count.index)
  tags                = merge(var.tags, { "name" : "${var.vm_hostname}-pip-0${count.index + 1}" })
}

// Dynamic public ip address will be got after it's assigned to a vm
data "azurerm_public_ip" "vm" {
  count               = var.nb_public_ip
  name                = azurerm_public_ip.vm[count.index].name
  resource_group_name = data.azurerm_resource_group.vm.name
  depends_on          = [azurerm_virtual_machine.vm-linux, azurerm_virtual_machine.vm-windows]
}

/*resource "azurerm_network_security_group" "vm" {
  name                = "${var.vm_hostname}-nsg"
  resource_group_name = data.azurerm_resource_group.vm.name
  location            = coalesce(var.location, data.azurerm_resource_group.vm.location)

  tags = var.tags
}

resource "azurerm_network_security_rule" "vm" {
  count                       = var.remote_port != "" ? 1 : 0
  name                        = "allow_remote_${coalesce(var.remote_port, module.os.calculated_remote_port)}_in_all"
  resource_group_name         = data.azurerm_resource_group.vm.name
  description                 = "Allow remote protocol in from all locations"
  priority                    = 101
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = coalesce(var.remote_port, module.os.calculated_remote_port)
  source_address_prefixes     = var.source_address_prefixes
  destination_address_prefix  = "*"
  network_security_group_name = azurerm_network_security_group.vm.name
} */

resource "azurerm_network_interface" "vm" {
  count                         = var.nb_instances
  name                          = "${var.vm_hostname}-nic-0${count.index + 1}"
  resource_group_name           = data.azurerm_resource_group.vm.name
  location                      = coalesce(var.location, data.azurerm_resource_group.vm.location)
  enable_accelerated_networking = var.enable_accelerated_networking

  ip_configuration {
    name                          = "${var.vm_hostname}-ip-0${count.index + 1}"
    subnet_id                     = var.vnet_subnet_id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = length(azurerm_public_ip.vm.*.id) > 0 ? element(concat(azurerm_public_ip.vm.*.id, tolist([""])), count.index) : ""
  }

  tags = merge(var.tags, { "name" : "${var.vm_hostname}-ip-0${count.index + 1}" })
}

##Run ps script on vm
resource "azurerm_virtual_machine_extension" "ps_extension" {
  count                = local.windows_server_count
  virtual_machine_id   = length(azurerm_virtual_machine.vm-windows.*.id) > 0 ? element(concat(azurerm_virtual_machine.vm-windows.*.id, tolist([""])), count.index) : ""
  name                 = "${var.vm_hostname}-0${count.index + 1}-psscript"
  publisher            = "Microsoft.Compute"
  type                 = "CustomScriptExtension"
  type_handler_version = "1.10"

  settings = <<SETTINGS
    {
        "fileUris": ["https://${var.storage_name}.blob.core.windows.net/scripts/scripts.ps1"]
    }
    SETTINGS

  protected_settings = <<PROTECTED_SETTINGS
    {
      "commandToExecute"  : "powershell -ExecutionPolicy Unrestricted -File scripts.ps1 -storageAccountKey ${var.storage_key}",
      "storageAccountName": "${var.storage_name}",
      "storageAccountKey" : "${var.storage_key}"
    }
    PROTECTED_SETTINGS
  depends_on         = [time_sleep.wait_300_seconds]
  tags               = merge(var.tags, { "name" : "${var.vm_hostname}-0${count.index + 1}-psscript" })

  timeouts {
    create = var.azurerm_virtual_machine_extension_create_timeout
  }
}

## add VM to domain
resource "azurerm_virtual_machine_extension" "add_domain" {
  count                = local.windows_server_count
  virtual_machine_id   = length(azurerm_virtual_machine.vm-windows.*.id) > 0 ? element(concat(azurerm_virtual_machine.vm-windows.*.id, tolist([""])), count.index) : ""
  name                 = "${var.vm_hostname}-0${count.index + 1}-addtodomain"
  publisher            = "Microsoft.Compute"
  type                 = "JsonADDomainExtension"
  type_handler_version = "1.3"

  settings = <<SETTINGS
      {
          "Name": "thewarehousegroup.net",
          "User": "thewarehousegroup.net\\${var.domain_admin_user}",
          "Restart": "true",
          "Options": "3"
      }
  SETTINGS

  protected_settings = <<PROTECTED_SETTINGS
      {
          "Password": "${var.domain_admin_password}"
      }
  PROTECTED_SETTINGS
  depends_on         = [azurerm_virtual_machine.vm-windows]
  tags               = merge(var.tags, { "name" : "${var.vm_hostname}-0${count.index + 1}-addtodomain" })

  timeouts {
    create = var.azurerm_virtual_machine_extension_create_timeout
  }
}

resource "time_sleep" "wait_300_seconds" {
  count      = local.windows_server_count
  depends_on = [azurerm_virtual_machine_extension.add_domain]

  create_duration = "300s"
}
/*resource "azurerm_network_interface_security_group_association" "test" {
  count                     = var.nb_instances
  network_interface_id      = azurerm_network_interface.vm[count.index].id
  network_security_group_id = azurerm_network_security_group.vm.id
}*/
