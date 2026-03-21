#!/bin/bash
# =============================================================================
#  cloud-init.sh.tpl — Oracle VPS Bootstrap
#  Templated by Terraform — all variables injected at apply time.
#  Runs once on first boot as root via cloud-init.
# =============================================================================

set -euo pipefail
exec > >(tee /var/log/cloud-init-bootstrap.log) 2>&1

BOOTSTRAP_STATUS="/opt/cloud-init-status"
on_exit() {
  local exit_code=$?
  if [[ $exit_code -ne 0 ]]; then
    echo "FAILED (exit code: $exit_code)" > "$BOOTSTRAP_STATUS"
    echo ""
    echo "!!! BOOTSTRAP FAILED at $(date) — exit code $exit_code"
    echo "!!! Check /var/log/cloud-init-bootstrap.log for details."
  fi
}
trap on_exit EXIT

echo "================================================================"
echo "  VPS Bootstrap starting: $(date)"
echo "================================================================"

# ── Injected variables (filled by Terraform templatefile()) ──────────────────
ADMIN_USER="${admin_username}"
ADMIN_PASS_B64="${admin_password_b64}"
SSH_PUBLIC_KEY="${ssh_public_key}"
SSH_PORT="${ssh_port}"
PANEL_PORT="${panel_port}"
PANEL_USERNAME="${panel_username}"
PANEL_PASSWORD="${panel_password}"
VLESS_PORT="${vless_port}"
HOME_IPS="${home_ips_space}"          # space-separated list
FAIL2BAN_IGNOREIP="${fail2ban_ignoreip}"

# =============================================================================
#  1. System update
# =============================================================================
echo ""
echo "── [1/9] System update ──────────────────────────────────────────"
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq
apt-get install -y -qq \
    curl ufw fail2ban unattended-upgrades sudo zram-tools
echo "System updated."

# Compressed RAM swap — avoids OOM on 1GB free-tier shapes without heavy disk thrash.
if [[ -f /etc/default/zramswap ]]; then
    sed -i 's/^[# ]*PERCENT=.*/PERCENT=40/' /etc/default/zramswap
fi
if systemctl list-unit-files --no-pager 2>/dev/null | grep -q '^zramswap\.service'; then
    systemctl enable zramswap.service
    systemctl start zramswap.service
fi

# =============================================================================
#  2. Create admin user
# =============================================================================
echo ""
echo "── [2/9] Creating user: $ADMIN_USER ─────────────────────────────"

if ! id "$ADMIN_USER" &>/dev/null; then
    useradd -m -s /bin/bash "$ADMIN_USER"
    echo "User $ADMIN_USER created."
fi

usermod -aG sudo "$ADMIN_USER"

# Passwordless sudo for this user
echo "$ADMIN_USER ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/$ADMIN_USER"
chmod 440 "/etc/sudoers.d/$ADMIN_USER"

# Install SSH key
USER_HOME="/home/$ADMIN_USER"
mkdir -p "$USER_HOME/.ssh"
echo "$SSH_PUBLIC_KEY" > "$USER_HOME/.ssh/authorized_keys"
chmod 700 "$USER_HOME/.ssh"
chmod 600 "$USER_HOME/.ssh/authorized_keys"
chown -R "$ADMIN_USER:$ADMIN_USER" "$USER_HOME/.ssh"

if [[ -n "$ADMIN_PASS_B64" ]]; then
  ADMIN_DEC=$(printf '%s' "$ADMIN_PASS_B64" | base64 -d) || { echo "ERROR: admin_password decode failed"; exit 1; }
  printf '%s:%s\n' "$ADMIN_USER" "$ADMIN_DEC" | chpasswd
  echo "Password set for $ADMIN_USER (console / local login). SSH remains key-only."
fi

# Also add to root as emergency fallback
mkdir -p /root/.ssh
grep -qF "$SSH_PUBLIC_KEY" /root/.ssh/authorized_keys 2>/dev/null \
    || echo "$SSH_PUBLIC_KEY" >> /root/.ssh/authorized_keys
chmod 700 /root/.ssh
chmod 600 /root/.ssh/authorized_keys

echo "SSH key installed for $ADMIN_USER and root."

# =============================================================================
#  3. SSH hardening
# =============================================================================
echo ""
echo "── [3/9] SSH hardening ──────────────────────────────────────────"

SSHD_CONFIG="/etc/ssh/sshd_config"
cp "$SSHD_CONFIG" "$${SSHD_CONFIG}.bak"

set_ssh_opt() {
    local key="$1" val="$2"
    if grep -qE "^#?\s*$${key}" "$SSHD_CONFIG"; then
        sed -i "s|^#\?\s*$${key}.*|$${key} $${val}|" "$SSHD_CONFIG"
    else
        echo "$${key} $${val}" >> "$SSHD_CONFIG"
    fi
}

set_ssh_opt "Port"                   "$SSH_PORT"
set_ssh_opt "PermitRootLogin"        "no"
set_ssh_opt "PasswordAuthentication" "no"
set_ssh_opt "PubkeyAuthentication"   "yes"
set_ssh_opt "AuthorizedKeysFile"     ".ssh/authorized_keys"
set_ssh_opt "PermitEmptyPasswords"   "no"
set_ssh_opt "X11Forwarding"          "no"
set_ssh_opt "MaxAuthTries"           "3"
set_ssh_opt "ClientAliveInterval"    "300"
set_ssh_opt "ClientAliveCountMax" "2"
set_ssh_opt "LoginGraceTime"         "30"

sshd -t || { echo "ERROR: sshd config invalid!"; cp "$${SSHD_CONFIG}.bak" "$SSHD_CONFIG"; exit 1; }
# Apply new port before UFW: otherwise sshd still listens on 22 while UFW only allows $SSH_PORT → lockout.
systemctl restart ssh
echo "SSH configured and listening on port $SSH_PORT."

# =============================================================================
#  4. UFW firewall
# =============================================================================
echo ""
echo "── [4/9] UFW firewall ───────────────────────────────────────────"

ufw --force reset > /dev/null
ufw default deny incoming > /dev/null
ufw default allow outgoing > /dev/null

# VLESS proxy — open to all
ufw allow "$VLESS_PORT"/tcp comment "VLESS proxy" > /dev/null
echo "Port $VLESS_PORT/tcp (VLESS) open to all."

# SSH and panel — each home IP (ping: OCI security list only; UFW here rejects proto icmp via CLI)
for ip in $HOME_IPS; do
    ufw allow from "$ip" to any port "$SSH_PORT"  proto tcp comment "SSH from $ip"   > /dev/null
    ufw allow from "$ip" to any port "$PANEL_PORT" proto tcp comment "Panel from $ip" > /dev/null
    echo "SSH ($SSH_PORT) and panel ($PANEL_PORT) allowed from $ip."
done

ufw --force enable > /dev/null
echo "UFW enabled."

# =============================================================================
#  5. Fail2ban
# =============================================================================
echo ""
echo "── [5/9] Fail2ban ───────────────────────────────────────────────"

cat > /etc/fail2ban/jail.local << EOF
[DEFAULT]
bantime  = 3600
findtime = 600
maxretry = 3
ignoreip = $FAIL2BAN_IGNOREIP

[sshd]
enabled  = true
port     = $SSH_PORT
filter   = sshd
logpath  = /var/log/auth.log
maxretry = 3
bantime  = 86400
EOF

systemctl enable fail2ban > /dev/null
systemctl restart fail2ban
echo "Fail2ban configured."

# =============================================================================
#  6. Automatic security updates
# =============================================================================
echo ""
echo "── [6/9] Automatic security updates ────────────────────────────"

cat > /etc/apt/apt.conf.d/50unattended-upgrades << 'EOF'
Unattended-Upgrade::Allowed-Origins {
    "$${distro_id}:$${distro_codename}-security";
};
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
EOF

cat > /etc/apt/apt.conf.d/20auto-upgrades << 'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

systemctl enable unattended-upgrades > /dev/null
systemctl restart unattended-upgrades
echo "Automatic security updates enabled."

install -d /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/99-size.conf << 'EOF'
[Journal]
SystemMaxUse=48M
RuntimeMaxUse=32M
MaxRetentionSec=3day
EOF
systemctl restart systemd-journald

# =============================================================================
#  7. Kernel hardening
# =============================================================================
echo ""
echo "── [7/9] Kernel hardening ───────────────────────────────────────"

cat > /etc/sysctl.d/99-hardening.conf << 'EOF'
# IP spoofing protection
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# Ignore ICMP redirects
net.ipv4.conf.all.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0

# Ignore send redirects
net.ipv4.conf.all.send_redirects = 0

# Disable source packet routing
net.ipv4.conf.all.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0

# SYN flood protection
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 2048
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_syn_retries = 5

# Log martians
net.ipv4.conf.all.log_martians = 1

# IPv6 hardening — accept RA only from the cloud network, not rogue sources
net.ipv6.conf.all.accept_ra = 0
net.ipv6.conf.default.accept_ra = 0

# Low-RAM / small VM (e.g. OCI VM.Standard.E2.1.Micro — 1GB)
vm.swappiness = 80
vm.vfs_cache_pressure = 50
EOF

sysctl -p /etc/sysctl.d/99-hardening.conf > /dev/null
echo "Kernel hardening applied."

# =============================================================================
#  8. 3X-UI via Docker Compose + Watchtower
# =============================================================================
# Non-interactive, matches upstream Docker guidance:
# https://github.com/MHSanaei/3x-ui/wiki/Installation#using-docker-compose
# Panel listens on 2053 inside the image until we apply setting -port to match $PANEL_PORT
# (Oracle Security List + UFW already use PANEL_PORT).
echo ""
echo "── [8/9] Docker, 3X-UI (Compose), Watchtower ────────────────────"

export DEBIAN_FRONTEND=noninteractive
curl -fsSL https://get.docker.com | sh

install -d /etc/docker
cat > /etc/docker/daemon.json << 'DOCKERCFG_EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "2"
  }
}
DOCKERCFG_EOF
systemctl enable docker
systemctl restart docker

usermod -aG docker "$ADMIN_USER"

install -d -m 0755 /opt/3x-ui/db /opt/3x-ui/cert

cat > /opt/3x-ui/compose.yml << 'COMPOSE_EOF'
services:
  3xui:
    image: ghcr.io/mhsanaei/3x-ui:latest
    container_name: 3xui_app
    volumes:
      - ./db:/etc/x-ui
      - ./cert:/root/cert
    environment:
      # Host fail2ban already protects SSH; panel is restricted by UFW. Saves RAM vs in-container fail2ban.
      XUI_ENABLE_FAIL2BAN: "false"
    tty: true
    network_mode: host
    restart: unless-stopped
    labels:
      com.centurylinklabs.watchtower.enable: "true"

  watchtower:
    image: containrrr/watchtower:latest
    container_name: watchtower
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
    environment:
      WATCHTOWER_LABEL_ENABLE: "true"
      WATCHTOWER_CLEANUP: "true"
    command: --interval 86400
    restart: unless-stopped
    deploy:
      resources:
        limits:
          cpus: "0.15"
          memory: 64M
COMPOSE_EOF

cd /opt/3x-ui
docker compose pull
docker compose up -d

echo "Waiting for 3X-UI database (/etc/x-ui/x-ui.db)..."
DB_READY=0
for _ in $(seq 1 60); do
  if docker compose exec -T 3xui test -f /etc/x-ui/x-ui.db 2>/dev/null; then
    DB_READY=1
    break
  fi
  sleep 2
done

if [[ "$DB_READY" -eq 1 ]]; then
  docker compose exec -T 3xui /app/x-ui setting -username "$PANEL_USERNAME" -password "$PANEL_PASSWORD" -port "$PANEL_PORT"
  docker compose restart 3xui
  echo "3X-UI panel configured: port=$PANEL_PORT, credentials set via Terraform."
else
  echo "WARNING: database not ready in time; panel may still be on defaults."
  echo "Fix: sudo docker compose -f /opt/3x-ui/compose.yml exec -T 3xui /app/x-ui setting -username \"$PANEL_USERNAME\" -password \"$PANEL_PASSWORD\" -port $PANEL_PORT"
  echo "      sudo docker compose -f /opt/3x-ui/compose.yml restart 3xui"
fi

echo "Panel credentials are in Terraform output: terraform output panel_credentials"
echo "Watchtower updates the labeled 3xui container daily (86400s); review releases for breaking changes."

# =============================================================================
#  9. SSH (already on $SSH_PORT since step 3; restart once more after heavy I/O)
# =============================================================================
echo ""
echo "── [9/9] SSH service check ─────────────────────────────────────"
systemctl restart ssh
echo "SSH active on port $SSH_PORT."

# =============================================================================
#  Done
# =============================================================================
echo "OK" > "$BOOTSTRAP_STATUS"

echo ""
echo "================================================================"
echo "  Bootstrap complete: $(date)"
echo "  SSH port  : $SSH_PORT"
echo "  Panel port: $PANEL_PORT"
echo "  VLESS port: $VLESS_PORT"
echo "  Home IPs  : $HOME_IPS"
echo "  Status    : $BOOTSTRAP_STATUS"
echo "================================================================"
