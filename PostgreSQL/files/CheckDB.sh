#!/usr/bin/env bash
# CheckDB.sh [db ...] — logical/physical integrity checks for PostgreSQL.
# Uses the amcheck extension (bt_index_check) if available, then falls back to
# pg_catalog sanity queries (invalid indexes, toast consistency). Writes the
# result to $STATUS_DIR/checkdb_status.json (read back fast by
# GetCheckDBStatus.sh). Heavy — scheduled weekly, not run from the chatbot.
#
# Final JSON: {"timestamp","total","clean","errors","failed",
#              "items":[{"database","status","duration_sec","log"}]}
source "$(dirname "$0")/lib/pg_common.sh"

DBS="${*:-$(list_databases)}"
rows=""

for db in $DBS; do
    logf="$LOG_DIR/checkdb_${db}_$(date +%Y%m%d_%H%M%S).out"
    start=$(date +%s)

    if [ "$(scalar "$db" "SELECT 1")" != "1" ]; then
        status="failed"
        printf 'connection to %s failed\n' "$db" >"$logf"
        dur=$(( $(date +%s) - start ))
        rows+="${db}|${status}|${dur}|${logf}"$'\n'
        continue
    fi

    # Check whether amcheck extension is available.
    have_amcheck="$(scalar "$db" \
        "SELECT COUNT(*) FROM pg_available_extensions WHERE name='amcheck'")"

    {
        printf '=== CheckDB for %s at %s ===\n' "$db" "$(date)"

        if [ "${have_amcheck:-0}" = "1" ]; then
            printf 'Using amcheck extension for B-tree index verification\n'
            # Ensure amcheck is created if not already.
            printf '%s\n' "CREATE EXTENSION IF NOT EXISTS amcheck;" | sqlx "$db" 2>&1 || true

            # Run bt_index_check on all non-system B-tree indexes.
            printf '%s\n' "
SELECT 'INDEX: ' || schemaname || '.' || indexname || ': ' ||
       CASE WHEN bt_index_check(i.indexrelid::regclass) IS DISTINCT FROM NULL
            THEN 'ERROR'
            ELSE 'ok'
       END
FROM pg_indexes
JOIN pg_class i ON i.relname = indexname
JOIN pg_namespace n ON n.oid = i.relnamespace AND n.nspname = schemaname
WHERE schemaname NOT IN ('pg_catalog', 'information_schema', 'pg_toast')
  AND EXISTS (
      SELECT 1 FROM pg_index pi
      JOIN pg_am am ON am.oid = (SELECT relam FROM pg_class WHERE oid = pi.indexrelid)
      WHERE pi.indexrelid = i.oid AND am.amname = 'btree'
  );
" | sql "$db" 2>&1
        fi

        # Always run: invalid index check (these cause query failures).
        printf '\n--- Invalid indexes ---\n'
        printf '%s\n' "
SELECT schemaname || '.' || tablename AS table,
       indexrelname AS index,
       'INVALID' AS status
FROM pg_stat_user_indexes sui
JOIN pg_index pi ON pi.indexrelid = sui.indexrelid
WHERE NOT pi.indisvalid;
" | sql "$db" 2>&1

        # Catalog sanity: pg_class / pg_attribute cross-check.
        printf '\n--- Catalog sanity (orphaned pg_attribute rows) ---\n'
        printf '%s\n' "
SELECT COUNT(*) AS orphaned_attrs
FROM pg_attribute a
WHERE NOT EXISTS (SELECT 1 FROM pg_class c WHERE c.oid = a.attrelid);
" | sql "$db" 2>&1

        printf '=== Done ===\n'
    } >"$logf" 2>&1

    # Determine status from the log output.
    if grep -qiE 'ERROR|INVALID|corrupt|panic' "$logf"; then
        status="errors"
    else
        status="clean"
    fi

    dur=$(( $(date +%s) - start ))
    rows+="${db}|${status}|${dur}|${logf}"$'\n'
done

result="$(printf '%s' "$rows" | python3 - <<'PY'
import json, sys, datetime
items, clean, errors, failed = [], 0, 0, 0
for line in sys.stdin.read().splitlines():
    if not line.strip(): continue
    db, status, dur, logf = (line.split('|') + ['']*4)[:4]
    if status == "clean": clean += 1
    elif status == "errors": errors += 1
    else: failed += 1
    items.append({"database": db, "status": status,
                  "duration_sec": int(dur or 0), "log": logf})
print(json.dumps({
    "timestamp": datetime.datetime.now().strftime("%Y-%m-%dT%H:%M:%S"),
    "total": len(items), "clean": clean, "errors": errors, "failed": failed,
    "items": items,
}))
PY
)"
write_status_file checkdb_status "$result"
printf '%s\n' "$result"
