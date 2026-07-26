#!/usr/bin/env bash
# CheckPostgreSQLStatus.sh — service ping + per-database connect watchdog.
# Verifies the PostgreSQL service is up (pg_isready / systemctl is-active) and
# each database catalogued in databases.ini is connectable; attempts a single
# `systemctl start` once if the service is down (mirrors the Db2 db2start /
# MySQL watchdog).
#
# Final JSON: {"timestamp","host","restarted","failed","items":[{"item","state"}]}
source "$(dirname "$0")/lib/pg_common.sh"

HOST="$(hostname -s 2>/dev/null || hostname)"
restarted=0; failed=0
items=""

# Candidate systemd unit names across distros / major versions.
PG_UNITS="${PG_UNITS:-postgresql postgresql-16 postgresql-15 postgresql-14 postgresql-13}"

service_up() {
    local u
    for u in $PG_UNITS; do
        systemctl is-active --quiet "$u" 2>/dev/null && return 0
    done
    # Fall back to pg_isready when systemd isn't managing the server.
    pg_isready -h "$PG_DEFAULT_HOST" -p "$PG_DEFAULT_PORT" >/dev/null 2>&1
}

service_start() {
    local u
    for u in $PG_UNITS; do
        if systemctl start "$u" >/dev/null 2>&1 && systemctl is-active --quiet "$u" 2>/dev/null; then
            return 0
        fi
    done
    return 1
}

# Instance/service check.
if service_up; then
    items+="instance|running"$'\n'
else
    if service_start; then
        items+="instance|restarted"$'\n'; restarted=$((restarted+1))
    else
        items+="instance|failed_to_start"$'\n'; failed=$((failed+1))
    fi
fi

# Per-database connect test via SELECT 1.
for db in $(list_databases); do
    if [ "$(scalar "$db" "SELECT 1")" = "1" ]; then
        items+="${db}|running"$'\n'
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
