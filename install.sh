#!/usr/bin/env bash

VERSION_FILE="./VERSION.txt"
INSTALL_VERSION="unknown"
INSTALL_GIT="nogit"

if [[ -f "$VERSION_FILE" ]]; then
  INSTALL_VERSION="$(grep -E '^Version:' "$VERSION_FILE" | awk '{print $2}')"
fi

if command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  INSTALL_GIT="$(git rev-parse --short HEAD 2>/dev/null || echo nogit)"
fi

set -euo pipefail

APP_CONF="/etc/revpi-gateway.conf"
MARKER="/etc/revpi-gateway.installed"
BACKUP_ROOT="/var/backups/revpi-gateway"

OFFLINE=0
YES=0

DO_BACKUP_ONLY=0
RESTORE_DIR=""
DRY_RUN=0
EXPORT_FILE=""

FTP_USER=""
FTP_PW=""



usage() {
  cat <<'EOF'
Usage:
  sudo ./install.sh [--offline] [--yes] [--backup] [--restore <dir>] [--dry-run] [--export <file.tar.gz>]

Modes:
  (default)   Interactive installation / Update / Repair
  --offline   Installs Debian packages from ./packages/ (no Internet required)
  --backup    Creates Backup only and ends
  --restore   Restores configuration from backup sirectory end ends
  --dry-run   Simulates installation without modifications
  --export    Exports actual Gateway configuration to <file.tar.gz> and ends

Notes:
  - Configuration: /etc/revpi-gateway.conf
  - Port forwards: /etc/nftables.d/portforwards_*.nft
  - Backups      :      /var/backups/revpi-gateway/<timestamp>/
EOF
}

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "Please start as root: sudo $0" >&2
    exit 1
  fi
}

prompt_default() {
  local label="$1" default="$2" var
  read -r -p "${label} [${default}]: " var
  echo "${var:-$default}"
}

confirm() {
  local msg="$1"
  if [[ "$YES" == "1" ]]; then return 0; fi
  read -r -p "$msg [y/N] " ans
  [[ "${ans,,}" == "y" || "${ans,,}" == "yes" ]]
}

exists_iface() { ip link show "$1" >/dev/null 2>&1; }
now_ts() { date +%Y%m%d-%H%M%S; }

run() {
  # wrapper: respects DRY_RUN
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "DRY-RUN> $*"
  else
    eval "$@"
  fi
}

ensure_dirs() {
  run "mkdir -p /etc/nftables.d"
  run "mkdir -p \"$BACKUP_ROOT\""
  run "mkdir -p /srv/ftp"
  # run "mkdir -p /srv/ftp/hakko/{in,out,log}"
  run "chown -R root:root /srv/ftp"
  run "chmod -R 755 /srv/ftp"
}

choose_ftp_mode() {
  echo "== FTP PASV configuration ==" >&2
  echo "1) Static WAN IP (manual)" >&2
  echo "2) DHCP auto-detect (recommended)" >&2

  local choice
  read -r -p "Auswahl [2]: " choice
  choice="${choice:-2}"

  case "$choice" in
    1)
      echo "static"
      ;;
    2)
      echo "dhcp"
      ;;
    *)
      echo "dhcp"
      ;;
  esac
}

setup_vsftpd_pasv() {
  echo "== Configure vsftpd PASV =="

  local CONF="/etc/vsftpd.conf"

  if [[ "$FTP_MODE" == "static" ]]; then
    WAN_IP="$FTP_PASV_IP"
    echo "Using static IP: $WAN_IP"
  else
    WAN_IP=$(ip -4 addr show "$WAN_IF" | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
    echo "Detected WAN IP: $WAN_IP"
  fi

  if [ -z "$WAN_IP" ]; then
    echo "ERROR: No WAN IP available"
    return 1
  fi

  if grep -q "^pasv_address=" "$CONF"; then
    sed -i "s/^pasv_address=.*/pasv_address=$WAN_IP/" "$CONF"
  else
    echo "pasv_address=$WAN_IP" >> "$CONF"
  fi
}

ask_static_ip() {
  local ip
  read -r -p "Enter WAN IP for FTP PASV: " ip
  echo "$ip"
}

save_ftp_config() {
  local mode="$1"
  local ip="$2"

  mkdir -p /etc/revpi-gateway

  cat >> /etc/revpi-gateway/revpi-gateway.conf <<EOF
FTP_MODE="$mode"
FTP_PASV_IP="$ip"
EOF
}

setup_vsftpd_pasv() {
  echo "== Configure vsftpd PASV address (DHCP-aware) =="
  local IFACE="${WAN_IF:-eth1}"
  local CONF="/etc/vsftpd.conf"

  WAN_IP=$(ip -4 addr show "$IFACE" | grep -oP '(?<=inet\s)\d+(\.\d+){3}')

  if [ -z "$WAN_IP" ]; then
    echo "ERROR: No IP detected on $IFACE"
    return 1
  fi

  echo "Detected WAN IP: $WAN_IP"

  if grep -q "^pasv_address=" "$CONF"; then
    sed -i "s/^pasv_address=.*/pasv_address=$WAN_IP/" "$CONF"
  else
    echo "pasv_address=$WAN_IP" >> "$CONF"
  fi
}

install_vsftpd_pasv_helper() {
  echo "== Install vsftpd PASV auto-update helper =="

  cat >/usr/local/sbin/update-vsftpd-pasv.sh <<'EOF'
#!/bin/bash

IFACE="eth1"
CONF="/etc/vsftpd.conf"

WAN_IP=$(ip -4 addr show "$IFACE" | grep -oP '(?<=inet\s)\d+(\.\d+){3}')

if [ -z "$WAN_IP" ]; then
  echo "No IP found on $IFACE"
  exit 1
fi

echo "Updating PASV address to $WAN_IP"

if grep -q "^pasv_address=" "$CONF"; then
  sed -i "s/^pasv_address=.*/pasv_address=$WAN_IP/" "$CONF"
else
  echo "pasv_address=$WAN_IP" >> "$CONF"
fi

systemctl restart vsftpd
EOF

  chmod +x /usr/local/sbin/update-vsftpd-pasv.sh
}

install_vsftpd_pasv_service() {
  echo "== Install systemd service for PASV update =="

  cat >/etc/systemd/system/vsftpd-pasv-update.service <<'EOF'
[Unit]
Description=Update vsftpd PASV address from DHCP
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/update-vsftpd-pasv.sh

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reexec
  systemctl daemon-reload
  systemctl enable vsftpd-pasv-update.service
}

install_dhcp_hook() {
  if [[ "$FTP_MODE" != "dhcp" ]]; then
    echo "Skipping DHCP hook (static mode)"
    return
  fi

  echo "== Install DHCP hook for PASV update =="

  mkdir -p /etc/dhcp/dhclient-exit-hooks.d

  cat >/etc/dhcp/dhclient-exit-hooks.d/vsftpd <<'EOF'
#!/bin/bash
/usr/local/sbin/update-vsftpd-pasv.sh
EOF

  chmod +x /etc/dhcp/dhclient-exit-hooks.d/vsftpd
}

setup_ftp_env() {
  echo "Setting up ftp environment..."

  rm -rf /etc/modules-load.d/ftp.conf
  echo "nf_conntrack_ftp" > /etc/modules-load.d/ftp.conf
  modprobe nf_conntrack_ftp

  # Set vsftpd parameters
  install -m 644 -D "files/etc/vsftpd.conf" /etc/vsftpd.conf

  # Create users
#  run "useradd -d /srv/ftp/ -s /bin/sh ftpuser || true"
#  run "useradd -d /srv/ftp/ -s /bin/sh ftp || true"
#  run "useradd -d /srv/ftp/ -s /bin/sh dobby || true"

  grep -qxF /bin/false /etc/shells || echo /bin/false | sudo tee -a /etc/shells

  # Set passwords
#  echo 'ftpuser:ftpuser' | sudo chpasswd
#  echo 'ftp:ftp' | sudo chpasswd
#  echo 'dobby:dobby' | sudo chpasswd

  FTP_USER="$(prompt_default "FTP username on Hakko" "ftp")"
  FTP_PW="$(prompt_default "FTP password on Hakko" "ftp")"

  # Generate .env file
  if [[ -f /etc/hakko-ftp.env ]]; then
    cp -a /etc/hakko-ftp.env "/etc/hakko-ftp.env.bak.$(now_ts)" || true
  fi

  rm -rf /etc/hakko-ftp.env
  #install -m 644 /dev/null /etc/hakko-ftp.env
  touch /etc/hakko-ftp.env
  echo "HAKKO_HOST='192.168.19.3'" >> /etc/hakko-ftp.env
  echo "HAKKO_USER='$FTP_USER'" >> /etc/hakko-ftp.env
  echo "HAKKO_PASS='$FTP_PW'" >> /etc/hakko-ftp.env
  echo "HAKKO_REMOTE_DIR='/'" >> /etc/hakko-ftp.env

  echo "== Setup FTP user =="
  local USER="ftpuser"
  local PASS="ftpuser"
  local HOME="/srv/ftp"
  if ! id "$USER" &>/dev/null; then
    echo "Creating user $USER"
    useradd -m -d "$HOME" -s /bin/bash "$USER"
    echo "$USER:$PASS" | chpasswd
  else
    echo "User $USER already exists"
    usermod -s /bin/bash "$USER"
  fi

  local USER="ftp"
  local PASS="ftp"
  local HOME="/srv/ftp"
  if ! id "$USER" &>/dev/null; then
    echo "Creating user $USER"
    useradd -m -d "$HOME" -s /bin/bash "$USER"
    echo "$USER:$PASS" | chpasswd
  else
    echo "User $USER already exists"
    usermod -s /bin/bash "$USER"
  fi

  local USER="dobby"
  local PASS="dobby"
  local HOME="/srv/ftp"
  if ! id "$USER" &>/dev/null; then
    echo "Creating user $USER"
    useradd -m -d "$HOME" -s /bin/bash "$USER"
    echo "$USER:$PASS" | chpasswd
  else
    echo "User $USER already exists"
    usermod -s /bin/bash "$USER"
  fi

  # File system access rights
  run "chown -R ftpuser:ftpuser /srv/ftp"


  mkdir -p "$HOME"
  chown -R "$USER:$USER" "$HOME"


#  grep -q "^pasv_address=" /etc/vsftpd.conf \
#  && sed -i "s/^pasv_address=.*/pasv_address=$WAN_IP/" /etc/vsftpd.conf \
#  || echo "pasv_address=$WAN_IP" >> /etc/vsftpd.conf

#  service vsftpd restart
#  journalctl -u vsftpd -n200 --no-pager

  # Install scripts for ftp push/pull
  install -m 644 -D "files/usr/local/bin/hakko-pull.sh" /usr/local/bin/hakko-pull.sh
  install -m 644 -D "files/usr/local/bin/hakko-push.sh" /usr/local/bin/hakko-push.sh

  # Set up systemd timer for ftp push/pull
  install -m 644 -D "files/etc/systemd/system/hakko-pull.service" /etc/systemd/system/hakko-pull.service
  install -m 644 -D "files/etc/systemd/system/hakko-push.service" /etc/systemd/system/hakko-push.service
  install -m 644 -D "files/etc/systemd/system/hakko-pull.timer" /etc/systemd/system/hakko-pull.timer
  install -m 644 -D "files/etc/systemd/system/hakko-push.timer" /etc/systemd/system/hakko-push.timer
  systemctl daemon-reload
  systemctl enable --now hakko-pull.timer hakko-push.timer
  echo "Activated services:"
  systemctl list-timers | grep hakko
  echo "Ftp environment setup finished."

}


do_backup() {
  local dest="$BACKUP_ROOT/$(now_ts)"
  echo "== Backup nach $dest =="
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "DRY-RUN> would save: /etc/nftables.conf, /etc/nftables.d/*, $APP_CONF, /etc/sysctl.d/99-revpi-gateway.conf"
    echo "DRY-RUN> Destination: $dest"
    return 0
  fi

  mkdir -p "$dest"
  [[ -f /etc/nftables.conf ]] && cp -a /etc/nftables.conf "$dest/etc.nftables.conf" || true
  [[ -f "$APP_CONF" ]] && cp -a "$APP_CONF" "$dest/revpi-gateway.conf" || true
  [[ -f "$MARKER" ]] && cp -a "$MARKER" "$dest/revpi-gateway.installed" || true

  if [[ -d /etc/nftables.d ]]; then
    mkdir -p "$dest/etc.nftables.d"
    cp -a /etc/nftables.d/* "$dest/etc.nftables.d/" 2>/dev/null || true
  fi

  [[ -f /etc/sysctl.d/99-revpi-gateway.conf ]] && cp -a /etc/sysctl.d/99-revpi-gateway.conf "$dest/sysctl.99-revpi-gateway.conf" || true
  echo "OK: Backup created: $dest"
}

restore_from() {
  local src="$1"
  if [[ ! -d "$src" ]]; then
    echo "ERROR: Restore repository does not exist: $src" >&2
    exit 1
  fi

  echo "== Restore from $src =="
  if confirm "Back up the current configuration?"; then
    do_backup
  fi

  run "[[ -f \"$src/etc.nftables.conf\" ]] && cp -a \"$src/etc.nftables.conf\" /etc/nftables.conf || true"
  run "[[ -f \"$src/revpi-gateway.conf\" ]] && cp -a \"$src/revpi-gateway.conf\" \"$APP_CONF\" || true"
  run "[[ -f \"$src/revpi-gateway.installed\" ]] && cp -a \"$src/revpi-gateway.installed\" \"$MARKER\" || true"

  run "mkdir -p /etc/nftables.d"
  run "[[ -d \"$src/etc.nftables.d\" ]] && cp -a \"$src/etc.nftables.d/\"* /etc/nftables.d/ 2>/dev/null || true"

  run "[[ -f \"$src/sysctl.99-revpi-gateway.conf\" ]] && cp -a \"$src/sysctl.99-revpi-gateway.conf\" /etc/sysctl.d/99-revpi-gateway.conf || true"
  run "sysctl --system >/dev/null || true"

  echo "== nftables laden =="
  run "nft -f /etc/nftables.conf"
  run "systemctl enable --now nftables"

  echo "OK: Restore completed."
}

export_current() {
  local out="$1"
  if [[ -z "$out" ]]; then
    echo "ERROR: --export needs a Target file, e.g. --export /mnt/usb/revpi-gateway-export.tar.gz" >&2
    exit 1
  fi

  echo "== Export to $out =="

  # minimal set (add more if you want)
  local tmpdir="/tmp/revpi-gateway-export.$$"
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "DRY-RUN> would export:"
    echo "  /etc/nftables.conf"
    echo "  /etc/nftables.d/*"
    echo "  $APP_CONF"
    echo "  /etc/sysctl.d/99-revpi-gateway.conf"
    echo "  Listener snapshot: ss -lntup"
    echo "  nft snapshot: nft list ruleset"
    echo "  Target: $out"
    return 0
  fi

  rm -rf "$tmpdir"
  mkdir -p "$tmpdir"

  mkdir -p "$tmpdir/etc"
  [[ -f /etc/nftables.conf ]] && cp -a /etc/nftables.conf "$tmpdir/etc/nftables.conf" || true

  mkdir -p "$tmpdir/etc/nftables.d"
  [[ -d /etc/nftables.d ]] && cp -a /etc/nftables.d/* "$tmpdir/etc/nftables.d/" 2>/dev/null || true

  mkdir -p "$tmpdir/etc/sysctl.d"
  [[ -f /etc/sysctl.d/99-revpi-gateway.conf ]] && cp -a /etc/sysctl.d/99-revpi-gateway.conf "$tmpdir/etc/sysctl.d/99-revpi-gateway.conf" || true

  mkdir -p "$tmpdir/etc/revpi-gateway"
  [[ -f "$APP_CONF" ]] && cp -a "$APP_CONF" "$tmpdir/etc/revpi-gateway/revpi-gateway.conf" || true
  [[ -f /etc/revpi-gateway.version ]] && cp -a /etc/revpi-gateway.version "$tmpdir/etc/revpi-gateway.version" || true

  # snapshots helpful for support
  (ss -lntup 2>/dev/null || true) > "$tmpdir/ss-listeners.txt"
  (nft -nn list ruleset 2>/dev/null || true) > "$tmpdir/nft-ruleset.txt"
  (ip -br a 2>/dev/null || true) > "$tmpdir/ip-brief.txt"
  (sysctl net.ipv4.ip_forward 2>/dev/null || true) > "$tmpdir/sysctl-ip-forward.txt"

  tar czf "$out" -C "$tmpdir" .
  rm -rf "$tmpdir"

  echo "OK: Export created: $out"
}

install_packages_online() {
  echo "== Install Packages (online) =="
  run "apt-get update"
  run "apt-get install -y --no-install-recommends \
    nftables iproute2 iputils-ping tcpdump curl ca-certificates \
    openssh-server \
    cockpit cockpit-bridge cockpit-system \
    apache2 \
    vsftpd lftp"
}

install_packages_offline() {
  echo "== Install packages from (offline) ./packages/ =="
  if [[ ! -d "./packages" ]]; then
    echo "ERROR: ./packages/ not found. Use offline-Bundle." >&2
    exit 1
  fi
  shopt -s nullglob
  local debs=(./packages/*.deb)
  if [[ ${#debs[@]} -eq 0 ]]; then
    echo "ERROR: No .deb files found in ./packages/. Offline-Bundle is empty." >&2
    exit 1
  fi

  run "dpkg -i ./packages/*.deb || true"
  run "apt-get -o Dir::Cache::archives=\"$(pwd)/packages\" --no-download -f install -y"
}

enable_ip_forward() {
  echo "== Activate IP Forwarding =="
  run "sysctl -w net.ipv4.ip_forward=1 >/dev/null"
  run "mkdir -p /etc/sysctl.d"
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "DRY-RUN> would write: /etc/sysctl.d/99-revpi-gateway.conf (net.ipv4.ip_forward=1)"
  else
    cat >/etc/sysctl.d/99-revpi-gateway.conf <<EOF
net.ipv4.ip_forward=1
EOF
  fi
  run "sysctl --system >/dev/null || true"
}

deploy_base_files() {
  echo "== Deploy base files =="

  if [[ "$DRY_RUN" == "1" ]]; then
    echo "DRY-RUN> would install:"
    echo "  /etc/nftables.conf (from files/etc/nftables.conf)"
    echo "  /etc/nftables.d/README.portforwards.txt"
    echo "  /usr/local/sbin/revpi-firewall-report"
    return 0
  fi

  if [[ -f /etc/nftables.conf ]]; then
    cp -a /etc/nftables.conf "/etc/nftables.conf.bak.$(now_ts)" || true
  fi

  install -m 0644 -D "files/etc/nftables.conf" /etc/nftables.conf
  mkdir -p /etc/nftables.d
  install -m 0644 -D "files/etc/nftables.d/README.portforwards.txt" /etc/nftables.d/README.portforwards.txt
  install -m 0755 -D "files/usr/local/sbin/revpi-firewall-report" /usr/local/sbin/revpi-firewall-report
}

deploy_portforwards_if_needed() {
  local mode="$1" # install|update
  if [[ "$mode" == "install" ]]; then
    echo "== Install Port Forwards (New installation) =="
    if [[ "$DRY_RUN" == "1" ]]; then
      echo "DRY-RUN> would replace:"
      echo "  /etc/nftables.d/portforwards_tcp.nft"
      echo "  /etc/nftables.d/portforwards_udp.nft"
      return 0
    fi
    install -m 0644 -D "files/etc/nftables.d/portforwards_tcp.nft" /etc/nftables.d/portforwards_tcp.nft
    install -m 0644 -D "files/etc/nftables.d/portforwards_udp.nft" /etc/nftables.d/portforwards_udp.nft
    return 0
  fi

  echo "== Portforwards (Update/Repair) =="
  if [[ -f /etc/nftables.d/portforwards_tcp.nft || -f /etc/nftables.d/portforwards_udp.nft ]]; then
    echo "Existing Portforwards found."
    if confirm "Replace Portforwards by Repo Defaults (overwrites local modifications)?"; then
      if [[ "$DRY_RUN" == "1" ]]; then
        echo "DRY-RUN> would overwrite Portforwards (Repo Defaults)."
      else
        install -m 0644 -D "files/etc/nftables.d/portforwards_tcp.nft" /etc/nftables.d/portforwards_tcp.nft
        install -m 0644 -D "files/etc/nftables.d/portforwards_udp.nft" /etc/nftables.d/portforwards_udp.nft
      fi
    else
      echo "OK: Portforwards remain untouched."
    fi
  else
    echo "No Portforwards available → installing Defaults."
    if [[ "$DRY_RUN" == "1" ]]; then
      echo "DRY-RUN> would create Defaults."
    else
      install -m 0644 -D "files/etc/nftables.d/portforwards_tcp.nft" /etc/nftables.d/portforwards_tcp.nft
      install -m 0644 -D "files/etc/nftables.d/portforwards_udp.nft" /etc/nftables.d/portforwards_udp.nft
    fi
  fi
}

patch_config() {
  local wan_if="$1" lan_net="$2"
  echo "== Patch configuration (WAN_IF=$wan_if, LAN_NET=$lan_net) =="

  if [[ "$DRY_RUN" == "1" ]]; then
    echo "DRY-RUN> would replace:"
    echo "  iifname \"eth1\" -> iifname \"$wan_if\" in portforwards_*.nft"
    echo "  oifname \"eth1\" -> oifname \"$wan_if\" in /etc/nftables.conf"
    echo "  ip saddr 192.168.19.0/24 -> ip saddr $lan_net in /etc/nftables.conf"
    return 0
  fi

  sed -i "s/iifname \"eth1\"/iifname \"$wan_if\"/g" /etc/nftables.d/portforwards_tcp.nft 2>/dev/null || true
  sed -i "s/iifname \"eth1\"/iifname \"$wan_if\"/g" /etc/nftables.d/portforwards_udp.nft 2>/dev/null || true

  sed -i "s/oifname \"eth1\"/oifname \"$wan_if\"/g" /etc/nftables.conf
  sed -i "s#ip saddr 192.168.19.0/24#ip saddr $lan_net#g" /etc/nftables.conf
}

save_app_conf() {
  local wan_if="$1" lan_if="$2" lan_net="$3"
  echo "== Saving $APP_CONF =="
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "DRY-RUN> would write:"
    echo "  WAN_IF=\"$wan_if\""
    echo "  LAN_IF=\"$lan_if\""
    echo "  LAN_NET=\"$lan_net\""
    return 0
  fi
  cat > "$APP_CONF" <<EOF
# RevPi Gateway config (used by install.sh)
WAN_IF="$wan_if"
LAN_IF="$lan_if"
LAN_NET="$lan_net"
EOF
  chmod 0644 "$APP_CONF"
}

echo "== Saving version info =="

if [[ "$DRY_RUN" == "1" ]]; then
  echo "DRY-RUN> would write: /etc/revpi-gateway.version"
else
  cat > /etc/revpi-gateway.version <<EOF
revpi-gateway
version=$INSTALL_VERSION
git=$INSTALL_GIT
installed=$(date -Is)
EOF
fi

apply_nftables() {
  echo "== Load nftables =="
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "DRY-RUN> would execute: nft -f /etc/nftables.conf && systemctl enable --now nftables"
    return 0
  fi
  nft -f /etc/nftables.conf
  systemctl enable --now nftables
}

disable_conflicting_firewalls() {
  echo "== Deaktivating conflicting Firewall services =="

  if systemctl list-unit-files | grep -q '^firewalld.service'; then
    run "systemctl disable --now firewalld || true"
  fi
}

smoke_tests() {
  echo "== Smoke Tests =="
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "DRY-RUN> would check:"
    echo "  nft list chain ip nat prerouting"
    echo "  nft list chain ip nat postrouting"
    echo "  revpi-firewall-report | head"
    return 0
  fi
  nft list chain ip nat prerouting || true
  nft list chain ip nat postrouting || true
  /usr/local/sbin/revpi-firewall-report | sed -n '1,120p' || true
}

detect_installation() {
  [[ -f "$MARKER" || -f "$APP_CONF" || -f /etc/nftables.d/README.portforwards.txt ]]
}

choose_action() {
  if detect_installation; then
    echo "Detected existing installation." >&2
    echo "  1) Update/Repair (recommended; Portforwards will remain the same)" >&2
    echo "  2) New installation (overwrites Portforwards)" >&2
    echo "  3) Abort" >&2

    local choice
    read -r -p "Selection [1]: " choice
    choice="${choice:-1}"

    case "$choice" in
      1) echo "update" ;;
      2) echo "install" ;;
      *) echo "abort" ;;
    esac
  else
    echo "No installation detected → new installation." >&2
    echo "install"
  fi
}

# ---------- parse args ----------
need_root

while [[ $# -gt 0 ]]; do
  case "$1" in
    --offline) OFFLINE=1; shift ;;
    --yes|-y) YES=1; shift ;;
    --backup) DO_BACKUP_ONLY=1; shift ;;
    --restore) RESTORE_DIR="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --export) EXPORT_FILE="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown Option: $1" >&2; usage; exit 1 ;;
  esac
done

ensure_dirs

if [[ -n "$EXPORT_FILE" ]]; then
  export_current "$EXPORT_FILE"
  exit 0
fi

if [[ "$DO_BACKUP_ONLY" == "1" ]]; then
  do_backup
  exit 0
fi

if [[ -n "$RESTORE_DIR" ]]; then
  restore_from "$RESTORE_DIR"
  exit 0
fi

# ---------- defaults ----------
WAN_IF_DEFAULT="eth1"
LAN_IF_DEFAULT="eth0"
LAN_NET_DEFAULT="192.168.19.0/24"

if [[ -f "$APP_CONF" ]]; then
  # shellcheck disable=SC1090
  source "$APP_CONF" || true
  WAN_IF_DEFAULT="${WAN_IF:-$WAN_IF_DEFAULT}"
  LAN_IF_DEFAULT="${LAN_IF:-$LAN_IF_DEFAULT}"
  LAN_NET_DEFAULT="${LAN_NET:-$LAN_NET_DEFAULT}"
fi

echo "=================================================="
echo " RevPi Gateway Installer (interactive)"
echo " Version: $INSTALL_VERSION"
echo " Git:     $INSTALL_GIT"
echo " Mode: $([[ "$OFFLINE" == "1" ]] && echo OFFLINE || echo ONLINE)"
echo " Dry-Run: $([[ "$DRY_RUN" == "1" ]] && echo YES || echo NO)"
echo " Backups: $BACKUP_ROOT"
echo "=================================================="
echo
echo "Actual Interfaces:"
ip -br a || true
echo

ACTION="$(choose_action)"
if [[ "$ACTION" == "abort" ]]; then
  echo "Aborted."
  exit 0
fi

WAN_IF="$(prompt_default "WAN Interface (customer network)" "$WAN_IF_DEFAULT")"
LAN_IF="$(prompt_default "LAN Interface (machine LAN / el. box)" "$LAN_IF_DEFAULT")"
LAN_NET="$(prompt_default "LAN net (CIDR)" "$LAN_NET_DEFAULT")"
FTP_MODE="dhcp"     # dhcp | static
FTP_PASV_IP=""      # nur bei static

echo
echo "Action: $ACTION"
echo "Configuration:"
echo "  WAN_IF = $WAN_IF"
echo "  LAN_IF = $LAN_IF"
echo "  LAN_NET= $LAN_NET"
echo

if ! exists_iface "$WAN_IF"; then echo "WARN: Interface '$WAN_IF' does not exist." >&2; fi
if ! exists_iface "$LAN_IF"; then echo "WARN: Interface '$LAN_IF' does not exist." >&2; fi

if ! confirm "Continue? (Backup will be created)"; then
  echo "Aborted."
  exit 0
fi

do_backup
chmod +x build-offline-bundle.sh
chmod +x uninstall.sh

if [[ "$OFFLINE" == "1" ]]; then
  install_packages_offline
else
  install_packages_online
fi

enable_ip_forward
deploy_base_files
deploy_portforwards_if_needed "$ACTION"
patch_config "$WAN_IF" "$LAN_NET"
save_app_conf "$WAN_IF" "$LAN_IF" "$LAN_NET"

echo "== Write marker =="
if [[ "$DRY_RUN" == "1" ]]; then
  echo "DRY-RUN> would write: $MARKER"
else
  echo "installed $(date -Is)" > "$MARKER"
  chmod 0644 "$MARKER"
fi

disable_conflicting_firewalls
apply_nftables
setup_ftp_env
FTP_MODE="$(choose_ftp_mode)"

if [[ "$FTP_MODE" == "static" ]]; then
  FTP_PASV_IP="$(ask_static_ip)"
else
  FTP_PASV_IP=""
fi

save_ftp_config "$FTP_MODE" "$FTP_PASV_IP"

setup_vsftpd_pasv
install_vsftpd_pasv_helper
install_vsftpd_pasv_service
install_dhcp_hook

systemctl restart vsftpd

echo
echo "$(date) Updated PASV IP to $WAN_IP" >> /var/log/vsftpd-pasv.log
echo

smoke_tests

echo
echo "OK: Gateway $ACTION completed."
echo "Portforwards:"
echo "  /etc/nftables.d/portforwards_tcp.nft"
echo "  /etc/nftables.d/portforwards_udp.nft"
echo "Backup directory: $BACKUP_ROOT"


