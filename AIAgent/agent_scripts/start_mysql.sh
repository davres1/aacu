#!/usr/bin/env bash
# Starts MySQL/MariaDB via systemctl.
# Runs as: root (via sudo -u root run_fix.sh)
set -euo pipefail

echo "[$(date +%T)] Starting MySQL..."

# Try different service names (MySQL, MariaDB, etc.)
STARTED=false
for SVC in mysql mysqld mariadb; do
    if systemctl list-unit-files "${SVC}.service" &>/dev/null 2>&1; then
        echo "Starting service: $SVC"
        systemctl start "$SVC" && STARTED=true && break
    fi
done

if [[ "$STARTED" == "false" ]]; then
    echo "ERROR: Could not find a MySQL/MariaDB service unit to start." >&2
    systemctl list-unit-files | grep -iE 'mysql|mariadb' || true
    exit 1
fi

# Wait up to 30s for mysqladmin to respond
TIMEOUT=30
while [[ $TIMEOUT -gt 0 ]]; do
    mysqladmin ping --connect-timeout=2 2>/dev/null && break
    sleep 2
    TIMEOUT=$((TIMEOUT-2))
done

if mysqladmin ping --connect-timeout=3 2>/dev/null; then
    echo "[$(date +%T)] MySQL is UP and accepting connections."
else
    echo "[$(date +%T)] WARNING: MySQL started but not yet responding to ping."
fi
