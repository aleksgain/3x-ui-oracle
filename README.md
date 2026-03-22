# Oracle VPS — 3X-UI VLESS/Reality Proxy

Terraform configuration to provision a hardened **Ubuntu 22.04 LTS** (default) or **Debian 12**
instance on Oracle Cloud Free Tier, with 3X-UI installed via cloud-init on first boot.

## What this provisions

- **VCN** + subnet + internet gateway + route table — **IPv4 by default**; set **`enable_ipv6 = true`** for dual-stack (VCN IPv6, `::/0` routes, IPv6 VLESS rule, VNIC IPv6)
- **Security List** (Oracle-layer firewall):
  - VLESS port open to the world on IPv4; when `enable_ipv6`, also on `::/0`
  - SSH and panel restricted to **`management_ips`** (IPv4 admin sources only)
- **Host firewall:** `iptables` with rules in `/etc/iptables/rules.v4` (UFW is not used; see [Oracle Compute guidance](https://docs.oracle.com/en-us/iaas/Content/Compute/known-issues.htm#ufw) for Ubuntu on OCI).
- **Ubuntu 22.04** (default) or **Debian 12** instance (`VM.Standard.A1.Flex` by default; use `VM.Standard.E2.1.Micro` where that shape exists in the chosen AD)
- **Auto-generated panel credentials** (random username + password, retrievable via `terraform output`)
- **cloud-init bootstrap** that automatically:
  - Updates the system
  - Creates a sudo user with your SSH key
  - Hardens SSH (custom port, key-only auth, no root login)
  - Configures **iptables** on the host (aligned with the Security List)
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
2. Choose your **subscription region** — this cannot be changed later and determines where free-tier resources are available. Pick a region close to where the proxy will run (e.g. `eu-frankfurt-1`, `us-ashburn-1`)
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

> **Availability domain** is resolved automatically when `availability_domain` is unset (`oci_identity_availability_domains`).

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
| `management_ips` | Your public IPv4 addresses allowed to use SSH and the panel |

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

# 6. Wait ~10 minutes for cloud-init to complete, then check:
ssh -p <ssh_port> -i ~/.ssh/id_ed25519 <admin_username>@<instance_ip> \
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
4. Go to **Inbounds → Add Inbound**. Below is a **field reference** for the current-style form (labels move slightly between releases). Set **Port** to the same value as **`vless_port`** in `terraform.tfvars` (often **443**).

### Add Inbound — field reference (VLESS + Reality)

**General (inbound)**

| Field | Purpose |
|--------|--------|
| **Enabled** | Turn the inbound on. |
| **Remark** | Label in the list only. |
| **Protocol** | **VLESS**. |
| **Listen IP** | Usually empty / all interfaces unless you bind to one NIC. |
| **Port** | Must match **`vless_port`** and OCI + host firewall (e.g. **443**). |
| **Total Flow** / **Traffic Reset** / **Duration** | Optional traffic accounting / reset rules. |

**Per-client row** (after you add a client under the inbound)

| Field | Purpose |
|--------|--------|
| **Email** | Friendly id for the client in the panel. |
| **ID** | Client UUID (generated). |
| **Subscription** | Subscription token / path segment for subscription URLs. |
| **Comment** | Notes. |
| **Flow** | e.g. **xtls-rprx-vision** for Vision + Reality with supported apps; use **none** if the client requires it. |
| **Total Flow** / **Start After First Use** / **Duration** | Optional per-client traffic limits. |
| **Authentication** — **decryption** / **encryption** | Often **none** for standard VLESS + Reality. |

**Transmission**

| Field | Purpose |
|--------|--------|
| **Transmission** | **TCP** for typical Reality. |
| **Proxy Protocol** | Off unless you sit behind a proxy that sends PROXY headers. |
| **HTTP Obfuscation** | Optional TCP HTTP-header camouflage; fewer clients support it than plain TCP + Reality. |
| **Sockopt** / **UDP Masks** / **External Proxy** | Advanced; leave default unless you know you need them. |
| **Fallbacks** | Optional alternate paths; leave empty for a simple setup. |

**Security** (expand **Show** if collapsed)

| Field | Purpose |
|--------|--------|
| **Security** | **reality**. |
| **Xver** | Often **0** unless you use X-Forwarded-For style metadata. |
| **uTLS** | Browser fingerprint, e.g. **chrome** / **Chrome**. |
| **Target** | Reality dest, e.g. **`vk.com:443`** — real TLS site on 443. |
| **SNI** | Server name for Reality, e.g. **`vk.com`** (aligned with **Target**). |
| **Max Time Diff (ms)** | Clock skew tolerance; **0** is common. |
| **Min Client Ver** / **Max Client Ver** | Optional Xray client version window. |
| **Short IDs** | Comma-separated Reality short IDs; use the panel’s generator — at least one must match the client. |
| **SpiderX** | Often **`/`** (default path-style knob for Reality). |
| **Public Key** / **Private Key** | Generate in the panel; **never** commit these or paste them into git. |
| **mldsa65 Seed** / **Verify** | Optional post-quantum / newer Reality options; leave default unless you intentionally use them. |

**Minimal path:** **VLESS** → **TCP** → **Security = reality** → fill **Target** + **SNI** → generate **keys** + **Short IDs** → set **uTLS** → add a client and set **Flow** → **Save** → share **QR** / subscription link.

**IPv6:** With **`enable_ipv6`**, you can put the instance’s public IPv6 in the client URI (typically bracketed), e.g. `vless://uuid@[2001:db8::1]:443?...`.

5. Add a client → **Save** the inbound.
6. Use the **QR** or subscription link with a client that matches **Reality**, **uTLS**, **flow**, and optional **HTTP Obfuscation** if you enabled it.

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
- **Runner egress IP:** GitHub-hosted runners use dynamic IPs. Add the runner’s current egress to `management_ips` for that run, use a self-hosted runner with a fixed IP, or temporarily widen firewall rules (avoid for production panels).
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

**Minimal / “Container-optimized” images** rarely help here: you still need a normal userland for SSH, host firewall (`iptables`), Fail2ban, and `docker compose`, and OCI’s minimal images can omit pieces cloud-init expects.

**Empty image list / validate errors:** Platform images are queried with **`tenancy_ocid`** (listing under a child `compartment_id` often returns nothing). The module tries shape-filtered listing, then the same OS without shape. If you still get no match, set **`host_image_ocid`** from **Compute → Images → OS images** (pick the build that matches your shape, e.g. x86_64 for `VM.Standard.E2.1.Micro`). If Debian is unavailable in your region, keep the default **`host_os = "ubuntu-22.04"`**.

## Small VMs (e.g. E2.1.Micro or minimal A1.Flex)

1 GB–class shapes are tight for Docker + Xray + a panel. The bootstrap script is tuned for that:

- **zram** (`zram-tools`, ~40% of RAM as compressed swap) to reduce OOM kills without relying on a large on-disk swap file.
- **Higher `vm.swappiness`** so the kernel is willing to use that compressed “swap” before processes die.
- **Small journald caps** so logs do not eat the boot volume.
- **Docker log rotation** (`daemon.json`: 10 MB × 2 files per container) so container stdout does not grow without bound.
- **No in-container Fail2ban** for 3X-UI — the host runs Fail2ban for SSH, and the panel is only reachable from `management_ips` (OCI + `iptables`).

**Not capped:** the 3X-UI service is **not** given a hard Docker memory limit, so Xray can burst under load; on 1 GB you should still keep inbound/client counts modest and watch `free -h` / `docker stats` after changes.

**Optional later:** if you need more headroom, move to a paid shape, add a **dedicated disk swapfile** (slower than zram but larger), lengthen the Watchtower interval, or turn Watchtower off and pull images manually.

## Security notes

- **`admin_password`** (optional): if set in `terraform.tfvars`, cloud-init sets a password for **`admin_username`** so you can log in on the **OCI serial console** or a local tty. **SSH remains public-key only** (`PasswordAuthentication` stays off). The value is **sensitive** and ends up in **Terraform state** — use a **remote backend** if the state is shared. Changing it updates `user_data`; expect Terraform to **replace** the instance so cloud-init runs again.
- `terraform.tfvars` is gitignored — never commit it
- Terraform state (`*.tfstate`) is gitignored — use a **remote backend** for any shared or CI workflow
- Panel credentials are auto-generated and stored in Terraform state (marked sensitive). Override with `panel_username`/`panel_password` in tfvars if needed
- The OCI Security List and host `iptables` rules provide two independent firewall layers
- Fail2ban adds brute-force protection as a third layer
- SSH password auth is disabled; key-only access only
- **`enable_ipv6`**: dual-stack VLESS and public IPv6 when `true`; SSH and the panel stay limited to **`management_ips`** (IPv4). Toggling replaces the subnet and usually the instance — review `terraform plan`.
