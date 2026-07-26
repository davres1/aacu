#!/usr/bin/env bash
# Deletes Oracle archive logs older than 2 days via RMAN.
# Runs as: oracle (via sudo -u oracle run_fix.sh)
# Env: ORACLE_HOME, ORACLE_SID
set -euo pipefail

export ORACLE_HOME="${ORACLE_HOME:?ORACLE_HOME is required}"
export ORACLE_SID="${ORACLE_SID:?ORACLE_SID is required}"
export PATH="$ORACLE_HOME/bin:$PATH"
export NLS_DATE_FORMAT="YYYY-MM-DD HH24:MI:SS"

echo "[$(date +%T)] Clearing archive logs older than 2 days for $ORACLE_SID..."

rman target / <<'RMAN'
DELETE NOPROMPT ARCHIVELOG ALL COMPLETED BEFORE 'SYSDATE-2';
EXIT;
RMAN

echo "[$(date +%T)] Archive log clear complete."
