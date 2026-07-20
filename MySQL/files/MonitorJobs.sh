#!/usr/bin/env bash
# MonitorJobs.sh [db ...] — scheduled-job report, ported from the Db2
# Administrative Task Scheduler monitor. Db2 jobs map to MySQL EVENTS
# (information_schema.EVENTS + mysql.event). MySQL does not record per-run
# success/failure in a catalog, so the buckets are derived as:
#   * disabled     — STATUS in (DISABLED, SLAVESIDE_DISABLED), or event
#                    scheduler globally OFF (all enabled events are dead).
#   * failed       — enabled but overdue: never executed though STARTS is in
#                    the past, or LAST_EXECUTED older than its interval/lookback
#                    (a proxy for a failed/mis-firing job).
#   * long_running — an event currently executing longer than LONG_RUN_MIN
#                    minutes (best-effort, via performance_schema).
#
# Final JSON: {"timestamp","lookback_hours","failed_count",
#              "databases":[{database,failed_count,long_running_count,
#                            disabled_jobs,failed:[...],long_running:[...],
#                            disabled:[...]}]}
source "$(dirname "$0")/lib/mysql_common.sh"

LOOKBACK_HOURS="${LOOKBACK_HOURS:-$(get_threshold admin_tasks.lookback_hours 24)}"
LONG_RUN_MIN="${LONG_RUN_MIN:-$(get_threshold admin_tasks.long_run_min 30)}"
DBS="${*:-$(list_databases)}"
rows=""

for db in $DBS; do
    sched="$(scalar "$db" "SELECT VARIABLE_VALUE FROM performance_schema.global_variables WHERE VARIABLE_NAME='event_scheduler'")"
    [[ -z "$sched" ]] && sched="$(scalar "$db" "SELECT @@event_scheduler")"

    # One row per event:  E|schema|name|status|last_executed|starts|iv_val|iv_field
    events="$(printf '%s' "SELECT CONCAT_WS('\t','E',
                EVENT_SCHEMA, EVENT_NAME, STATUS,
                COALESCE(DATE_FORMAT(LAST_EXECUTED,'%Y-%m-%dT%H:%i:%s'),''),
                COALESCE(DATE_FORMAT(STARTS,'%Y-%m-%dT%H:%i:%s'),''),
                COALESCE(INTERVAL_VALUE,''),
                COALESCE(INTERVAL_FIELD,''))
              FROM information_schema.EVENTS
              WHERE EVENT_SCHEMA = DATABASE();" | sqlx "$db" 2>/dev/null)"

    # Currently-executing events (best-effort). Event worker threads run under
    # NAME 'thread/sql/event_worker'; join the in-flight statement for elapsed.
    longs="$(printf '%s' "SELECT CONCAT_WS('\t','L',
                COALESCE(t.PROCESSLIST_ID,0),
                CAST(ROUND(COALESCE(s.TIMER_WAIT,0)/1000000000000) AS SIGNED),
                COALESCE(SUBSTRING(s.SQL_TEXT,1,120),''))
              FROM performance_schema.threads t
              JOIN performance_schema.events_statements_current s
                ON s.THREAD_ID = t.THREAD_ID
              WHERE t.NAME LIKE '%event_worker%';" | sqlx "$db" 2>/dev/null)"

    rows+="D|${db}|${sched:-UNKNOWN}"$'\n'
    while IFS= read -r ln; do
        [[ -z "${ln// }" ]] && continue
        rows+="${db}|${ln}"$'\n'
    done <<< "$events"
    while IFS= read -r ln; do
        [[ -z "${ln// }" ]] && continue
        rows+="${db}|${ln}"$'\n'
    done <<< "$longs"
done

printf '%s' "$rows" | python3 - "$LOOKBACK_HOURS" "$LONG_RUN_MIN" <<'PY'
import json, sys, datetime
lookback = int(sys.argv[1] or 24)
long_min = int(sys.argv[2] or 30)
now = datetime.datetime.now()

# seconds per interval unit (approximate for month/year — good enough for overdue)
UNIT = {"SECOND":1,"MINUTE":60,"HOUR":3600,"DAY":86400,"WEEK":604800,
        "MONTH":2592000,"YEAR":31536000,"QUARTER":7776000}

def parse_dt(s):
    s = (s or '').strip()
    if not s:
        return None
    try:
        return datetime.datetime.strptime(s, "%Y-%m-%dT%H:%M:%S")
    except ValueError:
        return None

def interval_secs(val, field):
    try:
        n = int(val)
    except (ValueError, TypeError):
        return None
    f = (field or '').upper()
    # INTERVAL_FIELD can be compound like DAY_HOUR; use the leading unit.
    for u in ("SECOND","MINUTE","HOUR","DAY","WEEK","MONTH","QUARTER","YEAR"):
        if f.startswith(u):
            return n * UNIT[u]
    return None

dbmap = {}       # db -> {sched, events:[...], longs:[...]}
order = []
for line in sys.stdin.read().splitlines():
    if not line.strip():
        continue
    parts = line.split('|')
    kind = parts[1] if parts[0] not in ('D',) else 'D'
    if parts[0] == 'D':
        _, db, sched = (parts + ['']*3)[:3]
        if db not in dbmap:
            dbmap[db] = {"sched": sched, "events": [], "longs": []}
            order.append(db)
        else:
            dbmap[db]["sched"] = sched
        continue
    db = parts[0]
    d = dbmap.setdefault(db, {"sched": "UNKNOWN", "events": [], "longs": []})
    if db not in order:
        order.append(db)
    if parts[1] == 'E':
        # db | E | schema | name | status | last_exec | starts | iv_val | iv_field
        f = (parts + ['']*9)[:9]
        d["events"].append({
            "schema": f[2], "name": f[3], "status": f[4],
            "last_executed": f[5], "starts": f[6],
            "iv_val": f[7], "iv_field": f[8],
        })
    elif parts[1] == 'L':
        f = (parts + ['']*5)[:5]
        try:
            secs = int(f[3] or 0)
        except ValueError:
            secs = 0
        d["longs"].append({"pid": f[2], "seconds": secs, "sql": f[4]})

databases, grand_failed = [], 0
for db in order:
    d = dbmap[db]
    sched_off = (d["sched"] or "").upper() in ("OFF", "0")
    failed, disabled = [], []
    for ev in d["events"]:
        st = (ev["status"] or "").upper()
        if st != "ENABLED":
            disabled.append({"event": ev["name"], "schema": ev["schema"],
                             "status": ev["status"]})
            continue
        # enabled event — is it overdue / dead?
        reason = None
        if sched_off:
            reason = "event_scheduler OFF"
        else:
            last = parse_dt(ev["last_executed"])
            starts = parse_dt(ev["starts"])
            isecs = interval_secs(ev["iv_val"], ev["iv_field"])
            if last is None:
                if starts is not None and starts < now - datetime.timedelta(hours=lookback):
                    reason = "never executed since %s" % ev["starts"]
            elif isecs is not None:
                # overdue if it missed its next slot by more than one interval
                if (now - last).total_seconds() > 2 * isecs:
                    reason = "last run %s (interval %ss)" % (ev["last_executed"], isecs)
            elif (now - last).total_seconds() > lookback * 3600:
                reason = "last run %s" % ev["last_executed"]
        if reason:
            failed.append({"event": ev["name"], "schema": ev["schema"],
                           "last_executed": ev["last_executed"], "reason": reason})
    long_running = [x for x in d["longs"] if x["seconds"] >= long_min * 60]
    long_running = [{"event": "(running)", "pid": x["pid"],
                     "seconds": x["seconds"], "sql": x["sql"]} for x in long_running]
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
