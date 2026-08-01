#!/usr/bin/env bash
# Shrinks all temporary tablespaces to reclaim free space.
# Runs as: oracle (via sudo -u oracle run_fix.sh)
# Env: ORACLE_HOME, ORACLE_SID
set -euo pipefail
source "$(dirname "$0")/_common.sh"

export ORACLE_HOME="${ORACLE_HOME:?ORACLE_HOME is required}"
export ORACLE_SID="${ORACLE_SID:?ORACLE_SID is required}"
export PATH="$ORACLE_HOME/bin:$PATH"

# --- Check: sqlplus available before attempting the shrink ---
require_cmd sqlplus

echo "[$(date +%T)] Shrinking temp tablespace for $ORACLE_SID..."

OUT=$(sqlplus -s / as sysdba <<'SQL' 2>&1
SET SERVEROUTPUT ON
DECLARE
  v_sql VARCHAR2(200);
BEGIN
  FOR r IN (SELECT TABLESPACE_NAME FROM DBA_TABLESPACES WHERE CONTENTS='TEMPORARY') LOOP
    v_sql := 'ALTER TABLESPACE ' || r.TABLESPACE_NAME || ' SHRINK SPACE KEEP 256M';
    BEGIN
      EXECUTE IMMEDIATE v_sql;
      DBMS_OUTPUT.PUT_LINE('Shrunk: ' || r.TABLESPACE_NAME);
    EXCEPTION
      WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('Skipped ' || r.TABLESPACE_NAME || ': ' || SQLERRM);
    END;
  END LOOP;
END;
/
EXIT;
SQL
) || true
echo "$OUT"

SHRUNK=$(printf '%s\n' "$OUT" | grep -c '^Shrunk:' || true)
save_action "DONE" "temp tablespace shrink completed on $ORACLE_SID ($SHRUNK tablespace(s) shrunk)"
echo "[$(date +%T)] Temp tablespace shrink complete."
