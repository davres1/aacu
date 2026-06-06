#!/usr/bin/env bash
# PatchLevelCheck.sh — report Db2 install level (db2level) + per-DB service level
# from SYSIBMADM.ENV_INST_INFO. Compares against thresholds.json patch.min_fixpack.
#
# Final JSON: {"timestamp","instances":[{instance,version,fixpack,build}],
#              "databases":[{database,service_level}],"last_os_package":"..."}
source "$(dirname "$0")/lib/db2_common.sh"

MIN_FIXPACK="$(get_threshold patch.min_fixpack '11.5.8.0')"
INSTANCE="${DB2INSTANCE:-$(db2 get instance 2>/dev/null | awk -F'is: ' '/instance/{print $2; exit}')}"
INSTANCE="${INSTANCE:-db2inst1}"

LEVEL="$(db2level 2>/dev/null)"
VERSION="$(printf '%s' "$LEVEL" | grep -oE 'v[0-9]+\.[0-9.]+' | head -1)"
FIXPACK="$(printf '%s' "$LEVEL" | grep -oE 'Fix Pack[^"]*"[0-9]+"' | grep -oE '[0-9]+$')"
BUILD="$(printf '%s' "$LEVEL" | grep -oE 's[0-9]{6,}' | head -1)"

LAST_OS_PKG="$( (rpm -qa --last 2>/dev/null || true) | head -1)"

db_rows=""
for db in $(list_databases); do
    svc="$(printf '%s' "SELECT SERVICE_LEVEL FROM TABLE(SYSPROC.ENV_GET_INST_INFO()) AS T;" | sqlx "$db" 2>/dev/null | tr -d ' ')"
    db_rows+="${db}|${svc}"$'\n'
done

printf '%s' "$db_rows" | python3 - "$INSTANCE" "$VERSION" "$FIXPACK" "$BUILD" "$MIN_FIXPACK" "$LAST_OS_PKG" <<'PY'
import json, sys, datetime
inst, ver, fp, build, min_fp, last_pkg = sys.argv[1:7]
dbs = []
for line in sys.stdin.read().splitlines():
    if not line.strip(): continue
    db, svc = (line.split('|') + ['', ''])[:2]
    dbs.append({"database": db, "service_level": svc})
print(json.dumps({
    "timestamp": datetime.datetime.now().strftime("%Y-%m-%dT%H:%M:%S"),
    "instances": [{"instance": inst, "version": ver, "fixpack": fp, "build": build,
                   "min_fixpack": min_fp}],
    "databases": dbs,
    "last_os_package": last_pkg,
}))
PY
