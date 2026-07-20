#!/usr/bin/env bash
# DetectBlockingLocks.sh [db ...] — report InnoDB lock waits, ported from the
# Db2 SYSIBMADM.MON_LOCKWAITS handler. Uses sys.innodb_lock_waits when present,
# otherwise performance_schema.data_lock_waits joined to threads. Waits are
# attributed to the schema of the locked object so per-database reporting works.
# When a blocker has held a waiter for longer than AUTO_KILL_MIN minutes
# (default 60 — hard-coded safeguard, mirrors the Db2 FORCE APPLICATION and the
# SQL Server / Oracle blocking handlers) the blocking connection is KILLed.
#
# Optional first arg restricts to a single database (only_database).
#
# Final JSON: {"timestamp","blocked","killed",
#              "items":[{"database","blocker_handle","blocker_appl",
#                        "waiter_handle","wait_seconds","action"}]}
source "$(dirname "$0")/lib/mariadb_common.sh"

AUTO_KILL_MIN="${AUTO_KILL_MIN:-60}"
DBS="${*:-$(list_databases)}"
rows=""

for db in $DBS; do
    have_sys="$(scalar "$db" "SELECT COUNT(*) FROM information_schema.VIEWS WHERE TABLE_SCHEMA='sys' AND TABLE_NAME='innodb_lock_waits'")"
    if [[ "${have_sys:-0}" != "0" ]]; then
        # blocker_pid | blocker_user | waiter_pid | wait_seconds
        raw="$(printf '%s' "SELECT CONCAT_WS('\t',
                    w.blocking_pid,
                    COALESCE(bt.PROCESSLIST_USER,'?'),
                    w.waiting_pid,
                    COALESCE(w.wait_age_secs,
                             TIMESTAMPDIFF(SECOND, w.wait_started, NOW()), 0))
                  FROM sys.innodb_lock_waits w
                  LEFT JOIN performance_schema.threads bt
                    ON bt.PROCESSLIST_ID = w.blocking_pid
                  WHERE w.locked_table_schema = DATABASE();" | sqlx "$db" 2>/dev/null)"
    else
        raw="$(printf '%s' "SELECT CONCAT_WS('\t',
                    bt.PROCESSLIST_ID,
                    COALESCE(bt.PROCESSLIST_USER,'?'),
                    rt.PROCESSLIST_ID,
                    CAST(ROUND(COALESCE(tx.TIMER_WAIT,0)/1000000000000) AS SIGNED))
                  FROM performance_schema.data_lock_waits w
                  JOIN performance_schema.threads bt
                    ON bt.THREAD_ID = w.BLOCKING_THREAD_ID
                  JOIN performance_schema.threads rt
                    ON rt.THREAD_ID = w.REQUESTING_THREAD_ID
                  JOIN performance_schema.data_locks dl
                    ON dl.ENGINE_LOCK_ID = w.REQUESTING_ENGINE_LOCK_ID
                  LEFT JOIN performance_schema.events_transactions_current tx
                    ON tx.THREAD_ID = w.REQUESTING_THREAD_ID
                  WHERE dl.OBJECT_SCHEMA = DATABASE();" | sqlx "$db" 2>/dev/null)"
    fi

    while IFS=$'\t' read -r bpid buser wpid wsec; do
        bpid="$(echo "$bpid" | tr -d ' ')"; [[ -z "$bpid" ]] && continue
        wsec="$(echo "$wsec" | tr -d ' ')"; wsec="${wsec:-0}"
        [[ "$wsec" =~ ^[0-9]+$ ]] || wsec=0
        action="logged"
        if (( wsec > AUTO_KILL_MIN * 60 )); then
            if printf '%s\n' "KILL ${bpid};" | sql "$db" >/dev/null 2>&1; then
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
