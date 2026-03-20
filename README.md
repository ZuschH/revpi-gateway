?? RevPi Gateway (nftables-based NAT & Service Gateway)
================================================

A ready-to-deploy gateway solution for Revolution Pi (Debian Bookworm) systems.

This project provides:
?? NAT / Port Forwarding (multi-service)
?? nftables-based firewall (no iptables)
?? WAN ? LAN routing
?? FTP proxy (via vsftpd)
?? Secure default firewall policy
?? Easy installation via interactive script
?? Export / backup capability
?? Designed for industrial environments



?? Architecture Overview
========================

        Customer Network (WAN)
              |
         [ eth1 / WAN ]
              |
        +--------------+
        ¦   RevPi      ¦
        ¦  Gateway     ¦
        ¦              ¦
        ¦ nftables NAT ¦
        ¦ vsftpd proxy ¦
        +--------------+
               |
         [ eth0 / LAN ]
               |
     +-------------------+
     ¦ Internal Devices   ¦
     ¦                   ¦
     ¦ 192.168.19.3      ¦ (Hakko HMI / FTP / VNC)
     ¦ 192.168.19.1      ¦ (Fuji Controller)
     ¦ RevPi itself      ¦ (HTTP, OPC UA, OpenVPN)
     +-------------------+


?? Features
===========

NAT / Port Forwarding

Supports multiple services:

Service	Target IP	Ports
FTP (via vsftpd)	RevPi (local)	21 + passive range
VNC	192.168.19.3	5800, 5900
Fuji Programmer	192.168.19.1	507, 509
Hakko V-SFT	192.168.19.3	8000,8001,10000,10001
HTTP / HTTPS	RevPi	80, 443
Cockpit / Apache	RevPi	41443
OPC UA	RevPi	4840
OpenVPN	RevPi	1194 (UDP)



Firewall Concept:
=================

Default policy: DROP
-  Only required ports are opened
-  Full state tracking (ct state established,related)
-  Logging of dropped packets (rate-limited)
-  FTP Handling (Important!)
-  Industrial FTP devices (e.g. Hakko HMI) often:
-  use dynamic passive ports
-  return internal IP addresses



?? Solution:
=============

vsftpd runs on RevPi
acts as FTP gateway/proxy
ensures compatibility with all clients (WinSCP, etc.)




?? Repository Structure:
========================

revpi-gateway/
¦
+-- install.sh                 # Main installer (interactive)
+-- README.md                  # This file
+-- LICENSE
¦
+-- etc/
¦   +-- nftables.conf          # Main firewall config
¦   +-- nftables.d/
¦   ¦   +-- portforwards_tcp.nft
¦   ¦   +-- portforwards_udp.nft
¦   ¦
¦   +-- vsftpd.conf
¦   +-- sysctl.d/
¦   ¦   +-- 99-revpi-gateway.conf
¦   ¦
¦   +-- revpi-gateway/
¦       +-- revpi-gateway.conf
¦
+-- scripts/
    +-- revpi-firewall-report



?? Installation:
=================

  Option A: Online Installation
  -----------------------------
    git clone https://github.com/ZuschH/revpi-gateway/
    cd revpi-gateway
    chmod +x install.sh
    sudo ./install.sh

  Option B: Offline Installation
  ------------------------------
    1) Copy repository to target system
    2) Run:
      sudo ./install.sh

    Installer will:
    install required packages (if available)
    configure firewall
    configure vsftpd
    enable services



?? Installer Features:
=======================

  Interactive Mode
  ----------------
    The installer will ask:
      1) Update / Repair
      2) Fresh installation
      3) Abort

    Modes:
    Mode	Description
    Install	Full setup (overwrites config)
    Update	Keeps port forwarding config
    Repair	Re-applies configs and services

  Dry-Run Mode
  ------------
    Preview changes without applying:

    ./install.sh --dry-run

  Export Configuration
  --------------------
    Creates full backup:

    ./install.sh --export

    Output:
    /tmp/revpi-gateway-export-<timestamp>.tar.gz

    Includes:
    nftables config
    vsftpd config
    system settings
    version info



?? Configuration
================

  Main Config
    /etc/revpi-gateway/revpi-gateway.conf

  Defines:
    - WAN / LAN interfaces
    - IP addresses
    - service mappings

  Firewall Config
    /etc/nftables.conf
    /etc/nftables.d/

  Structure:
    - inet filter ? firewall rules
    - ip nat ? DNAT / SNAT
    - modular port forward includes

  Version File
    /etc/revpi-gateway.version

  Example:
    NAME="revpi-gateway"
    VERSION="0.1.1"
    BUILD_DATE="2026-03-20"
    AUTHOR="https://github.com/ZuschH"


?? Important: firewalld
=======================

  ?? firewalld must be disabled

  The installer automatically runs:
    systemctl disable --now firewalld

  Reason:
  firewalld conflicts with nftables
  blocks forwarded ports (e.g. FTP)


?? Diagnostics:
================

  Check firewall
    nft list ruleset

  Check listening ports
    ss -lntup

  Monitor traffic
    tcpdump -ni eth1 'tcp port 21 or (tcp portrange 50000-50100)'

  Generate report
    revpi-firewall-report


?? Reapply Configuration:
=========================

  sudo nft -f /etc/nftables.conf


?? Troubleshooting:
===================

  FTP not working
    Check:
      - vsftpd running?
         systemctl status vsftpd

      - passive ports open?
         nft list ruleset | grep 50000

      - firewalld disabled?

  No connection after reboot
    Likely cause:
      firewalld re-enabled
  Fix:
    systemctl disable --now firewalld

  NAT not working

    Check:
      sysctl net.ipv4.ip_forward
    Must be:
      1



?? Security Notes:
==================

  - System assumes external hardware firewall
  - Internal network is trusted
  - Only required ports exposed



?? Extending the System:
=========================
  To add new services:
    Edit:
      /etc/nftables.d/portforwards_tcp.nft
      Add new DNAT rule

    Reload:
      nft -f /etc/nftables.conf


?? Deployment Strategy:
=======================

  Recommended workflow:
    Prepare golden system
      Run:
        ./install.sh --export

      Deploy archive to other devices

      Run installer



????? Target Use Cases:
=====================

  - Industrial HMIs (Hakko / Fuji)
  - PLC programming access
  - Remote maintenance gateways
  - Secure field network routing



?? License:
===========

  GNU GENERAL PUBLIC LICENSE
  Version 3, 29 June 2007

  see 'LICENSE' file in root folder



?? Support:
===========

  For internal use:
    - Provide export archive
    - Include revpi-firewall-report



? Status:
==========
  ? Stable
  ? Production-ready
  ? Tested on Debian Bookworm / RevPi
