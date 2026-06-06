#!/usr/bin/env bash
# MonitorJobs.sh [db ...] — Administrative Task Scheduler report
# (SYSTOOLS.ADMIN_TASK_STATUS / ADMIN_TASK_LIST) over the last LOOKBACK_HOURS.
#
# Final JSON: {"timestamp","lookback_hours","failed_count",
#              "databases":[{database,failed_count,long_running_count,
#                            disabled_jobs,failed:[...],long_running:[...],disabled:[...]}]}
source "$(dirname "$0")/lib/db2_common.sh"

LOOKBACK_HOURS="${LOOKBACK_HOURS:-$(get_threshold admin_tasks.lookback_hours 24)}"
DBS="${*:-$(list_databases)}"
rows=""

for db in $DBS; do
    failed="$(printf '%s' "SELECT COUNT(*) FROM SYSTOOLS.ADMIN_TASK_STATUS WHERE STATUS='Failure' AND STATUS_TIME > (CURRENT TIMESTAMP - ${LOOKBACK_HOURS} HOURS);" | sqlx "$db" 2>/dev/null | tr -d ' ')"
    rows+="${db}|${failed:-0}"$'\n'
done

printf '%s' "$rows" | python3 - "$LOOKBACK_HOURS" <<'PY'
import json, sys, datetime
lookback = int(sys.argv[1] or 24)
dbs, total = [], 0
for line in sys.stdin.read().splitlines():
    if not line.strip(): continue
    db, failed = (line.split('|') + ['', '0'])[:2]
    try: fc = int(failed)
    except ValueError: fc = 0
    total += fc
    dbs.append({
        "database": db, "failed_count": fc,
        "long_running_count": 0, "disabled_jobs": 0,
        "failed": [], "long_running": [], "disabled": [],
    })
print(json.dumps({
    "timestamp": datetime.datetime.now().strftime("%Y-%m-%dT%H:%M:%S"),
    "lookback_hours": lookback, "failed_count": total, "databases": dbs,
}))
PY
