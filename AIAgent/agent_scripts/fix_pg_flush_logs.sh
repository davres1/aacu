#!/usr/bin/env bash
# Rotates PostgreSQL log file and removes logs older than 7 days.
# Runs as: postgres (via sudo -u postgres run_fix.sh)
set -euo pipefail

echo "[$(date +%T)] Rotating PostgreSQL logs..."

# Trigger server-side log rotation
psql -U postgres -c "SELECT pg_rotate_logfile();" postgres 2>/dev/null || \
psql -c "SELECT pg_rotate_logfile();" postgres 2>/dev/null || \
echo "Warning: pg_rotate_logfile() failed — check pg_log directory permissions"

# Remove logs older than 7 days from common log locations
for LOGDIR in /var/log/postgresql /var/lib/postgresql/*/main/pg_log; do
    [[ -d "$LOGDIR" ]] || continue
    echo "Cleaning old logs in: $LOGDIR"
    find "$LOGDIR" -name "*.log" -mtime +7 -delete 2>/dev/null || true
    find "$LOGDIR" -name "*.csv" -mtime +7 -delete 2>/dev/null || true
done

# Force logrotate if a config exists
for CFG in /etc/logrotate.d/postgresql /etc/logrotate.d/postgresql-common; do
    [[ -f "$CFG" ]] && { echo "Running logrotate: $CFG"; logrotate -f "$CFG" 2>/dev/null || true; }
done

echo "[$(date +%T)] PostgreSQL log rotation complete."
