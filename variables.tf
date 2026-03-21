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
  description = "Availability domain name, e.g. 'Uocm:EU-FRANKFURT-1-AD-1'. Check the console for which AD supports free-tier shapes in your region."
  type        = string
}

variable "instance_shape" {
  description = "Compute shape. VM.Standard.E2.1.Micro is always-free eligible."
  type        = string
  default     = "VM.Standard.E2.1.Micro"
}

variable "host_os" {
  description = "Platform image for the instance. Debian and Ubuntu use the same bootstrap (apt); pick Ubuntu if you prefer Canonical images on OCI. RAM use is similar — the panel and Xray dominate memory, not the base OS."
  type        = string
  default     = "debian-12"

  validation {
    condition     = contains(["debian-12", "ubuntu-22.04"], var.host_os)
    error_message = "host_os must be debian-12 or ubuntu-22.04."
  }
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
  description = "Optional suffix for parallel or ephemeral runs (e.g. github run id). Keeps VCN DNS labels and display names unique in the same tenancy."
  type        = string
  default     = ""
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
  validation {
    condition     = var.panel_port != var.vless_port
    error_message = "Panel port must differ from VLESS port."
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
