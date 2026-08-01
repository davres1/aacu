#!/usr/bin/env bash
# Cycles the MSSQL error log on Linux (sp_cycle_errorlog).
# Runs as: root (via sudo -u root run_fix.sh)
set -euo pipefail
source "$(dirname "$0")/_common.sh"

echo "[$(date +%T)] Cycling MSSQL error log..."

# --- Check: locate sqlcmd; skip cleanly (not an error) if the tools are absent ---
SQLCMD=""
for p in /opt/mssql-tools18/bin/sqlcmd /opt/mssql-tools/bin/sqlcmd; do
    [[ -x "$p" ]] && { SQLCMD="$p"; break; }
done

if [[ -z "$SQLCMD" ]]; then
    save_action "SKIP" "sqlcmd not found (mssql-tools not installed) — cannot cycle error log"
    echo "sqlcmd not found. Ensure mssql-tools is installed." >&2
    exit 0
fi

if "$SQLCMD" -S localhost -E -No \
    -Q "EXEC sp_cycle_errorlog; EXEC msdb.dbo.sp_cycle_agent_errorlog;" 2>/dev/null || \
   "$SQLCMD" -S localhost -E \
    -Q "EXEC sp_cycle_errorlog;" 2>/dev/null; then
    ls -lh /var/opt/mssql/log/errorlog* 2>/dev/null | head -5 || true
    save_action "DONE" "cycled MSSQL error log (sp_cycle_errorlog)"
else
    save_action "FAIL" "sp_cycle_errorlog failed — check SQL Server connectivity/permissions"
fi
echo "[$(date +%T)] MSSQL error log cycle complete."
