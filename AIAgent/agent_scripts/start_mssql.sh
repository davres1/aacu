#!/usr/bin/env bash
# Starts Microsoft SQL Server on Linux via systemctl.
# Runs as: root (via sudo -u root run_fix.sh)
set -euo pipefail

echo "[$(date +%T)] Starting MSSQL Server..."

systemctl start mssql-server || {
    echo "ERROR: Failed to start mssql-server service." >&2
    journalctl -u mssql-server -n 20 --no-pager 2>/dev/null || true
    exit 1
}

# Wait up to 60s for sqlcmd to respond
SQLCMD=""
for p in /opt/mssql-tools18/bin/sqlcmd /opt/mssql-tools/bin/sqlcmd; do
    [[ -x "$p" ]] && { SQLCMD="$p"; break; }
done

if [[ -n "$SQLCMD" ]]; then
    TIMEOUT=60
    while [[ $TIMEOUT -gt 0 ]]; do
        "$SQLCMD" -S localhost -E -No -Q "SELECT 1" -l 3 2>/dev/null && break
        sleep 3; TIMEOUT=$((TIMEOUT-3))
    done
    "$SQLCMD" -S localhost -E -No -Q "SELECT @@VERSION" -l 5 2>/dev/null | head -3 || true
fi

echo "[$(date +%T)] MSSQL start complete."
