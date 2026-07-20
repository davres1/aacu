#!/usr/bin/env bash
# IndexMaintenance.sh — cron-scheduled OPTIMIZE + ANALYZE for fragmented InnoDB
# tables (information_schema.TABLES.DATA_FREE above threshold). OPTIMIZE TABLE on
# InnoDB performs an online rebuild, which also rebuilds the secondary indexes;
# ANALYZE TABLE refreshes the optimizer statistics afterward.
# NOT a chatbot intent. Heavy; scheduled monthly.
source "$(dirname "$0")/lib/mysql_common.sh"

DBS="${*:-$(list_databases)}"
FRAG_BYTES="$(get_threshold index_maintenance.data_free_bytes 104857600)"
rc=0

for db in $DBS; do
    log "OPTIMIZE/ANALYZE pass on $db (DATA_FREE > ${FRAG_BYTES} bytes)"
    tables="$(printf '%s' "SELECT CONCAT('\`',TABLE_SCHEMA,'\`.\`',TABLE_NAME,'\`') FROM information_schema.TABLES WHERE ENGINE='InnoDB' AND TABLE_TYPE='BASE TABLE' AND DATA_FREE > ${FRAG_BYTES} AND TABLE_SCHEMA NOT IN ('mysql','information_schema','performance_schema','sys');" | sqlx "$db" 2>/dev/null | awk 'NF{print}')"
    for t in $tables; do
        # OPTIMIZE rebuilds the table + secondary indexes; ANALYZE refreshes stats.
        printf '%s\n' "OPTIMIZE TABLE ${t};" | sql "$db" >>"$LOG_FILE" 2>&1 || rc=1
        printf '%s\n' "ANALYZE TABLE ${t};" | sql "$db" >>"$LOG_FILE" 2>&1 || rc=1
    done
done
exit $rc
