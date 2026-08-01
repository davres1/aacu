#!/usr/bin/env bash
# Flushes and rotates MySQL logs.
# Runs as: root (via sudo -u root run_fix.sh)
set -euo pipefail
source "$(dirname "$0")/_common.sh"

# --- Check: mysql client available before attempting a flush ---
require_cmd mysql

echo "[$(date +%T)] Flushing MySQL logs..."
if mysql -e "FLUSH LOGS; FLUSH ERROR LOGS; FLUSH SLOW LOGS;" 2>/dev/null || \
   mysql -u root -e "FLUSH LOGS;" 2>/dev/null; then
    FLUSHED=1
else
    FLUSHED=0
    echo "Warning: mysql flush failed — check credentials"
fi

# Force logrotate if a config exists
ROTATED=0
if have_cmd logrotate; then
    for cfg in /etc/logrotate.d/mysql /etc/logrotate.d/mysql-server; do
        [[ -f "$cfg" ]] && { echo "Rotating: $cfg"; logrotate -f "$cfg" 2>/dev/null && ROTATED=$((ROTATED+1)) || true; }
    done
fi

if [[ "$FLUSHED" -eq 1 ]]; then
    save_action "DONE" "MySQL logs flushed; logrotate configs processed: $ROTATED"
else
    save_action "FAIL" "MySQL FLUSH LOGS failed (check credentials); logrotate configs processed: $ROTATED"
fi
echo "[$(date +%T)] MySQL log flush complete."
