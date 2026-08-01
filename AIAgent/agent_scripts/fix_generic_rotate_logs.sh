#!/usr/bin/env bash
# Forces log rotation via logrotate for any configured DB log files.
# Runs as: root (via sudo -u root run_fix.sh)
set -euo pipefail
source "$(dirname "$0")/_common.sh"

echo "[$(date +%T)] Running generic log rotation..."

ROTATED=0
# --- Check: only rotate when logrotate is present ---
if have_cmd logrotate; then
    for cfg in /etc/logrotate.d/mysql /etc/logrotate.d/mysql-server \
               /etc/logrotate.d/mssql  /etc/logrotate.d/db2 \
               /etc/logrotate.d/oracle /etc/logrotate.d/postgresql; do
        if [[ -f "$cfg" ]]; then
            echo "Rotating config: $cfg"
            logrotate -f "$cfg" 2>/dev/null && ROTATED=$((ROTATED+1)) || true
        fi
    done
else
    echo "logrotate not installed — skipping config-based rotation."
fi

# Compress uncompressed old log backups > 50MB
COMPRESSED=$( { find /var/log -name "*.log.1" ! -name "*.gz" -size +50M 2>/dev/null || true; } | wc -l | tr -d ' ')
COMPRESSED="${COMPRESSED//[!0-9]/}"; COMPRESSED="${COMPRESSED:-0}"
find /var/log -name "*.log.1" ! -name "*.gz" -size +50M 2>/dev/null \
    | xargs -r gzip -f 2>/dev/null || true

# Show files > 500MB for awareness
LARGE=$( { find /var/log /u01/app/oracle/diag -name "*.log" -size +500M 2>/dev/null || true; } \
    | xargs -r du -sh 2>/dev/null | head -10)
[[ -n "$LARGE" ]] && echo "Large log files remaining:$LARGE"

if [[ "$ROTATED" -eq 0 && "${COMPRESSED:-0}" -eq 0 ]]; then
    save_action "SKIP" "no logrotate configs rotated and no oversized backups to compress"
else
    save_action "DONE" "rotated $ROTATED logrotate config(s), compressed ${COMPRESSED:-0} oversized backup(s)"
fi
echo "[$(date +%T)] Log rotation complete. Configs processed: $ROTATED"
