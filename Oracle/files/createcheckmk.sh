#!/usr/bin/env bash
# createcheckmk.sh — create a 'checkmk' Oracle monitoring user with read-only
# privileges (SELECT_CATALOG_ROLE, SELECT ANY DICTIONARY) on every DB listed
# in databases.ini.
#
#   ./createcheckmk.sh              # operate on every DB
#   ./createcheckmk.sh PHHSDG8      # just one
#
# Password defaults to env CHECKMK_PASSWORD, else 'checkmk' (matching the
# bootstrap convention for the InfluxDB user).

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/oracle_common.sh"

CHECKMK_USER="${CHECKMK_USER:-checkmk}"
CHECKMK_PW="${CHECKMK_PASSWORD:-checkmk}"

databases=()
if [[ $# -gt 0 ]]; then
    databases=("$@")
else
    mapfile -t databases < <(list_databases)
fi

log "Creating monitoring user '$CHECKMK_USER' on ${#databases[@]} DB(s)"

successes=0; failures=0
for db in "${databases[@]}"; do
    [[ -z "$db" ]] && continue
    log "→ $db"
    if sql "$db" <<SQL
DECLARE
    n NUMBER;
BEGIN
    SELECT COUNT(*) INTO n FROM dba_users WHERE username = UPPER('$CHECKMK_USER');
    IF n = 0 THEN
        EXECUTE IMMEDIATE 'CREATE USER $CHECKMK_USER IDENTIFIED BY "$CHECKMK_PW" '
                       || 'DEFAULT TABLESPACE USERS TEMPORARY TABLESPACE TEMP '
                       || 'PROFILE DEFAULT';
    ELSE
        EXECUTE IMMEDIATE 'ALTER USER $CHECKMK_USER IDENTIFIED BY "$CHECKMK_PW" ACCOUNT UNLOCK';
    END IF;
    EXECUTE IMMEDIATE 'GRANT CREATE SESSION TO $CHECKMK_USER';
    EXECUTE IMMEDIATE 'GRANT SELECT_CATALOG_ROLE TO $CHECKMK_USER';
    EXECUTE IMMEDIATE 'GRANT SELECT ANY DICTIONARY TO $CHECKMK_USER';
    EXECUTE IMMEDIATE 'ALTER USER $CHECKMK_USER QUOTA 0 ON USERS';
END;
/
SQL
    then
        log "   OK"
        ((successes++))
    else
        warn "   FAILED on $db"
        ((failures++))
    fi
done

log "=== createcheckmk done: $successes ok, $failures failed ==="
exit $(( failures > 0 ? 1 : 0 ))
