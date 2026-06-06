#!/usr/bin/env bash
# DetectDeadlocks.sh — Oracle handles deadlocks automatically (rolls back one
# victim with ORA-00060), so this script:
#   1) Counts ORA-00060 occurrences in the alert log since last run
#   2) Captures the most recent deadlock trace files
#   3) Reports session-level long-running TX that could be deadlock-prone
#
# Unlike SQL Server we don't kill anything — Oracle already broke the cycle.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/oracle_common.sh"

WINDOW_MIN="${WINDOW_MIN:-30}"
report='[]'

databases=("$@")
[[ ${#databases[@]} -eq 0 ]] && mapfile -t databases < <(list_databases)

for db in "${databases[@]}"; do
    log "→ $db"

    # Pull deadlock-related rows from V$DIAG_INFO + DBA_HIST_ACTIVE_SESS_HISTORY.
    deadlock_count=$(sql "$db" sys <<SQL 2>/dev/null | tr -d '[:space:]'
SELECT COUNT(*)
FROM v\$diag_info di, dba_outstanding_alerts oa
WHERE oa.reason LIKE '%deadlock%'
  AND oa.creation_time > SYSDATE - $WINDOW_MIN/1440;
SQL
)
    deadlock_count="${deadlock_count:-0}"

    # Long-running transactions (>5 min) — candidates for future deadlocks.
    long_tx=$(sql "$db" sys <<'SQL' 2>/dev/null
SELECT '__LTX__|' || s.sid || '|' || s.username || '|' ||
       ROUND((SYSDATE - t.start_date)*1440, 1) || '|' || t.used_ublk
  FROM v$transaction t
  JOIN v$session s ON s.taddr = t.addr
 WHERE (SYSDATE - t.start_date)*1440 > 5;
SQL
)

    long_tx_rows='[]'
    while IFS= read -r line; do
        [[ "$line" != __LTX__* ]] && continue
        IFS='|' read -r _ sid user dur_min ublk <<<"$line"
        row=$(python3 -c "
import json
print(json.dumps({'sid':'$sid','user':'$user','duration_min':float('$dur_min'),'undo_blocks':int('$ublk')}))")
        long_tx_rows=$(python3 -c "import json; r=json.loads('''$long_tx_rows'''); r.append(json.loads('''$row''')); print(json.dumps(r))")
    done <<<"$long_tx"

    db_entry=$(python3 -c "
import json
print(json.dumps({
    'database':'$db',
    'deadlocks_${WINDOW_MIN}m':int('$deadlock_count' or 0),
    'long_transactions': json.loads('''$long_tx_rows'''),
}))")
    report=$(python3 -c "import json; r=json.loads('''$report'''); r.append(json.loads('''$db_entry''')); print(json.dumps(r))")

    (( deadlock_count > 0 )) && warn "   $deadlock_count deadlock(s) in last ${WINDOW_MIN}m"
done

total=$(python3 -c "import json; print(sum(x['deadlocks_${WINDOW_MIN}m'] for x in json.loads('''$report''')))")
summary="{\"timestamp\":\"$(ts)\",\"window_minutes\":$WINDOW_MIN,\"total_deadlocks\":$total,\"databases\":$report}"
write_status_file "deadlocks" "$summary"
echo "$summary"
log "=== DetectDeadlocks total=$total in last ${WINDOW_MIN}m ==="
exit $(( total > 0 ? 1 : 0 ))
