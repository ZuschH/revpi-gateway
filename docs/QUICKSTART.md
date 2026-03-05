Online: sudo ./install.sh

Offline: sudo ./install.sh --offline

Dry-Run: sudo ./install.sh --dry-run

Export: sudo ./install.sh --export /mnt/usb/revpi-gateway-export.tar.gz

Backup only: sudo ./install.sh --backup

Restore: sudo ./install.sh --restore /var/backups/revpi-gateway/20260305-123456

Portforwards pflegen in /etc/nftables.d/portforwards_*.nft

Reload: sudo nft -f /etc/nftables.conf

Report: sudo revpi-firewall-report /root/firewall-report.md




Standard (with packages):
./build-offline-bundle.sh 0.1.0
ls -l dist/

Without packages (only config & scripts):
WITH_PACKAGES=0 ./build-offline-bundle.sh 0.1.0

Own package list:
PKG_LIST="nftables iproute2 tcpdump cockpit apache2" ./build-offline-bundle.sh 0.1.0







Update/Repair

Installer erkennt Installation automatisch

wählt standardmäßig „Update/Repair“

Portforwards werden nicht überschrieben (außer man bestätigt)

Backups

vor jeder Installation/Update wird ein Backup erstellt:

/var/backups/revpi-gateway/<timestamp>/


