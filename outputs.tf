# =============================================================================
#  outputs.tf — Oracle VPS / 3X-UI Proxy
# =============================================================================

locals {
  _ipv6_public_ips = flatten([for ds in data.oci_core_ipv6s.proxy : [for im in ds.ipv6s : im.ip_address]])
}

output "stack_prefix" {
  description = "Display name prefix for this stack (includes deployment_id when set)."
  value       = local.stack_prefix
}

output "availability_domain" {
  description = "Resolved availability domain name (auto-discovered or explicit override)."
  value       = local.resolved_availability_domain
}

output "resolved_image_id" {
  description = "Platform image OCID used for the instance."
  value       = length(data.oci_core_image.host_boot) > 0 ? data.oci_core_image.host_boot[0].id : local.host_image_id
}

output "instance_public_ip" {
  description = "Public IP address of the proxy instance."
  value       = oci_core_instance.proxy.public_ip
}

output "instance_public_ipv6" {
  description = "Public IPv6 when assigned and enable_ipv6 is true; n/a when dual-stack is off."
  value = (
    length(local._ipv6_public_ips) > 0 ? local._ipv6_public_ips[0] : (
      var.enable_ipv6 ? "not assigned yet" : "n/a (enable_ipv6 = false)"
    )
  )
}

output "ssh_command" {
  description = "SSH command to connect to the instance. Replace ~/path/to/private_key with the private key matching ssh_public_key in tfvars (e.g. ~/.ssh/id_ed25519)."
  value       = "ssh -p ${var.ssh_port} -i ~/path/to/private_key ${var.admin_username}@${oci_core_instance.proxy.public_ip}"
}

output "panel_url" {
  description = "3X-UI admin panel URL (management_ips only)."
  value       = "http://${oci_core_instance.proxy.public_ip}:${var.panel_port}"
}

output "panel_credentials" {
  description = "3X-UI admin panel login credentials (auto-generated or user-provided)."
  sensitive   = true
  value = {
    username = local.panel_username
    password = local.panel_password
  }
}

output "oracle_security_list_summary" {
  description = "Summary of what the Oracle Security List allows."
  value = {
    vless_proxy = var.enable_ipv6 ? "TCP ${var.vless_port} open to 0.0.0.0/0 and ::/0" : "TCP ${var.vless_port} open to 0.0.0.0/0 only (IPv4)"
    ssh         = "TCP ${var.ssh_port} open to: ${join(", ", var.management_ips)}"
    panel       = "TCP ${var.panel_port} open to: ${join(", ", var.management_ips)}"
  }
}

output "cloud_init_log" {
  description = "How to check cloud-init progress and status after first boot."
  value       = "sudo tail -f /var/log/cloud-init-output.log  # live progress\ncat /opt/cloud-init-status                    # OK or FAILED"
}

output "next_steps" {
  description = "What to do after apply completes."
  value       = <<-EOT

    ═══════════════════════════════════════════════════════
      Setup complete! Next steps:
    ═══════════════════════════════════════════════════════

    1. Wait ~10 minutes for cloud-init to finish (Docker pull + packages can be slow).
       Monitor progress (use -i with your private key if ssh does not pick it automatically):
       ssh -p ${var.ssh_port} -i ~/path/to/private_key ${var.admin_username}@${oci_core_instance.proxy.public_ip} \
         "sudo tail -f /var/log/cloud-init-output.log"

    2. Log into the 3X-UI panel:
       http://${oci_core_instance.proxy.public_ip}:${var.panel_port}
       Credentials: terraform output panel_credentials

    3. In the panel: Inbounds → Add Inbound — see README "Add Inbound — field reference":
       VLESS, TCP, port ${var.vless_port}, Security reality, Target/SNI, uTLS, keys + Short IDs,
       client Flow (e.g. xtls-rprx-vision). Save → QR / subscription link.

    4. Users install a compatible client (e.g. Hiddify), import QR / sub → connect.

    ═══════════════════════════════════════════════════════
  EOT
}
