#!/usr/bin/env bash
# IndexMaintenance.sh — cron-scheduled VACUUM ANALYZE + REINDEX for bloated and
# invalid PostgreSQL tables/indexes. Uses pg_stat_user_tables.n_dead_tup to
# identify tables with high dead-tuple counts and runs VACUUM ANALYZE on them.
# Invalid indexes are rebuilt with REINDEX INDEX CONCURRENTLY.
# NOT a chatbot intent. Heavy; scheduled weekly/monthly.
source "$(dirname "$0")/lib/pg_common.sh"

DBS="${*:-$(list_databases)}"
DEAD_TUP_THRESHOLD="$(get_threshold index_maintenance.dead_tup_threshold 10000)"
rc=0

for db in $DBS; do
    log "Index/vacuum maintenance pass on $db (n_dead_tup > ${DEAD_TUP_THRESHOLD})"

    # --- VACUUM ANALYZE tables with high dead-tuple counts ---
    bloated_tables="$(printf '%s\n' \
        "SELECT schemaname || '.' || tablename
         FROM pg_stat_user_tables
         WHERE n_dead_tup > ${DEAD_TUP_THRESHOLD}
         ORDER BY n_dead_tup DESC
         LIMIT 50;" \
        | sqlx "$db" 2>/dev/null | awk 'NF{print}')"

    for t in $bloated_tables; do
        log "VACUUM ANALYZE $t in $db"
        printf '%s\n' "VACUUM ANALYZE ${t};" | sql "$db" >>"$LOG_FILE" 2>&1 || rc=1
    done

    # --- REINDEX CONCURRENTLY invalid indexes ---
    invalid_indexes="$(printf '%s\n' \
        "SELECT schemaname || '.' || indexrelname
         FROM pg_stat_user_indexes sui
         JOIN pg_index pi ON pi.indexrelid = sui.indexrelid
         WHERE NOT pi.indisvalid
         ORDER BY schemaname, indexrelname;" \
        | sqlx "$db" 2>/dev/null | awk 'NF{print}')"

    for idx in $invalid_indexes; do
        log "REINDEX INDEX CONCURRENTLY $idx in $db"
        printf '%s\n' "REINDEX INDEX CONCURRENTLY ${idx};" \
            | sql "$db" >>"$LOG_FILE" 2>&1 || rc=1
    done

    # --- ANALYZE tables with stale statistics (no autovacuum for > 7 days) ---
    stale_tables="$(printf '%s\n' \
        "SELECT schemaname || '.' || tablename
         FROM pg_stat_user_tables
         WHERE (last_analyze IS NULL OR last_analyze < now() - interval '7 days')
           AND (last_autoanalyze IS NULL OR last_autoanalyze < now() - interval '7 days')
           AND n_live_tup > 1000
         ORDER BY n_live_tup DESC
         LIMIT 30;" \
        | sqlx "$db" 2>/dev/null | awk 'NF{print}')"

    for t in $stale_tables; do
        log "ANALYZE $t in $db"
        printf '%s\n' "ANALYZE ${t};" | sql "$db" >>"$LOG_FILE" 2>&1 || rc=1
    done
done
exit $rc
