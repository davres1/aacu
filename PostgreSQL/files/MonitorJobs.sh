#!/usr/bin/env bash
# MonitorJobs.sh [db ...] — scheduled-job report using the pg_cron extension.
# pg_cron is the PostgreSQL analog of MySQL EVENTS / Db2 Administrative Task
# Scheduler. If pg_cron is not installed, the output notes that. Job run history
# is read from cron.job_run_details for the configured lookback window.
#
# Final JSON: {"timestamp","lookback_hours","failed_count",
#              "databases":[{database,failed_count,long_running_count,
#                            disabled_jobs,failed:[...],long_running:[...],
#                            disabled:[...]}]}
source "$(dirname "$0")/lib/pg_common.sh"

LOOKBACK_HOURS="${LOOKBACK_HOURS:-$(get_threshold admin_tasks.lookback_hours 24)}"
LONG_RUN_MIN="${LONG_RUN_MIN:-$(get_threshold admin_tasks.long_run_min 30)}"
DBS="${*:-$(list_databases)}"
rows=""

for db in $DBS; do
    # Check if pg_cron extension is present.
    have_cron="$(scalar "$db" \
        "SELECT COUNT(*) FROM pg_extension WHERE extname='pg_cron'" 2>/dev/null || echo 0)"

    if [ "${have_cron:-0}" = "0" ]; then
        rows+="NOCRON|${db}"$'\n'
        continue
    fi

    # Fetch scheduled jobs.
    jobs="$(printf '%s\n' \
        "SELECT jobid::text, schedule, command, database, active::text
         FROM cron.job
         ORDER BY jobid;" \
        | sqlx "$db" 2>/dev/null)"

    # Fetch recent run details.
    runs="$(printf '%s\n' \
        "SELECT jobid::text,
                status,
                COALESCE(return_message, ''),
                EXTRACT(EPOCH FROM start_time)::bigint::text,
                EXTRACT(EPOCH FROM end_time)::bigint::text
         FROM cron.job_run_details
         WHERE start_time > now() - interval '${LOOKBACK_HOURS} hours'
         ORDER BY start_time DESC;" \
        | sqlx "$db" 2>/dev/null)"

    rows+="DB|${db}"$'\n'
    while IFS= read -r ln; do
        [[ -z "${ln// }" ]] && continue
        rows+="J|${db}|${ln}"$'\n'
    done <<< "$jobs"
    while IFS= read -r ln; do
        [[ -z "${ln// }" ]] && continue
        rows+="R|${db}|${ln}"$'\n'
    done <<< "$runs"
done

printf '%s' "$rows" | python3 - "$LOOKBACK_HOURS" "$LONG_RUN_MIN" <<'PY'
import json, sys, datetime
lookback = int(sys.argv[1] or 24)
long_min = int(sys.argv[2] or 30)
now = datetime.datetime.now()

# jobid -> job info
jobmap = {}   # db -> {jobs:{id:info}, runs:[...]}
order = []
nocron = []

for line in sys.stdin.read().splitlines():
    if not line.strip():
        continue
    parts = line.split('|')
    tag = parts[0]

    if tag == 'NOCRON':
        db = parts[1] if len(parts) > 1 else '?'
        nocron.append(db)
        continue

    if tag == 'DB':
        db = parts[1] if len(parts) > 1 else '?'
        if db not in jobmap:
            jobmap[db] = {"jobs": {}, "runs": []}
            order.append(db)
        continue

    if tag == 'J':
        # J|db|jobid|schedule|command|database|active
        f = (parts + ['']*7)[:7]
        db = f[1]
        if db not in jobmap:
            jobmap[db] = {"jobs": {}, "runs": []}
            order.append(db)
        jid = f[2]
        jobmap[db]["jobs"][jid] = {
            "jobid": jid, "schedule": f[3], "command": f[4],
            "database": f[5], "active": f[6].lower() == 'true',
        }
        continue

    if tag == 'R':
        # R|db|jobid|status|message|start_epoch|end_epoch
        f = (parts + ['']*7)[:7]
        db = f[1]
        if db not in jobmap:
            jobmap[db] = {"jobs": {}, "runs": []}
            order.append(db)
        try: start_epoch = int(f[5])
        except (ValueError, IndexError): start_epoch = 0
        try: end_epoch = int(f[6])
        except (ValueError, IndexError): end_epoch = 0
        duration_sec = max(end_epoch - start_epoch, 0) if end_epoch > 0 else 0
        jobmap[db]["runs"].append({
            "jobid": f[2], "status": f[3], "message": f[4],
            "duration_sec": duration_sec,
        })

databases, grand_failed = [], 0

# Handle databases with no pg_cron.
for db in nocron:
    databases.append({
        "database": db,
        "pg_cron": "not_installed",
        "failed_count": 0,
        "long_running_count": 0,
        "disabled_jobs": 0,
        "failed": [],
        "long_running": [],
        "disabled": [],
    })

for db in order:
    d = jobmap[db]
    failed, disabled, long_running = [], [], []

    for jid, job in d["jobs"].items():
        if not job["active"]:
            disabled.append({"jobid": jid, "schedule": job["schedule"],
                             "command": job["command"]})

    for run in d["runs"]:
        if run["status"] in ("failed", "error"):
            failed.append({
                "jobid": run["jobid"],
                "status": run["status"],
                "message": run["message"],
                "duration_sec": run["duration_sec"],
            })
        if run["duration_sec"] >= long_min * 60:
            long_running.append({
                "jobid": run["jobid"],
                "status": run["status"],
                "duration_sec": run["duration_sec"],
            })

    grand_failed += len(failed)
    databases.append({
        "database": db,
        "failed_count": len(failed),
        "long_running_count": len(long_running),
        "disabled_jobs": len(disabled),
        "failed": failed,
        "long_running": long_running,
        "disabled": disabled,
    })

print(json.dumps({
    "timestamp": now.strftime("%Y-%m-%dT%H:%M:%S"),
    "lookback_hours": lookback,
    "failed_count": grand_failed,
    "databases": databases,
}))
PY
