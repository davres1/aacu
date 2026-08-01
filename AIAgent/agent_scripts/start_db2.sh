#!/usr/bin/env bash
# Starts the DB2 instance.
# Runs as: db2inst1 (via sudo -u db2inst1 run_fix.sh)
# Env: DB2_INSTANCE (defaults to db2inst1)
set -euo pipefail
source "$(dirname "$0")/_common.sh"

DB2_INSTANCE="${DB2_INSTANCE:-db2inst1}"
PROFILE="/home/${DB2_INSTANCE}/sqllib/db2profile"

# --- Check: the instance profile must exist to source the DB2 environment ---
if [[ ! -f "$PROFILE" ]]; then
    save_action "FAIL" "DB2 profile not found at $PROFILE — cannot start $DB2_INSTANCE"
    echo "ERROR: DB2 profile not found at $PROFILE" >&2
    exit 1
fi
source "$PROFILE" 2>/dev/null || true

echo "[$(date +%T)] Starting DB2 instance $DB2_INSTANCE..."

db2start 2>&1 || true

# --- Verify + save: check for active databases after start ---
if db2 list active databases 2>/dev/null; then
    echo "[$(date +%T)] DB2 instance $DB2_INSTANCE is UP."
    save_action "DONE" "DB2 instance $DB2_INSTANCE started with active databases"
else
    echo "[$(date +%T)] DB2 instance started but no active databases yet."
    save_action "INFO" "DB2 instance $DB2_INSTANCE start issued; no active databases reported yet"
fi
