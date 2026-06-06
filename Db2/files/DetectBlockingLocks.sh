#!/usr/bin/env bash
# DetectBlockingLocks.sh [db ...] — report lock waits (SYSIBMADM.MON_LOCKWAITS)
# and auto-force the holding application when it has blocked for longer than
# AUTO_KILL_MIN minutes (default 60 — hard-coded safeguard, mirrors the
# SQL Server / Oracle blocking handlers).
#
# Final JSON: {"timestamp","blocked","killed",
#              "items":[{"database","blocker_handle","blocker_appl",
#                        "waiter_handle","wait_seconds","action"}]}
source "$(dirname "$0")/lib/db2_common.sh"

AUTO_KILL_MIN="${AUTO_KILL_MIN:-60}"
DBS="${*:-$(list_databases)}"
rows=""

for db in $DBS; do
    # holder handle | holder appl | waiter handle | wait seconds
    raw="$(printf '%s' "SELECT HLD_APPLICATION_HANDLE || '|' || COALESCE(HLD_APPLICATION_NAME,'?') || '|' || REQ_APPLICATION_HANDLE || '|' || CAST(LOCK_WAIT_ELAPSED_TIME AS BIGINT) FROM SYSIBMADM.MON_LOCKWAITS;" | sqlx "$db" 2>/dev/null)"
    while IFS='|' read -r hold happ wait_h wsec; do
        hold="$(echo "$hold" | tr -d ' ')"; [[ -z "$hold" ]] && continue
        wsec="$(echo "$wsec" | tr -d ' ')"; wsec="${wsec:-0}"
        action="logged"
        if (( wsec > AUTO_KILL_MIN * 60 )); then
            if printf '%s\n' "FORCE APPLICATION ($hold);" | sql "$db" >/dev/null 2>&1; then
                action="forced"
            else
                action="force_failed"
            fi
        fi
        rows+="${db}|${hold}|${happ}|$(echo "$wait_h" | tr -d ' ')|${wsec}|${action}"$'\n'
    done <<< "$raw"
done

printf '%s' "$rows" | python3 - "$AUTO_KILL_MIN" <<'PY'
import json, sys, datetime
items, killed = [], 0
for line in sys.stdin.read().splitlines():
    if not line.strip(): continue
    db, hold, happ, wait_h, wsec, action = (line.split('|') + ['']*6)[:6]
    if action == "forced": killed += 1
    items.append({
        "database": db, "blocker_handle": hold, "blocker_appl": happ,
        "waiter_handle": wait_h, "wait_seconds": int(wsec or 0), "action": action,
    })
print(json.dumps({
    "timestamp": datetime.datetime.now().strftime("%Y-%m-%dT%H:%M:%S"),
    "blocked": len(items), "killed": killed, "items": items,
}))
PY
