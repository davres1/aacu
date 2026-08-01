#!/usr/bin/env bash
# Starts an Oracle database instance (NOMOUNT → MOUNT → OPEN).
# Runs as: oracle (via sudo -u oracle run_fix.sh)
# Env: ORACLE_HOME, ORACLE_SID
set -euo pipefail
source "$(dirname "$0")/_common.sh"

export ORACLE_HOME="${ORACLE_HOME:?ORACLE_HOME is required}"
export ORACLE_SID="${ORACLE_SID:?ORACLE_SID is required}"
export PATH="$ORACLE_HOME/bin:$PATH"
export ORACLE_BASE="${ORACLE_BASE:-/u01/app/oracle}"

echo "[$(date +%T)] Starting Oracle instance $ORACLE_SID..."

# --- Check: verify sqlplus is accessible ---
require_cmd sqlplus

OUT=$(sqlplus -s / as sysdba <<'SQL' 2>&1
WHENEVER SQLERROR EXIT 1
SET ECHO OFF FEEDBACK OFF PAGESIZE 0

-- Check current status
DECLARE
  v_status VARCHAR2(20);
BEGIN
  SELECT STATUS INTO v_status FROM V$INSTANCE;
  DBMS_OUTPUT.PUT_LINE('Current status: ' || v_status);
EXCEPTION
  WHEN OTHERS THEN
    DBMS_OUTPUT.PUT_LINE('Instance not started');
END;
/

-- Attempt startup
STARTUP;

-- Verify
SELECT 'Instance status: ' || STATUS FROM V$INSTANCE;
EXIT;
SQL
) || true
echo "$OUT"

# --- Verify + save: confirm the instance reached OPEN ---
if printf '%s\n' "$OUT" | grep -q "Instance status: OPEN"; then
    save_action "DONE" "Oracle instance $ORACLE_SID started and OPEN"
else
    save_action "FAIL" "Oracle instance $ORACLE_SID startup did not reach OPEN"
fi
echo "[$(date +%T)] Oracle startup command completed."
