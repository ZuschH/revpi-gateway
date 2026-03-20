This directory contains .deb packages for offline installations.
They can be installed using:
  sudo ./install.sh --offline

Note:
- If dpkg reports missing dependencies, install.sh resolves this using:
  apt-get --no-download -f install

