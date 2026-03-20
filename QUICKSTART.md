
1) Execution bit:
=================
  chmod +x install.sh

2) Install:
===========
  Online:
    sudo ./install.sh

  Offline:
    sudo ./install.sh --offline

Appendix / Options:
===================
  Dry-Run:
    sudo ./install.sh --dry-run

  Export:
    sudo ./install.sh --export /mnt/usb/revpi-gateway-export.tar.gz

  Backup only:
    sudo ./install.sh --backup

  Restore:
    sudo ./install.sh --restore /var/backups/revpi-gateway/20260305-123456


  Manage port forwarding:
    nano /etc/nftables.d/portforwards_*.nft


Tools:
======
  Offline Bundle creation Standard (with packages):
    ./build-offline-bundle.sh 0.1.0
    ls -l dist/

  Offline Bundle creation without packages (only config & scripts):
    WITH_PACKAGES=0 ./build-offline-bundle.sh 0.1.0

  Own package list:
    PKG_LIST="nftables iproute2 tcpdump cockpit apache2" ./build-offline-bundle.sh 0.1.0


Troubleshooting:
================
  Reload:
    sudo nft -f /etc/nftables.conf

  Report:
    sudo revpi-firewall-report /root/firewall-report.md
