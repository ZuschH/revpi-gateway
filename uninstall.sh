#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Please execute as root: sudo $0" >&2
  exit 1
fi

echo "== Stop nftables =="
systemctl disable --now nftables 2>/dev/null || true

echo "== Remove files =="
rm -f /usr/local/sbin/revpi-firewall-report
rm -f /etc/sysctl.d/99-revpi-gateway.conf
rm -f /etc/nftables.d/portforwards_tcp.nft
rm -f /etc/nftables.d/portforwards_udp.nft
rm -f /etc/nftables.d/README.portforwards.txt
rm -f /etc/revpi-gateway.conf

# nftables.conf nicht hart löschen — nur Hinweis
echo "Remark: /etc/nftables.conf was not deleted."
echo "If you want to revert to the default settings, restore a backup: /etc/nftables.conf.bak.*"

echo "== sysctl reload =="
sysctl --system >/dev/null || true

echo "OK: Uninstall complete."


