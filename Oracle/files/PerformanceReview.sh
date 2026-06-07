#!/usr/bin/env bash
# PerformanceReview.sh [db ...] — read-only Oracle performance review:
# long-running active sessions, top SQL by elapsed time, current blocking, and
# the top non-idle wait events. Emits one JSON line consumed by the chatbot,
# which summarizes it and proposes remediations.
#
# Final JSON: {"timestamp",
#   "long_running":[{database,sid,user,elapsed_sec,event,sql}],
#   "top_sql":[{database,sql_id,executions,elapsed_sec,cpu_sec,sql}],
#   "blocking":[{database,blocker_sid,waiter_sid,event,wait_sec}],
#   "waits":[{database,event,total_waits,time_sec}]}
source "$(dirname "$0")/lib/oracle_common.sh"

LONG_SECONDS="${LONG_SECONDS:-5}"
TOPN="${TOPN:-10}"
DBS="${*:-$(list_databases)}"
rows=""

for db in $DBS; do
    rows+="$(printf '%s' "SELECT 'LONG|${db}|'||s.sid||'|'||s.username||'|'||s.last_call_et||'|'||NVL(s.event,'?')||'|'||SUBSTR(NVL(q.sql_text,' '),1,300) FROM v\$session s LEFT JOIN v\$sql q ON s.sql_id=q.sql_id WHERE s.status='ACTIVE' AND s.type='USER' AND s.last_call_et>=${LONG_SECONDS};" | sql "$db" 2>/dev/null)"$'\n'
    rows+="$(printf '%s' "SELECT * FROM (SELECT 'TOP|${db}|'||sql_id||'|'||executions||'|'||ROUND(elapsed_time/1000000,2)||'|'||ROUND(cpu_time/1000000,2)||'|'||SUBSTR(sql_text,1,300) FROM v\$sql ORDER BY elapsed_time DESC) WHERE ROWNUM<=${TOPN};" | sql "$db" 2>/dev/null)"$'\n'
    rows+="$(printf '%s' "SELECT 'BLOCK|${db}|'||blocking_session||'|'||sid||'|'||NVL(event,'?')||'|'||seconds_in_wait FROM v\$session WHERE blocking_session IS NOT NULL;" | sql "$db" 2>/dev/null)"$'\n'
    rows+="$(printf '%s' "SELECT * FROM (SELECT 'WAIT|${db}|'||event||'|'||total_waits||'|'||ROUND(time_waited_micro/1000000,2) FROM v\$system_event WHERE wait_class<>'Idle' ORDER BY time_waited_micro DESC) WHERE ROWNUM<=${TOPN};" | sql "$db" 2>/dev/null)"$'\n'
done

printf '%s' "$rows" | python3 - <<'PY'
import json, sys, datetime
long_r, top, block, wait = [], [], [], []
for line in sys.stdin.read().splitlines():
    line = line.strip()
    if not line or "|" not in line:
        continue
    tag = line.split("|", 1)[0]
    if tag == "LONG":
        _, db, sid, user, el, ev, sqlt = (line.split("|", 6) + [""]*7)[:7]
        long_r.append({"database": db, "sid": sid, "user": user,
                       "elapsed_sec": el, "event": ev, "sql": sqlt})
    elif tag == "TOP":
        _, db, sid, execs, el, cpu, sqlt = (line.split("|", 6) + [""]*7)[:7]
        top.append({"database": db, "sql_id": sid, "executions": execs,
                    "elapsed_sec": el, "cpu_sec": cpu, "sql": sqlt})
    elif tag == "BLOCK":
        _, db, b, w, ev, ws = (line.split("|", 5) + [""]*6)[:6]
        block.append({"database": db, "blocker_sid": b, "waiter_sid": w,
                      "event": ev, "wait_sec": ws})
    elif tag == "WAIT":
        _, db, ev, n, t = (line.split("|", 4) + [""]*5)[:5]
        wait.append({"database": db, "event": ev, "total_waits": n, "time_sec": t})
print(json.dumps({
    "timestamp": datetime.datetime.now().strftime("%Y-%m-%dT%H:%M:%S"),
    "long_running": long_r, "top_sql": top, "blocking": block, "waits": wait,
}))
PY
