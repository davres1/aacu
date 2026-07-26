#!/usr/bin/env bash
# Flushes and rotates MySQL logs.
# Runs as: root (via sudo -u root run_fix.sh)
set -euo pipefail

echo "[$(date +%T)] Flushing MySQL logs..."
mysql -e "FLUSH LOGS; FLUSH ERROR LOGS; FLUSH SLOW LOGS;" 2>/dev/null || \
mysql -u root -e "FLUSH LOGS;" 2>/dev/null || \
echo "Warning: mysql flush failed — check credentials"

# Force logrotate if a config exists
for cfg in /etc/logrotate.d/mysql /etc/logrotate.d/mysql-server; do
    [[ -f "$cfg" ]] && { echo "Rotating: $cfg"; logrotate -f "$cfg" 2>/dev/null || true; }
done

echo "[$(date +%T)] MySQL log flush complete."
