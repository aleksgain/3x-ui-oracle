# =============================================================================
#  variables.tf — Oracle VPS / 3X-UI Proxy
# =============================================================================

# ── OCI Authentication ────────────────────────────────────────────────────────

variable "tenancy_ocid" {
  description = "OCID of your OCI tenancy. Found under Profile → Tenancy."
  type        = string
}

variable "user_ocid" {
  description = "OCID of the OCI user running Terraform. Found under Profile → User Settings."
  type        = string
}

variable "fingerprint" {
  description = "Fingerprint of the API key added to your OCI user."
  type        = string
}

variable "private_key_path" {
  description = "Path to the OCI API private key (.pem). Expanded with pathexpand(); ignored when private_key is set (use private_key in CI)."
  type        = string
  default     = "~/.oci/oci_api_key.pem"
}

variable "private_key" {
  description = "OCI API private key PEM body. Prefer this in GitHub Actions (secret TF_VAR_private_key) instead of committing a key file."
  type        = string
  default     = null
  sensitive   = true
}

variable "region" {
  description = "OCI region identifier, e.g. eu-frankfurt-1, us-ashburn-1."
  type        = string
}

variable "compartment_id" {
  description = "OCID of the compartment to deploy into. Use tenancy_ocid for root."
  type        = string
}

# ── Instance ─────────────────────────────────────────────────────────────────

variable "availability_domain" {
  description = "Explicit AD name override. Leave null (default) to auto-discover via availability_domain_number. OCI rotates AD name prefixes without notice — auto-discovery avoids stale names causing 400-CannotParseRequest."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition = (
      var.availability_domain == null
      || (
        length(trimspace(var.availability_domain)) > 0
        && !can(regex("^ocid1\\.", trimspace(var.availability_domain)))
      )
    )
    error_message = "availability_domain must be null (auto-discover) or a non-empty AD name — not an OCID."
  }
}

variable "availability_domain_number" {
  description = "1-based index of the availability domain to use (1, 2, or 3). Most regions have 1 AD; some have 3. Free-tier capacity is not always in every AD — try a different number if you get 'Out of host capacity'. Ignored when availability_domain is set explicitly."
  type        = number
  default     = 1

  validation {
    condition     = var.availability_domain_number >= 1 && var.availability_domain_number <= 3
    error_message = "Must be 1, 2, or 3."
  }
}

variable "instance_shape" {
  description = "Compute shape. VM.Standard.E2.1.Micro is always-free eligible (x86). VM.Standard.A1.Flex is always-free eligible (ARM) — set instance_flex_ocpus and instance_flex_memory_gb when using flex shapes."
  type        = string
  default     = "VM.Standard.E2.1.Micro"
}

variable "instance_flex_ocpus" {
  description = "Number of OCPUs for flex shapes (e.g. VM.Standard.A1.Flex). Leave null for fixed shapes like VM.Standard.E2.1.Micro."
  type        = number
  default     = null
  nullable    = true
}

variable "instance_flex_memory_gb" {
  description = "Memory in GB for flex shapes. Leave null for fixed shapes. ARM free tier allows up to 24 GB across all A1 instances."
  type        = number
  default     = null
  nullable    = true
}

variable "host_os" {
  description = "Platform image for the instance. Default is Ubuntu 22.04 (widely available on OCI); Debian 12 is optional where Oracle publishes it. Same apt-based bootstrap either way."
  type        = string
  default     = "ubuntu-22.04"

  validation {
    condition     = contains(["debian-12", "ubuntu-22.04"], var.host_os)
    error_message = "host_os must be debian-12 or ubuntu-22.04."
  }
}

variable "host_image_ocid" {
  description = "Optional platform image OCID. When set, skips automatic image lookup (use if ListImages is empty, wrong arch, or you need a specific build)."
  type        = string
  default     = null
  nullable    = true
}

variable "instance_hostname" {
  description = "Base name for the instance and resources. Use lowercase letters, digits, hyphens only (OCI VNIC hostname); keep short."
  type        = string
  default     = "proxy"
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,62}$", var.instance_hostname))
    error_message = "instance_hostname must start with a letter and contain only lowercase letters, digits, and hyphens (max 63)."
  }
}

variable "deployment_id" {
  description = "Optional suffix for parallel or ephemeral runs (e.g. github run id). Keeps VCN DNS labels and display names unique in the same tenancy. Use only letters, digits, hyphens, underscores (no spaces)."
  type        = string
  default     = ""

  validation {
    condition     = var.deployment_id == "" || can(regex("^[a-zA-Z0-9_-]{1,40}$", var.deployment_id))
    error_message = "deployment_id must be empty or 1–40 chars: letters, digits, hyphens, underscores only."
  }
}

# ── Networking ────────────────────────────────────────────────────────────────

variable "vcn_cidr" {
  description = "CIDR block for the VCN."
  type        = string
  default     = "10.0.0.0/16"
}

variable "subnet_cidr" {
  description = "CIDR block for the public subnet."
  type        = string
  default     = "10.0.1.0/24"
}

variable "enable_ipv6" {
  description = "Dual-stack VCN (Oracle-assigned IPv6), ::/0 routes, IPv6 security rules, subnet IPv6 prefix, and primary VNIC IPv6. Default false avoids LaunchInstance issues in some regions. Toggling this replaces the subnet (OCI cannot remove a subnet IPv6 prefix in place)."
  type        = bool
  default     = false
}

# ── Access Control ────────────────────────────────────────────────────────────

variable "home_ips" {
  description = "List of your home/office public IP addresses. SSH and the 3X-UI panel will be restricted to these IPs only."
  type        = list(string)
  validation {
    condition     = length(var.home_ips) > 0
    error_message = "You must provide at least one home IP address."
  }
  validation {
    condition     = alltrue([for ip in var.home_ips : can(regex("^([0-9]{1,3}\\.){3}[0-9]{1,3}$", ip))])
    error_message = "All home_ips must be valid IPv4 addresses."
  }
}

variable "ssh_port" {
  description = "Non-standard SSH port (avoids default port scanners)."
  type        = number
  default     = 2222
  validation {
    condition     = var.ssh_port >= 1024 && var.ssh_port <= 65535
    error_message = "SSH port must be between 1024 and 65535."
  }
}

variable "panel_port" {
  description = "Port for the 3X-UI web admin panel."
  type        = number
  default     = 54321
  validation {
    condition     = var.panel_port >= 1024 && var.panel_port <= 65535
    error_message = "Panel port must be between 1024 and 65535."
  }
  validation {
    condition     = var.panel_port != var.ssh_port
    error_message = "Panel port must differ from SSH port."
  }
}

# ── SSH & User ────────────────────────────────────────────────────────────────

variable "ssh_public_key" {
  description = "SSH public key to authorise on the instance (full key string, e.g. 'ssh-ed25519 AAAA...')."
  type        = string
  sensitive   = true
}

variable "admin_username" {
  description = "Name of the sudo user to create on the instance."
  type        = string
  default     = "sysadmin"
  validation {
    condition     = can(regex("^[a-z_][a-z0-9_-]*$", var.admin_username))
    error_message = "Username must be lowercase letters, numbers, hyphens or underscores."
  }
}

# ── Panel Credentials ─────────────────────────────────────────────────────────

variable "panel_username" {
  description = "3X-UI admin username. Leave unset to auto-generate a random 8-char username."
  type        = string
  default     = null
  sensitive   = true
}

variable "panel_password" {
  description = "3X-UI admin password. Leave unset to auto-generate a random 16-char password."
  type        = string
  default     = null
  sensitive   = true
}

# ── Proxy ─────────────────────────────────────────────────────────────────────

variable "vless_port" {
  description = "Port for the VLESS/Reality inbound. 443 is recommended as it blends with HTTPS traffic."
  type        = number
  default     = 443
  validation {
    condition     = var.vless_port >= 1 && var.vless_port <= 65535
    error_message = "VLESS port must be between 1 and 65535."
  }
  validation {
    condition     = var.vless_port != var.ssh_port && var.vless_port != var.panel_port
    error_message = "VLESS port must differ from SSH and panel ports."
  }
}
