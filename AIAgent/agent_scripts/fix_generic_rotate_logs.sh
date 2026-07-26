#!/usr/bin/env bash
# Forces log rotation via logrotate for any configured DB log files.
# Runs as: root (via sudo -u root run_fix.sh)
set -euo pipefail

echo "[$(date +%T)] Running generic log rotation..."

ROTATED=0
for cfg in /etc/logrotate.d/mysql /etc/logrotate.d/mysql-server \
           /etc/logrotate.d/mssql  /etc/logrotate.d/db2 \
           /etc/logrotate.d/oracle; do
    if [[ -f "$cfg" ]]; then
        echo "Rotating config: $cfg"
        logrotate -f "$cfg" 2>/dev/null && ROTATED=$((ROTATED+1)) || true
    fi
done

# Compress uncompressed old log backups > 50MB
find /var/log -name "*.log.1" ! -name "*.gz" -size +50M 2>/dev/null \
    | xargs -r gzip -f 2>/dev/null || true

# Show files > 500MB for awareness
LARGE=$(find /var/log /u01/app/oracle/diag 2>/dev/null -name "*.log" -size +500M \
    | xargs -r du -sh 2>/dev/null | head -10)
[[ -n "$LARGE" ]] && echo "Large log files remaining:$LARGE"

echo "[$(date +%T)] Log rotation complete. Configs processed: $ROTATED"
