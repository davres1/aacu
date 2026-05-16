#!/usr/bin/env bash
# IndexMaintenance.sh — analyse + rebuild Oracle indexes.
# Uses INDEX_STATS via ANALYZE INDEX ... VALIDATE STRUCTURE to compute
# deletion ratio; rebuilds any index where del_lf_rows/lf_rows > $REBUILD_PCT.
# Rebuilds happen ONLINE to avoid blocking DML.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/oracle_common.sh"

REBUILD_PCT="${REBUILD_PCT:-30}"      # rebuild if deleted-leaf-rows > this %
MIN_LEAF_BLOCKS="${MIN_LEAF_BLOCKS:-100}"   # skip tiny indexes
SCHEMA_FILTER="${SCHEMA_FILTER:-}"    # restrict to one schema if set
report='[]'

databases=("$@")
[[ ${#databases[@]} -eq 0 ]] && mapfile -t databases < <(list_databases)

for db in "${databases[@]}"; do
    log "→ $db"
    where_schema=""
    [[ -n "$SCHEMA_FILTER" ]] && where_schema="AND owner = UPPER('$SCHEMA_FILTER')"

    # Get candidate indexes via DBA_INDEXES + INDEX_STATS sampling. To keep
    # the run bounded we only look at indexes with > MIN_LEAF_BLOCKS pages.
    indexes=$(sql "$db" sys <<SQL 2>/dev/null || true
SELECT '__IDX__|' || owner || '|' || index_name || '|' || table_name
  FROM dba_indexes
 WHERE index_type IN ('NORMAL','FUNCTION-BASED NORMAL')
   AND status = 'VALID'
   AND temporary = 'N'
   AND leaf_blocks > $MIN_LEAF_BLOCKS
   AND owner NOT IN ('SYS','SYSTEM','XDB','MDSYS','CTXSYS','WMSYS','APEX_PUBLIC_USER','APEX_040000')
   $where_schema
 ORDER BY leaf_blocks DESC
 FETCH FIRST 200 ROWS ONLY;
SQL
)

    rebuilt=0; analysed=0
    while IFS= read -r line; do
        [[ "$line" != __IDX__* ]] && continue
        IFS='|' read -r _ owner idx tbl <<<"$line"
        ((analysed++))
        # ANALYZE INDEX gives us INDEX_STATS — but only inside the same session.
        # We compose: VALIDATE + select pct + rebuild if needed, all in one SQL.
        result=$(sql "$db" sys <<SQL 2>/dev/null
ANALYZE INDEX "$owner"."$idx" VALIDATE STRUCTURE;
SELECT '__PCT__|' ||
       CASE WHEN lf_rows = 0 THEN 0
            ELSE ROUND((del_lf_rows / lf_rows) * 100, 1)
       END
FROM index_stats;
SQL
)
        pct=$(echo "$result" | awk -F'\\|' '/__PCT__/{print $2}' | tr -d '[:space:]')
        pct="${pct:-0}"

        if python3 -c "import sys; sys.exit(0 if float('$pct') > $REBUILD_PCT else 1)"; then
            log "   REBUILD $owner.$idx (deleted=$pct%)"
            if sql "$db" sys <<SQL >/dev/null 2>&1
ALTER INDEX "$owner"."$idx" REBUILD ONLINE;
SQL
            then ((rebuilt++))
            else warn "      rebuild failed"
            fi
        fi
    done <<<"$indexes"

    log "   $db analysed=$analysed rebuilt=$rebuilt"
    db_entry=$(python3 -c "
import json
print(json.dumps({'database':'$db','analysed':$analysed,'rebuilt':$rebuilt}))")
    report=$(python3 -c "import json; r=json.loads('''$report'''); r.append(json.loads('''$db_entry''')); print(json.dumps(r))")
done

summary="{\"timestamp\":\"$(ts)\",\"databases\":$report}"
echo "$summary"
log "=== IndexMaintenance done ==="
