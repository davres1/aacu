#!/usr/bin/env bash
# DetectBlockingLocks.sh — find blockers + long waiting sessions, kill those
# blocking longer than $AUTO_KILL_MIN minutes. Mirrors DetectBlockingLocks.ps1.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/oracle_common.sh"

AUTO_KILL_MIN="${AUTO_KILL_MIN:-60}"   # kill blockers older than this
report='[]'

databases=("$@")
[[ ${#databases[@]} -eq 0 ]] && mapfile -t databases < <(list_databases)

for db in "${databases[@]}"; do
    log "→ $db"

    # Blocker / waiter pairs with wait duration in seconds.
    rows=$(sql "$db" sys <<'SQL' 2>/dev/null || true
SELECT '__B__|' ||
       b.sid || '|' || b.serial# || '|' || b.username || '|' ||
       NVL(w.sid,0) || '|' || NVL(w.username,'') || '|' ||
       w.seconds_in_wait || '|' ||
       w.event
  FROM v$session b
  JOIN v$session w ON w.blocking_session = b.sid
 WHERE w.seconds_in_wait > 30;
SQL
)

    if [[ -z "$rows" ]]; then
        log "   no blocking"
        continue
    fi

    while IFS= read -r line; do
        [[ "$line" != __B__* ]] && continue
        IFS='|' read -r _ b_sid b_serial b_user w_sid w_user wait_sec wait_evt <<<"$line"
        wait_min=$(( wait_sec / 60 ))
        log "   BLOCKER sid=$b_sid ($b_user) -> WAITER sid=$w_sid ($w_user) ${wait_min}m on $wait_evt"

        action="logged"
        if (( wait_min > AUTO_KILL_MIN )); then
            warn "   Killing blocker sid=$b_sid (over ${AUTO_KILL_MIN}m)"
            if sql "$db" sys <<SQL >/dev/null 2>&1
ALTER SYSTEM KILL SESSION '$b_sid,$b_serial' IMMEDIATE;
SQL
            then action="killed"
            else action="kill_failed"
            fi
        fi

        item=$(python3 -c "
import json
print(json.dumps({
    'database':'$db',
    'blocker_sid':'$b_sid','blocker_serial':'$b_serial','blocker_user':'$b_user',
    'waiter_sid':'$w_sid','waiter_user':'$w_user',
    'wait_seconds':$wait_sec,'wait_event':'$wait_evt','action':'$action',
}))")
        report=$(python3 -c "import json; r=json.loads('''$report'''); r.append(json.loads('''$item''')); print(json.dumps(r))")
    done <<<"$rows"
done

killed=$(python3 -c "import json; print(sum(1 for x in json.loads('''$report''') if x['action']=='killed'))")
blocked=$(python3 -c "import json; print(len(json.loads('''$report''')))")
summary="{\"timestamp\":\"$(ts)\",\"blocked\":$blocked,\"killed\":$killed,\"items\":$report}"
write_status_file "blocking_locks" "$summary"
echo "$summary"
log "=== DetectBlockingLocks blocked=$blocked killed=$killed ==="
exit $(( blocked > 0 ? 1 : 0 ))
