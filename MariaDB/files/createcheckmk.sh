#!/usr/bin/env bash
# createcheckmk.sh [db ...] — provision a read-only monitoring account for the
# CheckMK local (mysql_*) plugins. Creates the '<checkmk>'@'<host>' user if it
# does not exist, grants the global monitoring privileges (PROCESS, REPLICATION
# CLIENT — needed for processlist / replication / InnoDB status) once, and grants
# SELECT on each configured schema so the plugins can read health metrics.
# Returns rc=1 if any database fails.
source "$(dirname "$0")/lib/mariadb_common.sh"

CHECKMK_USER="${CHECKMK_USER:-checkmk}"
CHECKMK_HOST="${CHECKMK_HOST:-localhost}"
DBS="${*:-$(list_databases)}"
failures=0

for db in $DBS; do
    if printf '%s\n' \
        "CREATE USER IF NOT EXISTS '${CHECKMK_USER}'@'${CHECKMK_HOST}';" \
        "GRANT PROCESS, REPLICATION CLIENT ON *.* TO '${CHECKMK_USER}'@'${CHECKMK_HOST}';" \
        "GRANT SELECT ON \`${db}\`.* TO '${CHECKMK_USER}'@'${CHECKMK_HOST}';" \
        "FLUSH PRIVILEGES;" \
        | sql "$db" >>"$LOG_FILE" 2>&1; then
        log "granted monitoring privileges on $db to ${CHECKMK_USER}@${CHECKMK_HOST}"
    else
        err "failed to grant monitoring privileges on $db to ${CHECKMK_USER}@${CHECKMK_HOST}"
        failures=$((failures+1))
    fi
done

[[ "$failures" -eq 0 ]]
