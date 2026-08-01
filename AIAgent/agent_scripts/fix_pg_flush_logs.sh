#!/usr/bin/env bash
# Rotates PostgreSQL log file and removes logs older than 7 days.
# Runs as: postgres (via sudo -u postgres run_fix.sh)
set -euo pipefail
source "$(dirname "$0")/_common.sh"

# --- Check: psql available before attempting server-side rotation ---
require_cmd psql

echo "[$(date +%T)] Rotating PostgreSQL logs..."

# Trigger server-side log rotation
if psql -U postgres -c "SELECT pg_rotate_logfile();" postgres 2>/dev/null || \
   psql -c "SELECT pg_rotate_logfile();" postgres 2>/dev/null; then
    ROTATED=1
else
    ROTATED=0
    echo "Warning: pg_rotate_logfile() failed — check pg_log directory permissions"
fi

# Remove logs older than 7 days from common log locations
REMOVED=0
for LOGDIR in /var/log/postgresql /var/lib/postgresql/*/main/pg_log; do
    [[ -d "$LOGDIR" ]] || continue
    echo "Cleaning old logs in: $LOGDIR"
    N=$( { find "$LOGDIR" \( -name "*.log" -o -name "*.csv" \) -mtime +7 2>/dev/null || true; } | wc -l | tr -d ' ')
    N="${N//[!0-9]/}"; N="${N:-0}"
    REMOVED=$((REMOVED + N))
    find "$LOGDIR" -name "*.log" -mtime +7 -delete 2>/dev/null || true
    find "$LOGDIR" -name "*.csv" -mtime +7 -delete 2>/dev/null || true
done

# Force logrotate if a config exists
if have_cmd logrotate; then
    for CFG in /etc/logrotate.d/postgresql /etc/logrotate.d/postgresql-common; do
        [[ -f "$CFG" ]] && { echo "Running logrotate: $CFG"; logrotate -f "$CFG" 2>/dev/null || true; }
    done
fi

if [[ "$ROTATED" -eq 1 ]]; then
    save_action "DONE" "rotated PostgreSQL log; removed $REMOVED log file(s) older than 7 days"
else
    save_action "FAIL" "pg_rotate_logfile() failed; removed $REMOVED old log file(s)"
fi
echo "[$(date +%T)] PostgreSQL log rotation complete."
