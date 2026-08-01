#!/usr/bin/env bash
# Starts Microsoft SQL Server on Linux via systemctl.
# Runs as: root (via sudo -u root run_fix.sh)
set -euo pipefail
source "$(dirname "$0")/_common.sh"

echo "[$(date +%T)] Starting MSSQL Server..."

# --- Check: systemctl available ---
require_cmd systemctl

if ! systemctl start mssql-server; then
    echo "ERROR: Failed to start mssql-server service." >&2
    journalctl -u mssql-server -n 20 --no-pager 2>/dev/null || true
    save_action "FAIL" "systemctl start mssql-server failed"
    exit 1
fi

# Wait up to 60s for sqlcmd to respond
SQLCMD=""
for p in /opt/mssql-tools18/bin/sqlcmd /opt/mssql-tools/bin/sqlcmd; do
    [[ -x "$p" ]] && { SQLCMD="$p"; break; }
done

ALIVE=false
if [[ -n "$SQLCMD" ]]; then
    TIMEOUT=60
    while [[ $TIMEOUT -gt 0 ]]; do
        if "$SQLCMD" -S localhost -E -No -Q "SELECT 1" -l 3 2>/dev/null; then
            ALIVE=true; break
        fi
        sleep 3; TIMEOUT=$((TIMEOUT-3))
    done
    "$SQLCMD" -S localhost -E -No -Q "SELECT @@VERSION" -l 5 2>/dev/null | head -3 || true
fi

# --- Save: record whether SQL Server is answering queries ---
if [[ "$ALIVE" == "true" ]]; then
    save_action "DONE" "MSSQL service started and answering queries"
elif [[ -z "$SQLCMD" ]]; then
    save_action "DONE" "MSSQL service start issued (sqlcmd absent — liveness not verified)"
else
    save_action "FAIL" "MSSQL service started but not answering queries within timeout"
fi
echo "[$(date +%T)] MSSQL start complete."
