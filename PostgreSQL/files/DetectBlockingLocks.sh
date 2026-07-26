#!/usr/bin/env bash
# DetectBlockingLocks.sh [db ...] — report PostgreSQL lock waits, ported from
# the Db2 SYSIBMADM.MON_LOCKWAITS handler. Uses pg_locks + pg_stat_activity to
# find blocked and blocking backends. When a blocker has held a waiter longer
# than AUTO_KILL_MIN minutes (default 60 — mirrors the Db2 FORCE APPLICATION
# and the SQL Server / Oracle blocking handlers) the blocking connection is
# terminated with pg_terminate_backend().
#
# Optional first arg restricts to a single database (only_database).
#
# Final JSON: {"timestamp","blocked","killed",
#              "items":[{"database","blocker_handle","blocker_appl",
#                        "waiter_handle","wait_seconds","action"}]}
source "$(dirname "$0")/lib/pg_common.sh"

AUTO_KILL_MIN="${AUTO_KILL_MIN:-60}"
DBS="${*:-$(list_databases)}"
rows=""

BLOCKING_QUERY="
SELECT
    blocked_locks.pid::text          AS blocked_pid,
    blocking_locks.pid::text         AS blocking_pid,
    COALESCE(blocked_activity.usename, '?')  AS blocked_user,
    COALESCE(blocking_activity.usename, '?') AS blocking_user,
    EXTRACT(EPOCH FROM (now() - blocked_activity.query_start))::int AS wait_seconds,
    COALESCE(SUBSTRING(blocked_activity.query, 1, 120), '') AS blocked_query
FROM pg_catalog.pg_locks blocked_locks
JOIN pg_catalog.pg_stat_activity blocked_activity
    ON blocked_activity.pid = blocked_locks.pid
JOIN pg_catalog.pg_locks blocking_locks
    ON  blocking_locks.locktype = blocked_locks.locktype
    AND blocking_locks.database IS NOT DISTINCT FROM blocked_locks.database
    AND blocking_locks.relation IS NOT DISTINCT FROM blocked_locks.relation
    AND blocking_locks.page    IS NOT DISTINCT FROM blocked_locks.page
    AND blocking_locks.tuple   IS NOT DISTINCT FROM blocked_locks.tuple
    AND blocking_locks.virtualxid IS NOT DISTINCT FROM blocked_locks.virtualxid
    AND blocking_locks.transactionid IS NOT DISTINCT FROM blocked_locks.transactionid
    AND blocking_locks.classid IS NOT DISTINCT FROM blocked_locks.classid
    AND blocking_locks.objid   IS NOT DISTINCT FROM blocked_locks.objid
    AND blocking_locks.objsubid IS NOT DISTINCT FROM blocked_locks.objsubid
    AND blocking_locks.pid != blocked_locks.pid
JOIN pg_catalog.pg_stat_activity blocking_activity
    ON blocking_activity.pid = blocking_locks.pid
WHERE NOT blocked_locks.granted;
"

for db in $DBS; do
    raw="$(printf '%s' "$BLOCKING_QUERY" | sqlx "$db" 2>/dev/null)"

    while IFS='|' read -r wpid bpid wuser buser wsec wquery; do
        bpid="$(echo "$bpid" | tr -d ' ')"; [[ -z "$bpid" ]] && continue
        wsec="$(echo "$wsec" | tr -d ' ')"; wsec="${wsec:-0}"
        [[ "$wsec" =~ ^[0-9]+$ ]] || wsec=0
        action="logged"
        if (( wsec > AUTO_KILL_MIN * 60 )); then
            if printf '%s\n' "SELECT pg_terminate_backend(${bpid});" | sqlx "$db" >/dev/null 2>&1; then
                action="forced"
            else
                action="force_failed"
            fi
        fi
        rows+="${db}|${bpid}|${buser}|$(echo "$wpid" | tr -d ' ')|${wsec}|${action}"$'\n'
    done <<< "$raw"
done

printf '%s' "$rows" | python3 - <<'PY'
import json, sys, datetime
items, killed = [], 0
for line in sys.stdin.read().splitlines():
    if not line.strip():
        continue
    db, bpid, buser, wpid, wsec, action = (line.split('|') + ['']*6)[:6]
    if action == "forced":
        killed += 1
    items.append({
        "database": db, "blocker_handle": bpid, "blocker_appl": buser,
        "waiter_handle": wpid, "wait_seconds": int(wsec or 0), "action": action,
    })
print(json.dumps({
    "timestamp": datetime.datetime.now().strftime("%Y-%m-%dT%H:%M:%S"),
    "blocked": len(items), "killed": killed, "items": items,
}))
PY
