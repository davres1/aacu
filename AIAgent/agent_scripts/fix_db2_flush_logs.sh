#!/usr/bin/env bash
# Flushes DB2 diagnostic logs by archiving and truncating oversized db2diag.log.
# Runs as: db2inst1 (via sudo -u db2inst1 run_fix.sh)
# Env: DB2_INSTANCE (defaults to db2inst1)
set -euo pipefail

DB2_INSTANCE="${DB2_INSTANCE:-db2inst1}"
PROFILE="/home/${DB2_INSTANCE}/sqllib/db2profile"

[[ -f "$PROFILE" ]] && source "$PROFILE" 2>/dev/null || true

echo "[$(date +%T)] Flushing DB2 diagnostic logs for instance $DB2_INSTANCE..."

DIAG_PATH=$(db2 get dbm cfg 2>/dev/null | grep -i "Diagnostic data directory" | awk '{print $NF}' || echo "")
LOG_FILE="${DIAG_PATH}/DIAG0000/db2diag.log"

if [[ -z "$DIAG_PATH" || ! -f "$LOG_FILE" ]]; then
    echo "Could not locate db2diag.log — trying default path"
    LOG_FILE="/home/${DB2_INSTANCE}/sqllib/db2dump/DIAG0000/db2diag.log"
fi

if [[ -f "$LOG_FILE" ]]; then
    SIZE_MB=$(du -sm "$LOG_FILE" | cut -f1)
    echo "Current log size: ${SIZE_MB}MB"
    if [[ "$SIZE_MB" -gt 100 ]]; then
        BACKUP="${LOG_FILE}.$(date +%Y%m%d%H%M%S)"
        tail -n 100000 "$LOG_FILE" > "${LOG_FILE}.new"
        cp "$LOG_FILE" "$BACKUP"
        mv "${LOG_FILE}.new" "$LOG_FILE"
        gzip -f "$BACKUP" &
        echo "Archived ${SIZE_MB}MB, kept last 100K lines. Background gzip of backup started."
    else
        echo "Log is ${SIZE_MB}MB — below 100MB threshold, no action."
    fi
else
    echo "db2diag.log not found at $LOG_FILE"
fi

echo "[$(date +%T)] DB2 log flush complete."
