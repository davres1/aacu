#!/usr/bin/env bash
# Starts the DB2 instance.
# Runs as: db2inst1 (via sudo -u db2inst1 run_fix.sh)
# Env: DB2_INSTANCE (defaults to db2inst1)
set -euo pipefail

DB2_INSTANCE="${DB2_INSTANCE:-db2inst1}"
PROFILE="/home/${DB2_INSTANCE}/sqllib/db2profile"

[[ -f "$PROFILE" ]] && source "$PROFILE" 2>/dev/null || {
    echo "ERROR: DB2 profile not found at $PROFILE" >&2; exit 1
}

echo "[$(date +%T)] Starting DB2 instance $DB2_INSTANCE..."

db2start 2>&1

# Verify instance is running
db2 list active databases 2>/dev/null && \
    echo "[$(date +%T)] DB2 instance $DB2_INSTANCE is UP." || \
    echo "[$(date +%T)] DB2 instance started but no active databases yet."
