#!/usr/bin/env bash
# Starts an Oracle database instance (NOMOUNT → MOUNT → OPEN).
# Runs as: oracle (via sudo -u oracle run_fix.sh)
# Env: ORACLE_HOME, ORACLE_SID
set -euo pipefail

export ORACLE_HOME="${ORACLE_HOME:?ORACLE_HOME is required}"
export ORACLE_SID="${ORACLE_SID:?ORACLE_SID is required}"
export PATH="$ORACLE_HOME/bin:$PATH"
export ORACLE_BASE="${ORACLE_BASE:-/u01/app/oracle}"

echo "[$(date +%T)] Starting Oracle instance $ORACLE_SID..."

# Verify sqlplus is accessible
command -v sqlplus >/dev/null || { echo "ERROR: sqlplus not found in $ORACLE_HOME/bin"; exit 1; }

sqlplus -s / as sysdba <<'SQL'
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

echo "[$(date +%T)] Oracle startup command completed."
