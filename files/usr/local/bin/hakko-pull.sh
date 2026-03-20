tee /usr/local/bin/hakko-pull.sh >/dev/null <<'EOF'
#!/bin/sh
set -eu
. /etc/hakko-ftp.env

LOCAL_DIR="/srv/ftp"
LOG="/srv/ftp/hakko/log/pull.log"

mkdir -p "$LOCAL_DIR" "$(dirname "$LOG")"

lftp -u "$HAKKO_USER","$HAKKO_PASS" "ftp://$HAKKO_HOST" <<LFTP >>"$LOG" 2>&1
set net:timeout 10
set net:max-retries 2
set ftp:passive-mode true
set xfer:clobber true
cd "$HAKKO_REMOTE_DIR"
mirror --verbose --only-newer --parallel=1 --use-cache --no-perms --no-umask . "$LOCAL_DIR"
quit
LFTP
EOF

chmod +x /usr/local/bin/hakko-pull.sh