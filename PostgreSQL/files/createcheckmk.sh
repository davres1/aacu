#!/usr/bin/env bash
# createcheckmk.sh [db ...] — provision a read-only monitoring account for the
# CheckMK local (pg_*) plugins. Creates the 'checkmk' user if it does not exist,
# grants the pg_monitor built-in role (PG 10+) which provides read access to all
# monitoring views including pg_stat_activity, pg_stat_replication, etc., and
# grants CONNECT + SELECT on each configured database.
# Returns rc=1 if any database fails.
source "$(dirname "$0")/lib/pg_common.sh"

CHECKMK_USER="${CHECKMK_USER:-checkmk}"
CHECKMK_PASS="${CHECKMK_PASS:-}"
DBS="${*:-$(list_databases)}"
failures=0

for db in $DBS; do
    sql_stmts=""

    if [ -n "$CHECKMK_PASS" ]; then
        sql_stmts="CREATE USER ${CHECKMK_USER} WITH PASSWORD '${CHECKMK_PASS}';"$'\n'
    else
        sql_stmts="CREATE USER ${CHECKMK_USER};"$'\n'
    fi

    sql_stmts+="
GRANT CONNECT ON DATABASE ${db} TO ${CHECKMK_USER};
GRANT USAGE ON SCHEMA public TO ${CHECKMK_USER};
GRANT SELECT ON ALL TABLES IN SCHEMA public TO ${CHECKMK_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO ${CHECKMK_USER};
GRANT pg_monitor TO ${CHECKMK_USER};
"

    # CREATE USER is idempotent via DO block (avoid error if user exists).
    pg_stmts="DO \$\$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${CHECKMK_USER}') THEN"
    if [ -n "$CHECKMK_PASS" ]; then
        pg_stmts+="
        CREATE USER ${CHECKMK_USER} WITH PASSWORD '${CHECKMK_PASS}';"
    else
        pg_stmts+="
        CREATE USER ${CHECKMK_USER};"
    fi
    pg_stmts+="
    END IF;
END
\$\$;
GRANT CONNECT ON DATABASE ${db} TO ${CHECKMK_USER};
GRANT USAGE ON SCHEMA public TO ${CHECKMK_USER};
GRANT SELECT ON ALL TABLES IN SCHEMA public TO ${CHECKMK_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO ${CHECKMK_USER};
GRANT pg_monitor TO ${CHECKMK_USER};"

    if printf '%s\n' "$pg_stmts" | sql "$db" >>"$LOG_FILE" 2>&1; then
        log "granted monitoring privileges on $db to ${CHECKMK_USER}"
    else
        err "failed to grant monitoring privileges on $db to ${CHECKMK_USER}"
        failures=$((failures+1))
    fi
done

[[ "$failures" -eq 0 ]]
