#!/usr/bin/env bash
# Kills Oracle sessions blocking others for more than 30 minutes.
# Runs as: oracle (via sudo -u oracle run_fix.sh)
# Env: ORACLE_HOME, ORACLE_SID
set -euo pipefail
source "$(dirname "$0")/_common.sh"

export ORACLE_HOME="${ORACLE_HOME:?ORACLE_HOME is required}"
export ORACLE_SID="${ORACLE_SID:?ORACLE_SID is required}"
export PATH="$ORACLE_HOME/bin:$PATH"

# --- Check: sqlplus available before attempting to kill sessions ---
require_cmd sqlplus

echo "[$(date +%T)] Killing blocking sessions (>30 min) on $ORACLE_SID..."

OUT=$(sqlplus -s / as sysdba <<'SQL' 2>&1
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
) || true
echo "$OUT"

# --- Save: record how many blocking sessions were terminated ---
KILLED=$(printf '%s\n' "$OUT" | sed -n 's/.*Sessions killed: *\([0-9][0-9]*\).*/\1/p' | tail -1)
KILLED="${KILLED:-0}"
if [[ "$KILLED" -eq 0 ]]; then
    save_action "SKIP" "no Oracle sessions blocking >30 min on $ORACLE_SID"
else
    save_action "DONE" "killed $KILLED Oracle blocking session(s) on $ORACLE_SID"
fi
echo "[$(date +%T)] Kill blocking complete."
