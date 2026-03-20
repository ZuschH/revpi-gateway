📦 RevPi Gateway (nftables-based NAT & Service Gateway)
========================================================

A production-ready gateway solution for Revolution Pi (Debian Bookworm) systems.
This project provides a complete, reproducible setup for:

  🔁 NAT / Port Forwarding (multi-service)
  🔥 nftables firewall (no iptables)
  🌐 WAN ↔ LAN routing
  📡 FTP proxy (vsftpd with NAT support)
  ⚙️ Interactive + automated deployment
  📦 Export / backup of full configuration


📐 Architecture Overview
=========================
        Customer Network (WAN)
              |
         [ eth1 / WAN ]
              |
        ┌──────────────┐
        │   RevPi      │
        │  Gateway     │
        │              │
        │ nftables NAT │
        │ vsftpd proxy │
        └──────┬───────┘
               |
         [ eth0 / LAN ]
               |
     ┌─────────┴─────────┐
     │ Internal Devices  │
     │                   │
     │ 192.168.19.3      │ (Hakko HMI / FTP / VNC)
     │ 192.168.19.1      │ (Fuji Controller)
     │ RevPi itself      │ (HTTP, OPC UA, OpenVPN)
     └───────────────────┘


🚀 Features
============
  NAT / Port Forwarding

   Service             Target IP        Ports
  --------------------+----------------+-------------------------+
  | FTP (proxy)       | RevPi	       | 21 + passive range      |
  | VNC               | 192.168.19.3   | 5800, 5900              |
  | Fuji Programmer   | 192.168.19.1   | 507, 509                |
  | Hakko V-SFT	      | 192.168.19.3   | 8000,8001,10000,10001   |
  | HTTP / HTTPS      | RevPi          | 80, 443                 |
  | Cockpit / Apache  | RevPi          | 41443                   |
  | OPC UA	      | RevPi	       | 4840                    |
  | OpenVPN	      | RevPi	       | 1194 (UDP)              |
  +-------------------+----------------+-------------------------+

  Firewall Concept
  ----------------
    - Default policy: DROP
    - Explicit allow rules only
    - Connection tracking enabled
    - Logging of dropped packets (rate-limited)

  FTP Handling (Important!)
  -------------------------
    Industrial FTP servers (e.g. Hakko HMI):
      - use dynamic passive ports
      - return internal IP addresses

    ➡️ Solution:
      - vsftpd runs on RevPi
      - acts as FTP gateway
      - ensures client compatibility (WinSCP, etc.)

📁 Repository Structure
========================
revpi-gateway/
│
├── install.sh
├── README.md
│
├── etc/
│   ├── nftables.conf
│   ├── nftables.d/
│   │   ├── portforwards_tcp.nft
│   │   └── portforwards_udp.nft
│   │
│   ├── vsftpd.conf
│   ├── sysctl.d/
│   │   └── 99-revpi-gateway.conf
│   │
│   └── revpi-gateway/
│       └── revpi-gateway.conf
│
└── scripts/
    └── revpi-firewall-report


⚙️ Installation
================
  Interactive (default)
    sudo ./install.sh
    
  Non-Interactive (automated)
    sudo ./install.sh --auto

  With parameters
    sudo FTP_MODE=dhcp WAN_IF=eth1 LAN_IF=eth0 ./install.sh --auto

  Static FTP IP example
    sudo FTP_MODE=static FTP_PASV_IP=192.168.200.47 ./install.sh --auto
    
🔧 Installer Behavior
  Modes
  -----
     Mode	   Description
    +-------------+--------------------------+
    | Install	  | Full setup               |
    | Update	  | Keeps port forwarding    |
    | Repair 	  | Re-applies configuration |
    +-------------+--------------------------+
    
  FTP PASV Mode
  -------------
  Installer offers:
    1) Static WAN IP
    2) DHCP auto-detect (recommended)

🌐 DHCP-aware FTP (Important)
==============================
  If WAN uses DHCP:
    - IP may change at runtime
    - FTP passive mode requires correct IP
  ➡️ Solution:
    - WAN IP is auto-detected
    - pasv_address updated dynamically
    - systemd service updates on boot
    - DHCP hook updates on IP change


🔁 Auto-Update Mechanism
=========================
  Script
    /usr/local/sbin/update-vsftpd-pasv.sh

  systemd service
    vsftpd-pasv-update.service

  DHCP hook
    /etc/dhcp/dhclient-exit-hooks.d/vsftpd

    
🔥 Important: firewalld
========================
  firewalld conflicts with nftables.
  Installer automatically runs:
    systemctl disable --now firewalld


🧪 Diagnostics
===============
  Firewall rules
    nft list ruleset

  Check services
    systemctl status vsftpd
    systemctl status nftables

  Check listening ports
    ss -lntup

  Monitor FTP traffic
    tcpdump -ni eth1 'tcp port 21 or (tcp portrange 50000-50100)'

  Generate report
    revpi-firewall-report


🛠 Troubleshooting
===================
  FTP login fails (Access denied)
  -------------------------------
    Check:
      grep ftpuser /etc/passwd

    Shell must NOT be:
      /bin/false

    Fix:
      usermod -s /bin/bash ftpuser

  FTP LIST / timeout
  ------------------
    Cause:
      - wrong PASV IP

    Check:
      tcpdump -ni eth1 port 21

    Look for:
      227 Entering Passive Mode (...)
    
    Fix:
      - ensure correct pasv_address

  FTP works locally but not remotely
  ----------------------------------
    Cause:
      - NAT + wrong PASV IP
    
    Fix:
      - use DHCP auto mode or set static IP

  No connection after reboot
  --------------------------
    Cause:
      - firewalld active again

    Fix:
      systemctl disable --now firewalld

  NAT not working
  ---------------
    Check:
      sysctl net.ipv4.ip_forward

    Must be:
      1


🔐 Security Notes
==================
  - Designed for use behind external firewall
  - Only required ports exposed
  - Internal network assumed trusted


🧩 Extending Port Forwarding
=============================
  Edit:
    /etc/nftables.d/portforwards_tcp.nft

  Then reload:
    nft -f /etc/nftables.conf


📦 Export / Backup
===================
  ./install.sh --export

  Creates:
    /tmp/revpi-gateway-export-<timestamp>.tar.gz


🏭 Deployment Strategy
=======================
  Recommended workflow:
    1. Setup reference system
    2. Run:
        ./install.sh --export
    3. Deploy archive to target systems
    4. Run installer


👨‍🏭 Use Cases
=============
  - Industrial HMIs (Hakko, Fuji)
  - Remote maintenance gateways
  - PLC programming access
  - Secure network segmentation


📄 License
===========
  GNU GENERAL PUBLIC LICENSE
  Version 3, 29 June 2007
  see 'LICENSE' file in the root folder


✅ Status
==========
  ✔ Stable
  ✔ DHCP-compatible
  ✔ Automation-ready
  ✔ Tested on RevPi / Debian Bookworm


🤝 Support
===========
  For support provide:
    - export archive
    - firewall report
    - relevant logs


sh 20/03/2026
