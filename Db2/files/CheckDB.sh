#!/usr/bin/env bash
# CheckDB.sh [db ...] — logical/physical integrity via INSPECT CHECK DATABASE.
# Writes the result to $STATUS_DIR/checkdb_status.json (read back, fast, by
# GetCheckDBStatus.sh). Heavy — scheduled weekly, not run from the chatbot.
#
# Final JSON: {"timestamp","total","clean","errors","failed",
#              "items":[{"database","status","duration_sec","log"}]}
source "$(dirname "$0")/lib/db2_common.sh"

DBS="${*:-$(list_databases)}"
rows=""

for db in $DBS; do
    logf="$LOG_DIR/checkdb_${db}_$(date +%Y%m%d_%H%M%S).out"
    start=$(date +%s)
    if _db2_connect "$db"; then
        if db2 "INSPECT CHECK DATABASE RESULTS KEEP ${db}_inspect.out" >"$logf" 2>&1; then
            status="clean"
        else
            status="errors"
        fi
        db2 connect reset >/dev/null 2>&1 || true
    else
        status="failed"
    fi
    dur=$(( $(date +%s) - start ))
    rows+="${db}|${status}|${dur}|${logf}"$'\n'
done

result="$(printf '%s' "$rows" | python3 - <<'PY'
import json, sys, datetime
items, clean, errors, failed = [], 0, 0, 0
for line in sys.stdin.read().splitlines():
    if not line.strip(): continue
    db, status, dur, logf = (line.split('|') + ['']*4)[:4]
    if status == "clean": clean += 1
    elif status == "errors": errors += 1
    else: failed += 1
    items.append({"database": db, "status": status,
                  "duration_sec": int(dur or 0), "log": logf})
print(json.dumps({
    "timestamp": datetime.datetime.now().strftime("%Y-%m-%dT%H:%M:%S"),
    "total": len(items), "clean": clean, "errors": errors, "failed": failed,
    "items": items,
}))
PY
)"
write_status_file checkdb_status "$result"
printf '%s\n' "$result"
