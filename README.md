# Oracle VPS — 3X-UI VLESS/Reality Proxy

Terraform configuration to provision a hardened **Ubuntu 22.04 LTS** (default) or **Debian 12**
instance on Oracle Cloud Free Tier, with 3X-UI installed via cloud-init on first boot.

## What this provisions

- **VCN** + subnet + internet gateway + route table — **IPv4 by default**; set **`enable_ipv6 = true`** for dual-stack (VCN IPv6, `::/0` routes, IPv6 VLESS rule, VNIC IPv6)
- **Security List** (Oracle-layer firewall):
  - VLESS port open to the world on IPv4; when `enable_ipv6`, also on `::/0`
  - SSH and panel restricted to your home IPs (IPv4)
- **Ubuntu 22.04** (default) or **Debian 12** instance (`VM.Standard.A1.Flex` by default; use `VM.Standard.E2.1.Micro` where that shape exists in the chosen AD)
- **Auto-generated panel credentials** (random username + password, retrievable via `terraform output`)
- **cloud-init bootstrap** that automatically:
  - Updates the system
  - Creates a sudo user with your SSH key
  - Hardens SSH (custom port, key-only auth, no root login)
  - Configures UFW (mirrors the Security List rules as a second layer)
  - Configures Fail2ban (SSH brute-force protection)
  - Enables automatic security updates
  - Applies kernel hardening (sysctl — IPv4/IPv6)
  - Installs Docker and runs **3X-UI** from the official image via **Docker Compose** (non-interactive)
  - Sets panel credentials and port automatically
  - Deploys **Watchtower** (label-scoped) to pull image updates for the panel container on a daily interval
  - Writes a status marker (`/opt/cloud-init-status`) — `OK` on success, `FAILED` on error

## Prerequisites

1. An Oracle Cloud account (free tier is fine — see [OCI account setup](#oci-account-setup) below)
2. An OCI API key configured locally (see [OCI API key setup](#oci-api-key-setup) below)
3. Terraform **>= 1.5.0** installed locally
4. An SSH key pair (e.g. `ssh-keygen -t ed25519`)

This repo pins the **[Oracle OCI provider](https://registry.terraform.io/providers/oracle/oci/latest)** to **8.5.x** (8.x line). Run **`terraform init -upgrade`** after pulling changes, then **commit `.terraform.lock.hcl`** so CI and teammates use the same provider build.

## OCI account setup

If you have never used Oracle Cloud before, follow these steps to create an account and find the values needed for `terraform.tfvars`.

### 1. Create a free Oracle Cloud account

1. Go to [cloud.oracle.com](https://cloud.oracle.com/) and click **Sign Up**
2. Choose your **home region** — this cannot be changed later and determines where free-tier resources are available. Pick a region geographically close to where the proxy will be used (e.g. `eu-frankfurt-1` for Europe, `us-ashburn-1` for US East)
3. Complete the sign-up (a credit card is required for verification but will not be charged for always-free resources)
4. Wait for the account to be provisioned (usually a few minutes, sometimes up to 24 hours)

### 2. Find your tenancy OCID

1. Log into the [OCI Console](https://cloud.oracle.com/)
2. Click your **profile icon** (top right) → **Tenancy: \<your-tenancy\>**
3. Copy the **OCID** — it looks like `ocid1.tenancy.oc1..aaaa...`
4. This is your `tenancy_ocid` and typically also your `compartment_id` (for personal/free-tier use)

### 3. Find your user OCID

1. Click your **profile icon** (top right) → **User Settings** (or **My Profile**)
2. Copy the **OCID** — it looks like `ocid1.user.oc1..aaaa...`
3. This is your `user_ocid`

### 4. Find your region

1. Your region is shown in the top bar of the console (e.g. `Germany Central (Frankfurt)`)
2. The region identifier is in the format `eu-frankfurt-1` — see the [full region list](https://docs.oracle.com/en-us/iaas/Content/General/Concepts/regions.htm)

> **Availability domain** is auto-discovered — you do **not** need to look it up. OCI periodically rotates AD name prefixes; the module queries the current name at apply time via `oci_identity_availability_domains`. If your region has multiple ADs and you get "Out of host capacity", set `availability_domain_number = 2` (or 3) in tfvars.

## OCI API key setup

Terraform authenticates to OCI using an API signing key.

### Generate and configure the key

```bash
# 1. Create the OCI config directory
mkdir -p ~/.oci

# 2. Generate a 2048-bit RSA key pair (no passphrase for automation)
openssl genrsa -out ~/.oci/oci_api_key.pem 2048
openssl rsa -pubout -in ~/.oci/oci_api_key.pem -out ~/.oci/oci_api_key_public.pem
chmod 600 ~/.oci/oci_api_key.pem

# 3. Copy the public key to your clipboard
cat ~/.oci/oci_api_key_public.pem
```

### Upload the public key to OCI

1. In the OCI Console, go to **Profile → User Settings → API Keys**
2. Click **Add API Key** → **Paste Public Key**
3. Paste the contents of `~/.oci/oci_api_key_public.pem`
4. Click **Add**
5. OCI will show a **Configuration File Preview** — copy the `fingerprint` value (e.g. `aa:bb:cc:dd:...`)
6. This is your `fingerprint` for `terraform.tfvars`

You now have everything needed to fill in `terraform.tfvars`:

| tfvars field | Where to find it |
|---|---|
| `tenancy_ocid` | Profile → Tenancy → OCID |
| `user_ocid` | Profile → User Settings → OCID |
| `fingerprint` | Shown after uploading the API key |
| `private_key_path` | Path to `~/.oci/oci_api_key.pem` |
| `region` | Top bar of console (e.g. `eu-frankfurt-1`) |
| `compartment_id` | Same as `tenancy_ocid` for free tier |

## Changing region

Resources are regional: edit `region` alone does not migrate them. Subscribe to the new region in Console if needed, **`terraform destroy`** in the **old** region, then set `region` (and usually `availability_domain_number = 1` in single-AD regions) and **`terraform apply`**. See [OCI regions](https://docs.oracle.com/en-us/iaas/Content/General/Concepts/regions.htm).

## Usage

```bash
# 1. Clone / copy this directory
cd 3x-ui-oracle

# 2. Create your tfvars from the example
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your values (see tables above)

# 3. Initialise Terraform (downloads OCI + random providers)
terraform init

# 4. Preview what will be created
terraform plan

# 5. Apply
terraform apply

# 6. Wait ~3 minutes for cloud-init to complete, then check:
ssh -p <ssh_port> <admin_username>@<instance_ip> \
  "cat /opt/cloud-init-status"
# Should print: OK
```

## After apply — 3X-UI setup

1. Get your auto-generated panel credentials:
   ```bash
   terraform output panel_credentials
   ```
2. Open the panel URL printed in outputs: `http://<ip>:<panel_port>`
3. Sign in with the credentials from step 1
4. Go to **Inbounds → Add Inbound**:
   - Protocol: `vless`
   - Port: `443`
   - Transmission: `TCP`
   - Security: `Reality`
   - SNI / Dest: `vk.com:443`
   - Server name: `vk.com`
   - Click **Get New Cert**
   - Flow: `xtls-rprx-vision`
5. Add a client → Generate UUID → Save
6. Click the **QR code icon** → send to recipient
7. Recipient installs **Hiddify** (iOS/Android), scan QR → Connect

Compose files and data live under `/opt/3x-ui` on the instance (`compose.yml`, `db/`, `cert/`). To manage the stack: `sudo docker compose -f /opt/3x-ui/compose.yml …`.

**Note:** Re-applying Terraform updates `user_data`, but OCI only runs cloud-init on **first boot**. To rebuild the node from an updated script, replace the instance (e.g. `terraform apply -replace=…`) or run the new steps manually.

## Teardown

```bash
terraform destroy
```

Everything is fully ephemeral — destroy and re-apply to get a clean instance.

## Ephemeral stacks and CI (e.g. GitHub Actions)

- **Non-interactive apply:** `export TF_INPUT=0` and use `terraform apply -auto-approve` (or `-input=false` with a plan file).
- **OCI API key:** store the PEM in a secret and expose it as **`TF_VAR_private_key`**; leave `private_key_path` unset (or empty) in that environment. The root module accepts either a file path or inline PEM.
- **SSH key:** set **`TF_VAR_ssh_public_key`** from a deploy key or generated key pair stored in repo secrets.
- **Runner egress IP:** GitHub-hosted runners use dynamic IPs. Either add the runner’s current egress to `home_ips` for that run, use a self-hosted runner with a fixed IP, or temporarily widen OCI/UFW rules for the job (not recommended for production panels).
- **Parallel jobs:** set **`deployment_id`** (e.g. `${{ github.run_id }}`) so VCN `dns_label` and resource display names stay unique in one tenancy.
- **State:** default is **local** `terraform.tfstate` (gitignored). For pipelines, configure a **remote backend** (OCI Object Storage, Terraform Cloud, etc.) so `apply` and `destroy` share state.

## Files

| File | Purpose |
|------|---------|
| `main.tf` | VCN, security list, instance |
| `variables.tf` | All input variable definitions |
| `outputs.tf` | SSH command, panel URL, next steps |
| `terraform.tfvars.example` | Template — copy to `terraform.tfvars` |
| `cloud-init.sh.tpl` | Bootstrap script run on first boot |
| `.gitignore` | Prevents secrets from being committed |
| `.terraform.lock.hcl` | Provider lock — commit after `terraform init` |

## Which Linux OS?

**Ubuntu 22.04 LTS** is the **default**: Canonical images are available in essentially all OCI regions, and the bootstrap is the same `apt`-based flow as Debian.

**Debian 12** is available via `host_os = "debian-12"` only where Oracle publishes it (some regions have no Debian platform images). On a 1 GB VM, **switching distro does not free meaningful RAM**; almost all memory goes to **Docker, the panel, and Xray**.

**Oracle Linux** or **RHEL-family** would mean a different bootstrap (`dnf`, `firewalld`, …) and is not worth the maintenance unless you standardize on Oracle Linux for compliance.

**Minimal / “Container-optimized” images** rarely help here: you still need a normal userland for SSH, UFW, Fail2ban, and `docker compose`, and OCI’s minimal images can omit pieces cloud-init expects.

**Empty image list / validate errors:** Platform images are queried with **`tenancy_ocid`** (listing under a child `compartment_id` often returns nothing). The module tries shape-filtered listing, then the same OS without shape. If you still get no match, set **`host_image_ocid`** from **Compute → Images → OS images** (pick the build that matches your shape, e.g. x86_64 for `VM.Standard.E2.1.Micro`). If Debian is unavailable in your region, keep the default **`host_os = "ubuntu-22.04"`**.

## Small VMs (e.g. E2.1.Micro or minimal A1.Flex)

1 GB–class shapes are tight for Docker + Xray + a panel. The bootstrap script is tuned for that:

- **zram** (`zram-tools`, ~40% of RAM as compressed swap) to reduce OOM kills without relying on a large on-disk swap file.
- **Higher `vm.swappiness`** so the kernel is willing to use that compressed “swap” before processes die.
- **Small journald caps** so logs do not eat the boot volume.
- **Docker log rotation** (`daemon.json`: 10 MB × 2 files per container) so container stdout does not grow without bound.
- **No in-container Fail2ban** for 3X-UI — the host already runs Fail2ban for SSH, and the panel is only exposed to your `home_ips` in OCI + UFW. That drops a second Fail2ban stack inside the container and saves memory.

**Not capped:** the 3X-UI service is **not** given a hard Docker memory limit, so Xray can burst under load; on 1 GB you should still keep inbound/client counts modest and watch `free -h` / `docker stats` after changes.

**Optional later:** if you need more headroom, move to a paid shape, add a **dedicated disk swapfile** (slower than zram but larger), lengthen the Watchtower interval, or turn Watchtower off and pull images manually.

## Troubleshooting

| Symptom | Typical fix |
|--------|-------------|
| `400-CannotParseRequest` on launch | Prefer auto AD (`availability_domain` unset); if you set it, paste the current name from Console. Ensure `compartment_id` is a compartment/tenancy OCID, not a resource OCID. |
| Out of capacity / `500` on launch | Try `availability_domain_number` 2 or 3, another time of day, or another region after `destroy` + `apply`. Use `-replace=oci_core_instance.proxy` if state is stuck after a failed create. |
| `404` on launch | Often **shape not in that AD** — `terraform plan` runs a shape check; use `VM.Standard.A1.Flex` or pick a shape from `oci compute shape list`. Confirm `compartment_id`, `region`, and optional `host_image_ocid`. |
| `404` on CreateVcn | Use root or a normal compartment (not a restricted PSM compartment); ensure IAM allows `manage virtual-network-family` there. |

## Security notes

- `terraform.tfvars` is gitignored — never commit it
- Terraform state (`*.tfstate`) is gitignored — use a **remote backend** for any shared or CI workflow
- Panel credentials are auto-generated and stored in Terraform state (marked sensitive). Override with `panel_username`/`panel_password` in tfvars if needed
- The Security List + UFW provide two independent firewall layers
- Fail2ban adds brute-force protection as a third layer
- SSH password auth is disabled; key-only access only
- **`enable_ipv6`**: dual-stack VLESS and public IPv6 when `true`; SSH/panel remain restricted to `home_ips` (IPv4). Toggling replaces the subnet (OCI cannot remove a subnet IPv6 prefix in place) and usually replaces the instance — review `terraform plan`.
