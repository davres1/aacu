#!/usr/bin/env bash
# createcheckmk.sh [db ...] — grant a read-only monitoring user CONNECT on each
# database. The OS account (default 'checkmk') must already exist; Db2 catalog
# views (SYSCAT.*, SYSIBMADM.*) are SELECTable by PUBLIC, so CONNECT is enough
# for the local plugins to read health metrics. Returns rc=1 if any DB fails.
source "$(dirname "$0")/lib/db2_common.sh"

CHECKMK_USER="${CHECKMK_USER:-checkmk}"
DBS="${*:-$(list_databases)}"
failures=0

for db in $DBS; do
    if _db2_connect "$db"; then
        if db2 "GRANT CONNECT ON DATABASE TO USER ${CHECKMK_USER}" >/dev/null 2>&1; then
            log "granted CONNECT on $db to $CHECKMK_USER"
        else
            err "failed to grant CONNECT on $db to $CHECKMK_USER"; failures=$((failures+1))
        fi
        db2 connect reset >/dev/null 2>&1 || true
    else
        err "cannot connect to $db"; failures=$((failures+1))
    fi
done

[[ "$failures" -eq 0 ]]
