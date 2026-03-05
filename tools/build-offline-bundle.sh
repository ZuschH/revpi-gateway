#!/usr/bin/env bash
set -euo pipefail

# Build an offline bundle tar.gz including:
# - repository files
# - ./packages/*.deb (downloaded via apt)
# - metadata: commit hash, build host, date, os release
#
# Usage:
#   ./build-offline-bundle.sh 0.1.0
#
# Optional env:
#   OUTDIR=dist
#   WITH_PACKAGES=1   (default 1)
#   PKG_LIST="..."    (override package list)

VERSION="${1:-0.1.0}"
OUTDIR="${OUTDIR:-dist}"
WITH_PACKAGES="${WITH_PACKAGES:-1}"

if [[ ! -f "./install.sh" || ! -d "./files" ]]; then
  echo "ERROR: Bitte im Repo-Root (revpi-gateway/) ausführen." >&2
  exit 1
fi

mkdir -p "$OUTDIR"
rm -rf ./packages
mkdir -p ./packages

# --- determine repo revision ---
GIT_REV="nogit"
GIT_DIRTY="no"
if command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  GIT_REV="$(git rev-parse --short HEAD 2>/dev/null || echo nogit)"
  if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
    GIT_DIRTY="yes"
  fi
fi

BUILD_DATE="$(date -Is)"
BUILD_HOST="$(hostname)"
OS_PRETTY="$( (grep -E '^PRETTY_NAME=' /etc/os-release 2>/dev/null | cut -d= -f2- | tr -d '"') || echo unknown )"
ARCH="$(dpkg --print-architecture 2>/dev/null || uname -m)"

# write metadata into repo (will be included)
cat > ./BUNDLE_INFO.txt <<EOF
revpi-gateway offline bundle
===========================

Version:        $VERSION
Build-Date:     $BUILD_DATE
Build-Host:     $BUILD_HOST
OS:             $OS_PRETTY
Arch:           $ARCH
Git-Rev:        $GIT_REV
Git-Dirty:      $GIT_DIRTY

Install:
  sudo ./install.sh --offline

Dry-run:
  sudo ./install.sh --dry-run

Export config:
  sudo ./install.sh --export /mnt/usb/revpi-gateway-export.tar.gz
EOF

# package list (can be overridden)
DEFAULT_PKGS=(
  nftables iproute2 iputils-ping tcpdump curl ca-certificates openssh-server
  cockpit cockpit-bridge cockpit-system
  apache2
)
if [[ -n "${PKG_LIST:-}" ]]; then
  # shellcheck disable=SC2206
  PKGS=($PKG_LIST)
else
  PKGS=("${DEFAULT_PKGS[@]}")
fi

if [[ "$WITH_PACKAGES" == "1" ]]; then
  echo "== Download Debian Pakete (inkl. Dependencies) =="
  if ! command -v apt-get >/dev/null 2>&1; then
    echo "ERROR: apt-get nicht gefunden. Bitte auf Debian/Ubuntu Build-System ausführen." >&2
    exit 1
  fi

  sudo apt-get update

  # Ensure we download the packages without installing/upgrading too much on the builder:
  # 1) download-only install (pulls dependencies into /var/cache/apt/archives)
  sudo apt-get -y install --download-only --no-install-recommends "${PKGS[@]}"

  # Copy downloaded .deb files into ./packages
  cp -a /var/cache/apt/archives/*.deb ./packages/ || true

  # cleanup broken/empty
  find ./packages -type f -name '*.deb' -size -1k -delete || true

  # Write packages manifest
  (cd ./packages && ls -1 *.deb 2>/dev/null | sort) > ./packages/PACKAGES_MANIFEST.txt || true

  cat > ./packages/README.txt <<EOF
Dieses Verzeichnis enthält .deb Pakete für Offline-Installationen.
Installiert werden sie via:
  sudo ./install.sh --offline

Hinweis:
- Falls dpkg fehlende Dependencies meldet, behebt install.sh das via:
  apt-get --no-download -f install
EOF
else
  echo "== WITH_PACKAGES=0 -> packages/ bleibt leer =="
  cat > ./packages/README.txt <<EOF
Dieses Bundle wurde ohne Debian-Pakete gebaut (WITH_PACKAGES=0).
Offline-Installation ist damit nicht möglich.
EOF
fi

# Create bundle
OUTFILE="$OUTDIR/revpi-gateway-offline-${VERSION}-${ARCH}.tar.gz"

echo "== Bundle erstellen: $OUTFILE =="
tar czf "$OUTFILE" \
  --exclude-vcs \
  --exclude="$OUTDIR" \
  .

echo "== Fertig =="
echo "Bundle: $OUTFILE"
echo "Info:   ./BUNDLE_INFO.txt (im Bundle enthalten)"
echo
echo "Auf dem RevPi:"
echo "  tar xzf $(basename "$OUTFILE")"
echo "  cd revpi-gateway"
echo "  sudo ./install.sh --offline"


