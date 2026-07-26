#!/usr/bin/env bash
# Cycles the MSSQL error log on Linux (sp_cycle_errorlog).
# Runs as: root (via sudo -u root run_fix.sh)
set -euo pipefail

echo "[$(date +%T)] Cycling MSSQL error log..."

SQLCMD=""
for p in /opt/mssql-tools18/bin/sqlcmd /opt/mssql-tools/bin/sqlcmd; do
    [[ -x "$p" ]] && { SQLCMD="$p"; break; }
done

if [[ -z "$SQLCMD" ]]; then
    echo "Error: sqlcmd not found. Ensure mssql-tools is installed." >&2
    exit 1
fi

"$SQLCMD" -S localhost -E -No \
    -Q "EXEC sp_cycle_errorlog; EXEC msdb.dbo.sp_cycle_agent_errorlog;" 2>/dev/null || \
"$SQLCMD" -S localhost -E \
    -Q "EXEC sp_cycle_errorlog;" 2>/dev/null

ls -lh /var/opt/mssql/log/errorlog* 2>/dev/null | head -5 || true
echo "[$(date +%T)] MSSQL error log cycle complete."
