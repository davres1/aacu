#!/usr/bin/env bash
# CheckMySQLStatus.sh — service ping + per-schema connect watchdog.
# Verifies the mysqld/mariadb service is up (systemctl is-active / mysqladmin
# ping) and each schema catalogued in databases.ini is connectable; attempts a
# `systemctl start` once if the service is down (mirrors the Db2 db2start
# watchdog).
#
# Final JSON: {"timestamp","host","restarted","failed","items":[{"item","state"}]}
source "$(dirname "$0")/lib/mysql_common.sh"

HOST="$(hostname -s 2>/dev/null || hostname)"
restarted=0; failed=0
items=""

# Candidate systemd unit names across distros / flavors (mysql vs mariadb).
MYSQL_UNITS="${MYSQL_UNITS:-mysqld mariadb mysql}"

service_up() {
    local u
    for u in $MYSQL_UNITS; do
        systemctl is-active --quiet "$u" 2>/dev/null && return 0
    done
    # Fall back to a direct ping in case systemd isn't managing the server.
    mysqladmin ping >/dev/null 2>&1
}

service_start() {
    local u
    for u in $MYSQL_UNITS; do
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

# Per-schema connect test.
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
