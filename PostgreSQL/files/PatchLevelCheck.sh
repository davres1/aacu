#!/usr/bin/env bash
# PatchLevelCheck.sh — report the PostgreSQL server version (SHOW server_version)
# for each configured database and flag anything below thresholds.patch.min_version.
# Also reports the most recently installed OS package (age proxy).
#
# Final JSON: {"timestamp",
#   "sql_instances":[{instance,version,min_version,compliant}],
#   "databases":[{database,version}],
#   "os":{"last_package","pg_package"}}
source "$(dirname "$0")/lib/pg_common.sh"

MIN_VERSION="$(get_threshold patch.min_version '14.0.0')"

LAST_OS_PKG="$( (rpm -qa --last 2>/dev/null || true) | head -1 )"
if [ -z "$LAST_OS_PKG" ]; then
    # Debian/Ubuntu fallback.
    LAST_OS_PKG="$( (grep 'install ' /var/log/dpkg.log 2>/dev/null || true) | tail -1 )"
fi
PG_OS_PKG="$( (rpm -qa --last 'postgresql*' 2>/dev/null || true) | head -1 )"
if [ -z "$PG_OS_PKG" ]; then
    PG_OS_PKG="$( (grep 'install postgresql' /var/log/dpkg.log 2>/dev/null || true) | tail -1 )"
fi

# psql binary version.
PSQL_BIN_VER="$("$PSQL_BIN" --version 2>/dev/null | head -1 || true)"

db_rows=""
for db in $(list_databases); do
    creds="$(db_credentials "$db" 2>/dev/null)" || continue
    IFS=$'\t' read -r _u _p host port <<<"$creds"
    ver="$(scalar "$db" "SHOW server_version;")"
    db_rows+="${db}|${host}:${port}|${ver}"$'\n'
done

printf '%s' "$db_rows" | python3 - "$MIN_VERSION" "$LAST_OS_PKG" "$PG_OS_PKG" "$PSQL_BIN_VER" <<'PY'
import json, sys, datetime, re
min_ver, last_pkg, pg_pkg, psql_ver = sys.argv[1:5]

def vtuple(v):
    m = re.match(r'(\d+)\.?(\d*)\.?(\d*)', v or '')
    if not m:
        return (0, 0, 0)
    parts = [int(x) if x else 0 for x in m.groups()]
    return tuple(parts)

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
    "os": {"last_package": last_pkg, "pg_package": pg_pkg, "psql_binary": psql_ver},
}))
PY
