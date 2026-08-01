#!/usr/bin/env bash
# Deletes Oracle archive logs older than 2 days via RMAN.
# Runs as: oracle (via sudo -u oracle run_fix.sh)
# Env: ORACLE_HOME, ORACLE_SID
set -euo pipefail
source "$(dirname "$0")/_common.sh"

export ORACLE_HOME="${ORACLE_HOME:?ORACLE_HOME is required}"
export ORACLE_SID="${ORACLE_SID:?ORACLE_SID is required}"
export PATH="$ORACLE_HOME/bin:$PATH"
export NLS_DATE_FORMAT="YYYY-MM-DD HH24:MI:SS"

# --- Check: RMAN present, and there is actually something to delete ---
require_cmd rman

DELETABLE="?"
if have_cmd sqlplus; then
    DELETABLE=$(sqlplus -s / as sysdba <<'SQL' 2>/dev/null | tr -dc '0-9'
SET HEADING OFF FEEDBACK OFF PAGESIZE 0 VERIFY OFF ECHO OFF
SELECT COUNT(*) FROM V$ARCHIVED_LOG
 WHERE DELETED = 'NO' AND COMPLETION_TIME < SYSDATE - 2;
EXIT;
SQL
) || DELETABLE="?"
    DELETABLE="${DELETABLE:-?}"
    if [[ "$DELETABLE" =~ ^[0-9]+$ && "$DELETABLE" -eq 0 ]]; then
        save_action "SKIP" "no archive logs older than 2 days to delete for $ORACLE_SID"
        exit 0
    fi
fi

echo "[$(date +%T)] Clearing archive logs older than 2 days for $ORACLE_SID (candidates: $DELETABLE)..."

rman target / <<'RMAN'
DELETE NOPROMPT ARCHIVELOG ALL COMPLETED BEFORE 'SYSDATE-2';
EXIT;
RMAN

save_action "DONE" "deleted archive logs older than 2 days for $ORACLE_SID (candidates: $DELETABLE)"
echo "[$(date +%T)] Archive log clear complete."
