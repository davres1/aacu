#!/usr/bin/env bash
# CheckDb2Status.sh — instance + per-database connect watchdog.
# Verifies the instance is up (db2pd -) and each catalogued DB is connectable;
# attempts `db2start` once if the instance is down.
#
# Final JSON: {"timestamp","host","restarted","failed","items":[{"item","state"}]}
source "$(dirname "$0")/lib/db2_common.sh"

HOST="$(hostname -s 2>/dev/null || hostname)"
restarted=0; failed=0
items=""

# Instance check.
if db2pd - >/dev/null 2>&1; then
    items+="instance|running"$'\n'
else
    if db2start >/dev/null 2>&1; then
        items+="instance|restarted"$'\n'; restarted=$((restarted+1))
    else
        items+="instance|failed_to_start"$'\n'; failed=$((failed+1))
    fi
fi

# Per-database connect test.
for db in $(list_databases); do
    if db2 connect to "$db" >/dev/null 2>&1; then
        items+="${db}|running"$'\n'
        db2 connect reset >/dev/null 2>&1 || true
    else
        items+="${db}|unreachable"$'\n'; failed=$((failed+1))
    fi
done

printf '%s' "$items" | python3 - "$HOST" "$restarted" "$failed" <<'PY'
import json, sys, datetime
host, restarted, failed = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
items = []
for line in sys.stdin.read().splitlines():
    if not line.strip(): continue
    item, state = (line.split('|') + [''])[:2]
    items.append({"item": item, "state": state})
print(json.dumps({
    "timestamp": datetime.datetime.now().strftime("%Y-%m-%dT%H:%M:%S"),
    "host": host, "restarted": restarted, "failed": failed, "items": items,
}))
PY
