# =============================================================================
#  main.tf — Oracle VPS / 3X-UI Proxy
# =============================================================================

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

# ── Panel Credentials (auto-generated, overridable) ──────────────────────────

resource "random_string" "panel_username" {
  length  = 8
  special = false
  upper   = false
}

resource "random_password" "panel_password" {
  length  = 16
  special = false
}

locals {
  panel_username = coalesce(var.panel_username, random_string.panel_username.result)
  panel_password = coalesce(var.panel_password, random_password.panel_password.result)
}

check "oci_api_key_configured" {
  assert {
    condition = (
      (var.private_key != null ? length(trimspace(var.private_key)) > 0 : false)
      || length(trimspace(var.private_key_path)) > 0
    )
    error_message = "Set private_key (e.g. TF_VAR_private_key in CI) or private_key_path (local file)."
  }
}

# ── Provider ──────────────────────────────────────────────────────────────────

provider "oci" {
  tenancy_ocid = var.tenancy_ocid
  user_ocid    = var.user_ocid
  fingerprint  = var.fingerprint
  region       = var.region

  private_key      = local.oci_private_key_inline
  private_key_path = local.oci_private_key_path_resolved
}

# ── OS image (latest platform image per region for the chosen OS) ─────────────

locals {
  host_os_image_filter = {
    "debian-12" = {
      operating_system         = "Debian GNU/Linux"
      operating_system_version = "12"
    }
    "ubuntu-22.04" = {
      operating_system         = "Canonical Ubuntu"
      operating_system_version = "22.04"
    }
  }
}

data "oci_core_images" "host" {
  compartment_id           = var.compartment_id
  operating_system         = local.host_os_image_filter[var.host_os].operating_system
  operating_system_version = local.host_os_image_filter[var.host_os].operating_system_version
  shape                    = var.instance_shape
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
  state                    = "AVAILABLE"
}

locals {
  host_image_id = data.oci_core_images.host.images[0].id

  # Build /32 CIDR list from home IPs for Security List rules
  home_ip_cidrs = [for ip in var.home_ips : "${ip}/32"]

  # Fail2ban ignoreip space-separated string
  fail2ban_ignoreip = join(" ", concat(["127.0.0.1/8", "::1"], var.home_ips))

  # CI-friendly auth: PEM string wins over file path (GitHub Actions has no ~/.oci key file).
  oci_use_inline_key = var.private_key != null ? length(trimspace(var.private_key)) > 0 : false
  oci_private_key_inline = local.oci_use_inline_key ? trimspace(var.private_key) : null
  oci_private_key_path_resolved = local.oci_use_inline_key ? null : pathexpand(var.private_key_path)

  # Parallel / ephemeral stacks: unique display names; VCN dns_label must be <=15 alphanumeric (OCI).
  deployment_slug = var.deployment_id != "" ? regexreplace(lower(var.deployment_id), "[^a-z0-9]", "") : ""
  stack_prefix = var.deployment_id != "" ? "${var.instance_hostname}-${var.deployment_id}" : var.instance_hostname
  vcn_dns_label = substr(
    regexreplace(
      lower("${var.instance_hostname}${local.deployment_slug}"),
      "[^a-z0-9]",
      ""
    ),
    0,
    15
  )
}

# ── Networking ────────────────────────────────────────────────────────────────

resource "oci_core_vcn" "main" {
  compartment_id = var.compartment_id
  cidr_block     = var.vcn_cidr
  display_name   = "${local.stack_prefix}-vcn"
  dns_label      = local.vcn_dns_label
  is_ipv6enabled = true
}

resource "oci_core_internet_gateway" "main" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.main.id
  display_name   = "${local.stack_prefix}-igw"
  enabled        = true
}

resource "oci_core_route_table" "main" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.main.id
  display_name   = "${local.stack_prefix}-rt"

  route_rules {
    destination       = "0.0.0.0/0"
    network_entity_id = oci_core_internet_gateway.main.id
  }

  route_rules {
    destination       = "::/0"
    network_entity_id = oci_core_internet_gateway.main.id
  }
}

# ── Security List (Oracle-layer firewall) ─────────────────────────────────────

resource "oci_core_security_list" "main" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.main.id
  display_name   = "${local.stack_prefix}-sl"

  # Allow all outbound (IPv4 + IPv6)
  egress_security_rules {
    destination = "0.0.0.0/0"
    protocol    = "all"
    description = "Allow all outbound traffic (IPv4)"
  }

  egress_security_rules {
    destination = "::/0"
    protocol    = "all"
    description = "Allow all outbound traffic (IPv6)"
  }

  # VLESS proxy — open to the world (clients in Russia connect here)
  ingress_security_rules {
    protocol    = "6" # TCP
    source      = "0.0.0.0/0"
    description = "VLESS/Reality proxy (IPv4)"
    tcp_options {
      min = var.vless_port
      max = var.vless_port
    }
  }

  ingress_security_rules {
    protocol    = "6" # TCP
    source      = "::/0"
    description = "VLESS/Reality proxy (IPv6)"
    tcp_options {
      min = var.vless_port
      max = var.vless_port
    }
  }

  # SSH — restricted to home IPs only
  dynamic "ingress_security_rules" {
    for_each = local.home_ip_cidrs
    content {
      protocol    = "6"
      source      = ingress_security_rules.value
      description = "SSH from home (${ingress_security_rules.value})"
      tcp_options {
        min = var.ssh_port
        max = var.ssh_port
      }
    }
  }

  # 3X-UI panel — restricted to home IPs only
  dynamic "ingress_security_rules" {
    for_each = local.home_ip_cidrs
    content {
      protocol    = "6"
      source      = ingress_security_rules.value
      description = "3X-UI panel from home (${ingress_security_rules.value})"
      tcp_options {
        min = var.panel_port
        max = var.panel_port
      }
    }
  }

  # ICMP — restricted to home IPs (ping for diagnostics)
  dynamic "ingress_security_rules" {
    for_each = local.home_ip_cidrs
    content {
      protocol    = "1" # ICMP
      source      = ingress_security_rules.value
      description = "ICMP from home (${ingress_security_rules.value})"
      icmp_options {
        type = 8 # Echo request
      }
    }
  }
}

resource "oci_core_subnet" "main" {
  compartment_id    = var.compartment_id
  vcn_id            = oci_core_vcn.main.id
  cidr_block        = var.subnet_cidr
  display_name      = "${local.stack_prefix}-subnet"
  dns_label         = "pub"
  route_table_id    = oci_core_route_table.main.id
  security_list_ids = [oci_core_security_list.main.id]

  # Public subnet — instances get public IPs (IPv4 + IPv6)
  prohibit_public_ip_on_vnic = false
  ipv6cidr_blocks            = [cidrsubnet(oci_core_vcn.main.ipv6cidr_blocks[0], 8, 0)]
}

# ── Cloud-Init (bootstraps the instance on first boot) ───────────────────────

# ── Compute Instance ──────────────────────────────────────────────────────────

resource "oci_core_instance" "proxy" {
  compartment_id      = var.compartment_id
  availability_domain = var.availability_domain
  shape               = var.instance_shape
  display_name        = local.stack_prefix

  source_details {
    source_type = "image"
    source_id   = local.host_image_id
    # 50GB boot volume — within always-free limits
    boot_volume_size_in_gbs = 50
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.main.id
    hostname_label   = substr(regexreplace(lower(local.stack_prefix), "[^a-z0-9-]", "-"), 0, 63)
    assign_public_ip = true
    display_name     = "${local.stack_prefix}-vnic"

    # Assign an IPv6 address from the subnet's Oracle-allocated /64
    ipv6address_ipv6subnet_cidr_pair_details {
      ipv6subnet_cidr = oci_core_subnet.main.ipv6cidr_blocks[0]
    }
  }

  metadata = {
    # OCI uses this key specifically for SSH access during initial setup
    ssh_authorized_keys = var.ssh_public_key
    # cloud-init user data — base64 encoded
    user_data = base64encode(templatefile("${path.module}/cloud-init.sh.tpl", {
      admin_username    = var.admin_username
      ssh_public_key    = var.ssh_public_key
      ssh_port          = var.ssh_port
      panel_port        = var.panel_port
      panel_username    = local.panel_username
      panel_password    = local.panel_password
      vless_port        = var.vless_port
      home_ips_space    = join(" ", var.home_ips)
      fail2ban_ignoreip = local.fail2ban_ignoreip
    }))
  }

  # Preserve the instance if Terraform is re-applied (avoid accidental destroy)
  lifecycle {
    ignore_changes = [
      # Image OCIDs change with OS updates — don't force replacement
      source_details,
      metadata["ssh_authorized_keys"],
    ]
  }
}

# ── IPv6 Address Lookup ──────────────────────────────────────────────────────

data "oci_core_vnic_attachments" "proxy" {
  compartment_id = var.compartment_id
  instance_id    = oci_core_instance.proxy.id
}

data "oci_core_ipv6s" "proxy" {
  vnic_id = data.oci_core_vnic_attachments.proxy.vnic_attachments[0].vnic_id
}
