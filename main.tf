# =============================================================================
#  main.tf — Oracle VPS / 3X-UI Proxy
# =============================================================================

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    oci = {
      source = "oracle/oci"
      # https://registry.terraform.io/providers/oracle/oci/latest
      version = ">= 8.5.0"
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

# ── Availability domain ───────────────────────────────────────────────────────

data "oci_identity_availability_domains" "ads" {
  compartment_id = var.compartment_id
}

locals {
  resolved_availability_domain = (
    var.availability_domain != null
    ? var.availability_domain
    : data.oci_identity_availability_domains.ads.availability_domains[var.availability_domain_number - 1].name
  )
}

data "oci_core_shapes" "instance_ad" {
  compartment_id      = var.compartment_id
  availability_domain = local.resolved_availability_domain
}

check "instance_shape_in_availability_domain" {
  assert {
    condition     = length([for s in data.oci_core_shapes.instance_ad.shapes : s if s.name == var.instance_shape]) > 0
    error_message = "Shape ${var.instance_shape} is not available in AD ${local.resolved_availability_domain} (${var.region}). Try another availability_domain_number, set availability_domain from the Console, or pick a shape from: oci compute shape list --compartment-id <ocid> --availability-domain \"${local.resolved_availability_domain}\" --region ${var.region} --all"
  }
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

  _host_image_ocid_trimmed = try(trimspace(var.host_image_ocid), "")
  _host_image_override     = length(local._host_image_ocid_trimmed) > 0 ? local._host_image_ocid_trimmed : null
}

data "oci_core_images" "host_shaped" {
  count = local._host_image_override == null ? 1 : 0

  compartment_id           = var.tenancy_ocid
  operating_system         = local.host_os_image_filter[var.host_os].operating_system
  operating_system_version = local.host_os_image_filter[var.host_os].operating_system_version
  shape                    = var.instance_shape
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
  state                    = "AVAILABLE"
}

locals {
  _ids_from_shaped = length(data.oci_core_images.host_shaped) == 0 ? [] : flatten([for ds in data.oci_core_images.host_shaped : [for im in ds.images : im.id]])
}

data "oci_core_images" "host_loose" {
  count = local._host_image_override == null && length(local._ids_from_shaped) == 0 ? 1 : 0

  compartment_id           = var.tenancy_ocid
  operating_system         = local.host_os_image_filter[var.host_os].operating_system
  operating_system_version = local.host_os_image_filter[var.host_os].operating_system_version
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
  state                    = "AVAILABLE"
}

locals {
  _ids_from_loose = length(data.oci_core_images.host_loose) == 0 ? [] : flatten([for ds in data.oci_core_images.host_loose : [for im in ds.images : im.id]])
  _auto_image_ids = length(local._ids_from_shaped) > 0 ? local._ids_from_shaped : local._ids_from_loose
  _image_id_candidates = concat(
    local._host_image_override != null ? [local._host_image_override] : [],
    local._auto_image_ids
  )
}

check "host_platform_image_found" {
  assert {
    condition     = length(local._image_id_candidates) > 0
    error_message = "No platform image for host_os=${var.host_os}, shape=${var.instance_shape}, region=${var.region}. Set host_image_ocid from Console → Compute → Images, or try host_os = \"debian-12\"."
  }
}

locals {
  host_image_id = try(local._image_id_candidates[0], null)

  # Build /32 CIDR list from home IPs for Security List rules
  home_ip_cidrs = [for ip in var.home_ips : "${ip}/32"]

  # Fail2ban ignoreip space-separated string
  fail2ban_ignoreip = join(" ", concat(["127.0.0.1/8", "::1"], var.home_ips))

  # CI-friendly auth: PEM string wins over file path (GitHub Actions has no ~/.oci key file).
  oci_use_inline_key            = var.private_key != null ? length(trimspace(var.private_key)) > 0 : false
  oci_private_key_inline        = local.oci_use_inline_key ? trimspace(var.private_key) : null
  oci_private_key_path_resolved = local.oci_use_inline_key ? null : pathexpand(var.private_key_path)

  deployment_slug_alnum = var.deployment_id != "" ? replace(replace(lower(var.deployment_id), "-", ""), "_", "") : ""
  stack_prefix          = var.deployment_id != "" ? "${var.instance_hostname}-${var.deployment_id}" : var.instance_hostname
  vcn_dns_label = substr(
    replace(lower("${var.instance_hostname}${local.deployment_slug_alnum}"), "-", ""),
    0,
    15
  )

  _instance_shape_is_flex       = strcontains(var.instance_shape, "Flex")
  instance_flex_ocpus_resolved  = local._instance_shape_is_flex ? coalesce(var.instance_flex_ocpus, 1) : null
  instance_flex_memory_resolved = local._instance_shape_is_flex ? coalesce(var.instance_flex_memory_gb, 6) : null
}

data "oci_core_image" "host_boot" {
  count = local.host_image_id != null && length(trimspace(local.host_image_id)) > 0 ? 1 : 0

  image_id = local.host_image_id
}

data "oci_identity_compartment" "deploy_target" {
  id = var.compartment_id
}

# ── Networking ────────────────────────────────────────────────────────────────

resource "oci_core_vcn" "main" {
  compartment_id                   = data.oci_identity_compartment.deploy_target.id
  cidr_block                       = var.vcn_cidr
  display_name                     = "${local.stack_prefix}-vcn"
  dns_label                        = local.vcn_dns_label
  is_ipv6enabled                   = var.enable_ipv6
  is_oracle_gua_allocation_enabled = var.enable_ipv6
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

  dynamic "route_rules" {
    for_each = var.enable_ipv6 ? [1] : []
    content {
      destination       = "::/0"
      network_entity_id = oci_core_internet_gateway.main.id
    }
  }
}

# ── Security List (Oracle-layer firewall) ─────────────────────────────────────

resource "oci_core_security_list" "main" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.main.id
  display_name   = "${local.stack_prefix}-sl"

  egress_security_rules {
    destination = "0.0.0.0/0"
    protocol    = "all"
    description = "Allow all outbound traffic (IPv4)"
  }

  dynamic "egress_security_rules" {
    for_each = var.enable_ipv6 ? [1] : []
    content {
      destination = "::/0"
      protocol    = "all"
      description = "Allow all outbound traffic (IPv6)"
    }
  }

  ingress_security_rules {
    protocol    = "6" # TCP
    source      = "0.0.0.0/0"
    description = "VLESS/Reality proxy (IPv4)"
    tcp_options {
      min = var.vless_port
      max = var.vless_port
    }
  }

  dynamic "ingress_security_rules" {
    for_each = var.enable_ipv6 ? [1] : []
    content {
      protocol    = "6" # TCP
      source      = "::/0"
      description = "VLESS/Reality proxy (IPv6)"
      tcp_options {
        min = var.vless_port
        max = var.vless_port
      }
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

resource "oci_core_subnet" "public_ipv4_only" {
  count = var.enable_ipv6 ? 0 : 1

  compartment_id             = var.compartment_id
  vcn_id                     = oci_core_vcn.main.id
  cidr_block                 = var.subnet_cidr
  display_name               = "${local.stack_prefix}-subnet-v4"
  dns_label                  = "pub"
  route_table_id             = oci_core_route_table.main.id
  security_list_ids          = [oci_core_security_list.main.id]
  prohibit_public_ip_on_vnic = false
}

resource "oci_core_subnet" "public_dual_stack" {
  count = var.enable_ipv6 ? 1 : 0

  compartment_id             = var.compartment_id
  vcn_id                     = oci_core_vcn.main.id
  cidr_block                 = var.subnet_cidr
  display_name               = "${local.stack_prefix}-subnet-dual"
  dns_label                  = "pub"
  route_table_id             = oci_core_route_table.main.id
  security_list_ids          = [oci_core_security_list.main.id]
  prohibit_public_ip_on_vnic = false
  ipv6cidr_blocks = (
    length(oci_core_vcn.main.ipv6cidr_blocks) > 0
    ? [cidrsubnet(oci_core_vcn.main.ipv6cidr_blocks[0], 8, 0)]
    : []
  )
}

locals {
  primary_subnet_id = var.enable_ipv6 ? oci_core_subnet.public_dual_stack[0].id : oci_core_subnet.public_ipv4_only[0].id
}

# ── Compute instance ──────────────────────────────────────────────────────────

resource "oci_core_instance" "proxy" {
  compartment_id      = var.compartment_id
  availability_domain = local.resolved_availability_domain
  shape               = var.instance_shape
  display_name        = local.stack_prefix

  dynamic "shape_config" {
    for_each = local.instance_flex_ocpus_resolved != null ? [1] : []
    content {
      ocpus         = local.instance_flex_ocpus_resolved
      memory_in_gbs = local.instance_flex_memory_resolved
    }
  }

  source_details {
    source_type             = "image"
    source_id               = length(data.oci_core_image.host_boot) > 0 ? data.oci_core_image.host_boot[0].id : local.host_image_id
    boot_volume_size_in_gbs = 50
  }

  create_vnic_details {
    subnet_id                 = local.primary_subnet_id
    hostname_label            = substr(replace(lower(local.stack_prefix), "_", "-"), 0, 63)
    assign_private_dns_record = true
    assign_public_ip          = true
    assign_ipv6ip             = var.enable_ipv6 ? true : null
    display_name              = "${local.stack_prefix}-vnic"
  }

  metadata = {
    ssh_authorized_keys = var.ssh_public_key
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

  lifecycle {
    precondition {
      condition     = local.host_image_id != null && local.host_image_id != ""
      error_message = "host_image_id is unset: fix OS image lookup (see check host_platform_image_found) or set host_image_ocid in tfvars."
    }
    ignore_changes = [
      source_details,
      metadata["ssh_authorized_keys"],
    ]
  }
}

# ── IPv6 Address Lookup (only when dual-stack is enabled) ───────────────────

data "oci_core_vnic_attachments" "proxy" {
  count = var.enable_ipv6 ? 1 : 0

  compartment_id = var.compartment_id
  instance_id    = oci_core_instance.proxy.id
}

data "oci_core_ipv6s" "proxy" {
  count = var.enable_ipv6 ? 1 : 0

  vnic_id = data.oci_core_vnic_attachments.proxy[0].vnic_attachments[0].vnic_id
}
