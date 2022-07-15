locals {
  is_windows_server    = (var.is_windows_image || contains(tolist([var.vm_os_simple, var.vm_os_offer]), "WindowsServer"))
  windows_server_count = local.is_windows_server ? var.nb_instances : 0
}
