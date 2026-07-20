#!/usr/bin/env bash
# PatchLevelCheck.sh — report the MariaDB/MariaDB server version (SELECT VERSION())
# for each configured instance and flag anything below thresholds.patch.min_version.
# Also reports the most recently installed OS package (age proxy).
#
# Final JSON: {"timestamp",
#   "sql_instances":[{instance,version,min_version,compliant}],
#   "databases":[{database,version}],
#   "os":{"last_package","mysql_package"}}
source "$(dirname "$0")/lib/mariadb_common.sh"

MIN_VERSION="$(get_threshold patch.min_version '8.0.0')"

LAST_OS_PKG="$( (rpm -qa --last 2>/dev/null || true) | head -1 )"
MYSQL_OS_PKG="$( (rpm -qa --last 'mysql*' 'mariadb*' 'percona*' 2>/dev/null || true) | head -1 )"

db_rows=""
for db in $(list_databases); do
    creds="$(db_credentials "$db" 2>/dev/null)" || continue
    IFS=$'\t' read -r _u _p host port <<<"$creds"
    ver="$(scalar "$db" "SELECT VERSION();")"
    db_rows+="${db}|${host}:${port}|${ver}"$'\n'
done

printf '%s' "$db_rows" | python3 - "$MIN_VERSION" "$LAST_OS_PKG" "$MYSQL_OS_PKG" <<'PY'
import json, sys, datetime, re
min_ver, last_pkg, mysql_pkg = sys.argv[1:4]

def vtuple(v):
    m = re.match(r'(\d+)\.(\d+)\.(\d+)', v or '')
    return tuple(int(x) for x in m.groups()) if m else (0, 0, 0)

min_t = vtuple(min_ver)
instances, seen, dbs = [], {}, []
for line in sys.stdin.read().splitlines():
    if not line.strip():
        continue
    db, inst, ver = (line.split('|') + ['', '', ''])[:3]
    dbs.append({"database": db, "version": ver})
    if inst and inst not in seen:
        seen[inst] = True
        instances.append({
            "instance": inst,
            "version": ver,
            "min_version": min_ver,
            "compliant": vtuple(ver) >= min_t,
        })
print(json.dumps({
    "timestamp": datetime.datetime.now().strftime("%Y-%m-%dT%H:%M:%S"),
    "sql_instances": instances,
    "databases": dbs,
    "os": {"last_package": last_pkg, "mysql_package": mysql_pkg},
}))
PY
