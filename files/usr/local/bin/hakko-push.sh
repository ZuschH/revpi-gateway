tee /usr/local/bin/hakko-push.sh >/dev/null <<'EOF'
#!/bin/sh
set -eu
. /etc/hakko-ftp.env

IN_DIR="/srv/ftp"
LOG="/srv/ftp/hakko/log/push.log"

mkdir -p "$IN_DIR" "$(dirname "$LOG")"

# Nichts zu tun?
if [ -z "$(ls -A "$IN_DIR" 2>/dev/null || true)" ]; then
  exit 0
fi

lftp -u "$HAKKO_USER","$HAKKO_PASS" "ftp://$HAKKO_HOST" <<LFTP >>"$LOG" 2>&1
set net:timeout 10
set net:max-retries 2
set ftp:passive-mode true
set xfer:clobber true
cd "$HAKKO_REMOTE_DIR"
mirror --reverse --verbose --only-newer --parallel=1 --use-cache --no-perms --no-umask "$IN_DIR" .
quit
LFTP

# Optional: nach erfolgreichem Push Upload-Ordner leeren/archivieren
# rm -f "$IN_DIR"/*
EOF

chmod +x /usr/local/bin/hakko-push.sh
