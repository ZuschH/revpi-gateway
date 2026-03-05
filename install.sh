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

usage() {
  cat <<'EOF'
Usage:
  sudo ./install.sh [--offline] [--yes] [--backup] [--restore <dir>] [--dry-run] [--export <file.tar.gz>]

Modes:
  (default)   Interaktive Installation / Update / Repair
  --offline   Installiert Debian-Pakete aus ./packages/ (kein Internet nötig)
  --backup    Erstellt nur ein Backup und beendet
  --restore   Stellt aus einem Backup-Verzeichnis wieder her und beendet
  --dry-run   Zeigt geplante Änderungen, ohne etwas zu verändern
  --export    Exportiert aktuelle Gateway-Konfiguration nach <file.tar.gz> und beendet

Notes:
  - Konfiguration: /etc/revpi-gateway.conf
  - Portforwards: /etc/nftables.d/portforwards_*.nft
  - Backups:      /var/backups/revpi-gateway/<timestamp>/
EOF
}

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "Bitte als root ausführen: sudo $0" >&2
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
}

do_backup() {
  local dest="$BACKUP_ROOT/$(now_ts)"
  echo "== Backup nach $dest =="
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "DRY-RUN> würde sichern: /etc/nftables.conf, /etc/nftables.d/*, $APP_CONF, /etc/sysctl.d/99-revpi-gateway.conf"
    echo "DRY-RUN> Ziel: $dest"
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
  echo "OK: Backup erstellt: $dest"
}

restore_from() {
  local src="$1"
  if [[ ! -d "$src" ]]; then
    echo "ERROR: Restore-Quelle existiert nicht: $src" >&2
    exit 1
  fi

  echo "== Restore von $src =="
  if confirm "Aktuelle Konfiguration vorher sichern?"; then
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

  echo "OK: Restore abgeschlossen."
}

export_current() {
  local out="$1"
  if [[ -z "$out" ]]; then
    echo "ERROR: --export benötigt eine Zieldatei, z.B. --export /mnt/usb/revpi-gateway-export.tar.gz" >&2
    exit 1
  fi

  echo "== Export nach $out =="

  # minimal set (add more if you want)
  local tmpdir="/tmp/revpi-gateway-export.$$"
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "DRY-RUN> würde exportieren:"
    echo "  /etc/nftables.conf"
    echo "  /etc/nftables.d/*"
    echo "  $APP_CONF"
    echo "  /etc/sysctl.d/99-revpi-gateway.conf"
    echo "  Listener snapshot: ss -lntup"
    echo "  nft snapshot: nft list ruleset"
    echo "  Ziel: $out"
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

  echo "OK: Export erstellt: $out"
}

install_packages_online() {
  echo "== Pakete (online) installieren =="
  run "apt-get update"
  run "apt-get install -y --no-install-recommends \
    nftables iproute2 iputils-ping tcpdump curl ca-certificates \
    openssh-server \
    cockpit cockpit-bridge cockpit-system \
    apache2"
}

install_packages_offline() {
  echo "== Pakete (offline) installieren aus ./packages/ =="
  if [[ ! -d "./packages" ]]; then
    echo "ERROR: ./packages/ nicht gefunden. Offline-Bundle benutzen." >&2
    exit 1
  fi
  shopt -s nullglob
  local debs=(./packages/*.deb)
  if [[ ${#debs[@]} -eq 0 ]]; then
    echo "ERROR: Keine .deb Dateien in ./packages/. Offline-Bundle ist leer." >&2
    exit 1
  fi

  run "dpkg -i ./packages/*.deb || true"
  run "apt-get -o Dir::Cache::archives=\"$(pwd)/packages\" --no-download -f install -y"
}

enable_ip_forward() {
  echo "== IP Forwarding aktivieren =="
  run "sysctl -w net.ipv4.ip_forward=1 >/dev/null"
  run "mkdir -p /etc/sysctl.d"
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "DRY-RUN> würde schreiben: /etc/sysctl.d/99-revpi-gateway.conf (net.ipv4.ip_forward=1)"
  else
    cat >/etc/sysctl.d/99-revpi-gateway.conf <<EOF
net.ipv4.ip_forward=1
EOF
  fi
  run "sysctl --system >/dev/null || true"
}

deploy_base_files() {
  echo "== Basis-Dateien ausrollen =="

  if [[ "$DRY_RUN" == "1" ]]; then
    echo "DRY-RUN> würde installieren:"
    echo "  /etc/nftables.conf (aus files/etc/nftables.conf)"
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
    echo "== Portforwards installieren (Neuinstallation) =="
    if [[ "$DRY_RUN" == "1" ]]; then
      echo "DRY-RUN> würde überschreiben:"
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
    echo "Vorhandene Portforwards gefunden."
    if confirm "Portforwards durch Repo-Defaults ersetzen (überschreibt lokale Anpassungen)?"; then
      if [[ "$DRY_RUN" == "1" ]]; then
        echo "DRY-RUN> würde Portforwards überschreiben (Repo-Defaults)."
      else
        install -m 0644 -D "files/etc/nftables.d/portforwards_tcp.nft" /etc/nftables.d/portforwards_tcp.nft
        install -m 0644 -D "files/etc/nftables.d/portforwards_udp.nft" /etc/nftables.d/portforwards_udp.nft
      fi
    else
      echo "OK: Portforwards bleiben unverändert."
    fi
  else
    echo "Keine Portforwards vorhanden → installiere Defaults."
    if [[ "$DRY_RUN" == "1" ]]; then
      echo "DRY-RUN> würde Defaults anlegen."
    else
      install -m 0644 -D "files/etc/nftables.d/portforwards_tcp.nft" /etc/nftables.d/portforwards_tcp.nft
      install -m 0644 -D "files/etc/nftables.d/portforwards_udp.nft" /etc/nftables.d/portforwards_udp.nft
    fi
  fi
}

patch_config() {
  local wan_if="$1" lan_net="$2"
  echo "== Konfiguration patchen (WAN_IF=$wan_if, LAN_NET=$lan_net) =="

  if [[ "$DRY_RUN" == "1" ]]; then
    echo "DRY-RUN> würde ersetzen:"
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
  echo "== Speichere $APP_CONF =="
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "DRY-RUN> würde schreiben:"
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

echo "== Speichere Versionsinfo =="

if [[ "$DRY_RUN" == "1" ]]; then
  echo "DRY-RUN> würde schreiben: /etc/revpi-gateway.version"
else
  cat > /etc/revpi-gateway.version <<EOF
revpi-gateway
version=$INSTALL_VERSION
git=$INSTALL_GIT
installed=$(date -Is)
EOF
fi

apply_nftables() {
  echo "== nftables laden =="
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "DRY-RUN> würde ausführen: nft -f /etc/nftables.conf && systemctl enable --now nftables"
    return 0
  fi
  nft -f /etc/nftables.conf
  systemctl enable --now nftables
}

smoke_tests() {
  echo "== Smoke Tests =="
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "DRY-RUN> würde prüfen:"
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
    echo "Vorhandene Installation erkannt."
    echo "  1) Update/Repair (empfohlen; Portforwards bleiben standardmäßig erhalten)"
    echo "  2) Neuinstallation (überschreibt Portforwards)"
    echo "  3) Abbrechen"
    local choice
    read -r -p "Auswahl [1]: " choice
    choice="${choice:-1}"
    case "$choice" in
      1) echo "update" ;;
      2) echo "install" ;;
      *) echo "abort" ;;
    esac
  else
    echo "Keine Installation erkannt → Neuinstallation."
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
    *) echo "Unbekannte Option: $1" >&2; usage; exit 1 ;;
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
echo "Aktuelle Interfaces:"
ip -br a || true
echo

ACTION="$(choose_action)"
if [[ "$ACTION" == "abort" ]]; then
  echo "Abgebrochen."
  exit 0
fi

WAN_IF="$(prompt_default "WAN Interface (Kundennetz)" "$WAN_IF_DEFAULT")"
LAN_IF="$(prompt_default "LAN Interface (Maschinen-LAN)" "$LAN_IF_DEFAULT")"
LAN_NET="$(prompt_default "LAN Netz (CIDR)" "$LAN_NET_DEFAULT")"

echo
echo "Aktion: $ACTION"
echo "Konfiguration:"
echo "  WAN_IF = $WAN_IF"
echo "  LAN_IF = $LAN_IF"
echo "  LAN_NET= $LAN_NET"
echo

if ! exists_iface "$WAN_IF"; then echo "WARN: Interface '$WAN_IF' existiert nicht." >&2; fi
if ! exists_iface "$LAN_IF"; then echo "WARN: Interface '$LAN_IF' existiert nicht." >&2; fi

if ! confirm "Fortfahren? (Backup wird erstellt)"; then
  echo "Abgebrochen."
  exit 0
fi

do_backup

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

echo "== Marker schreiben =="
if [[ "$DRY_RUN" == "1" ]]; then
  echo "DRY-RUN> würde schreiben: $MARKER"
else
  echo "installed $(date -Is)" > "$MARKER"
  chmod 0644 "$MARKER"
fi

apply_nftables
smoke_tests

echo
echo "OK: Gateway $ACTION abgeschlossen."
echo "Portforwards:"
echo "  /etc/nftables.d/portforwards_tcp.nft"
echo "  /etc/nftables.d/portforwards_udp.nft"
echo "Backup-Ordner: $BACKUP_ROOT"


