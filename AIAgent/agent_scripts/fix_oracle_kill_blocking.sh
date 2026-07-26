#!/usr/bin/env bash
# Kills Oracle sessions blocking others for more than 30 minutes.
# Runs as: oracle (via sudo -u oracle run_fix.sh)
# Env: ORACLE_HOME, ORACLE_SID
set -euo pipefail

export ORACLE_HOME="${ORACLE_HOME:?ORACLE_HOME is required}"
export ORACLE_SID="${ORACLE_SID:?ORACLE_SID is required}"
export PATH="$ORACLE_HOME/bin:$PATH"

echo "[$(date +%T)] Killing blocking sessions (>30 min) on $ORACLE_SID..."

sqlplus -s / as sysdba <<'SQL'
SET SERVEROUTPUT ON SIZE 100000
DECLARE
  v_n NUMBER := 0;
BEGIN
  FOR r IN (
    SELECT DISTINCT b.SID, b.SERIAL#, b.USERNAME, ROUND(b.LAST_CALL_ET/60,1) AS min
    FROM   V$LOCK    l
    JOIN   V$SESSION b ON b.SID = l.SID
    WHERE  l.BLOCK   > 0
    AND    b.LAST_CALL_ET > 1800
    ORDER  BY b.LAST_CALL_ET DESC
  ) LOOP
    BEGIN
      EXECUTE IMMEDIATE 'ALTER SYSTEM KILL SESSION ''' || r.SID || ',' || r.SERIAL# || ''' IMMEDIATE';
      DBMS_OUTPUT.PUT_LINE('Killed sid='||r.SID||' user='||NVL(r.USERNAME,'?')||' blocking '||r.min||' min');
      v_n := v_n + 1;
    EXCEPTION
      WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('Cannot kill sid='||r.SID||': '||SQLERRM);
    END;
  END LOOP;
  DBMS_OUTPUT.PUT_LINE('Sessions killed: '||v_n);
END;
/
EXIT;
SQL

echo "[$(date +%T)] Kill blocking complete."
