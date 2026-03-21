# =============================================================================
#  outputs.tf — Oracle VPS / 3X-UI Proxy
# =============================================================================

output "stack_prefix" {
  description = "Display name prefix for this stack (includes deployment_id when set)."
  value       = local.stack_prefix
}

output "instance_public_ip" {
  description = "Public IP address of the proxy instance."
  value       = oci_core_instance.proxy.public_ip
}

output "instance_public_ipv6" {
  description = "Public IPv6 address of the proxy instance."
  value       = try(data.oci_core_ipv6s.proxy.ipv6s[0].ip_address, "not assigned")
}

output "ssh_command" {
  description = "SSH command to connect to the instance."
  value       = "ssh -p ${var.ssh_port} ${var.admin_username}@${oci_core_instance.proxy.public_ip}"
}

output "panel_url" {
  description = "3X-UI admin panel URL (accessible from your home IPs only)."
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
    vless_proxy = "TCP ${var.vless_port} open to 0.0.0.0/0 + ::/0"
    ssh         = "TCP ${var.ssh_port} open to: ${join(", ", var.home_ips)}"
    panel       = "TCP ${var.panel_port} open to: ${join(", ", var.home_ips)}"
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

    1. Wait ~3 minutes for cloud-init to finish provisioning.
       Monitor progress:
       ssh -p ${var.ssh_port} ${var.admin_username}@${oci_core_instance.proxy.public_ip} \
         "sudo tail -f /var/log/cloud-init-output.log"

    2. Log into the 3X-UI panel:
       http://${oci_core_instance.proxy.public_ip}:${var.panel_port}
       Credentials: terraform output panel_credentials

    3. In the panel:
       • Go to Inbounds → Add Inbound
       • Protocol: vless, Port: ${var.vless_port}
       • Security: Reality, SNI: vk.com:443
       • Flow: xtls-rprx-vision
       • Add a client → Generate UUID → Save
       • Click the QR code icon → send to your parents

    4. Parents install Hiddify (iOS/Android), scan QR → Connect.

    ═══════════════════════════════════════════════════════
  EOT
}
