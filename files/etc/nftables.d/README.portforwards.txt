System:     Revolution Pi
OS:         Debian Bookworm
Firewall:   nftables
Zweck:      Industrial Gateway / NAT Router

Der RevPi verbindet zwei Netzwerke:

  eth1  = Kundennetz / WAN
          Beispiel: 192.168.178.0/24

  eth0  = internes Anlagen-LAN
          Beispiel: 192.168.19.0/24

Der RevPi übernimmt folgende Funktionen:

  • Firewall
  • NAT Router
  • Port Forwarding (WAN → LAN)
  • Zugriff auf lokale Dienste (SSH, Cockpit, HTTP, OPC UA)
  • OpenVPN Server

