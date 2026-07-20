#!/usr/bin/env bash
# PerformanceReview.sh [db ...] — read-only MySQL/MariaDB performance review.
# Long-running statements (information_schema.PROCESSLIST), top statements by
# accumulated latency (performance_schema.events_statements_summary_by_digest),
# current lock waits (sys.innodb_lock_waits), InnoDB buffer-pool hit ratio, and
# base tables missing a primary key. Emits one flat JSON line for the chatbot.
#
# Final JSON: {"timestamp",
#   "long_running":[{database,pid,elapsed_sec,sql}],
#   "top_sql":[{database,executions,act_time_ms,sql}],
#   "blocking":[{database,blocker_pid,waiter_pid,wait_sec}],
#   "waits":[{database,name,hit_ratio_pct}],
#   "missing_indexes":[{database,schema,table,reason}]}
source "$(dirname "$0")/lib/mysql_common.sh"

LONG_SECONDS="${LONG_SECONDS:-5}"
TOPN="${TOPN:-10}"
DBS="${*:-$(list_databases)}"
rows=""

for db in $DBS; do
    rows+="$(printf '%s' "SELECT CONCAT_WS('|','LONG','${db}',ID,COALESCE(TIME,0),REPLACE(REPLACE(SUBSTRING(COALESCE(INFO,''),1,300),'\n',' '),'|',' ')) FROM information_schema.PROCESSLIST WHERE COMMAND NOT IN ('Sleep','Daemon') AND INFO IS NOT NULL AND TIME >= ${LONG_SECONDS};" | sqlx "$db" 2>/dev/null)"$'\n'
    rows+="$(printf '%s' "SELECT CONCAT_WS('|','TOP','${db}',COUNT_STAR,ROUND(SUM_TIMER_WAIT/1000000000,0),REPLACE(REPLACE(SUBSTRING(COALESCE(DIGEST_TEXT,''),1,300),'\n',' '),'|',' ')) FROM performance_schema.events_statements_summary_by_digest WHERE DIGEST_TEXT IS NOT NULL ORDER BY SUM_TIMER_WAIT DESC LIMIT ${TOPN};" | sqlx "$db" 2>/dev/null)"$'\n'
    rows+="$(printf '%s' "SELECT CONCAT_WS('|','BLOCK','${db}',blocking_pid,waiting_pid,COALESCE(wait_age_secs,0)) FROM sys.innodb_lock_waits;" | sqlx "$db" 2>/dev/null)"$'\n'
    rows+="$(printf '%s' "SELECT CONCAT_WS('|','WAIT','${db}','innodb_buffer_pool',ROUND(100*(1-(reads/GREATEST(rr,1))),2)) FROM (SELECT MAX(IF(VARIABLE_NAME='Innodb_buffer_pool_reads',VARIABLE_VALUE,0)) AS reads, MAX(IF(VARIABLE_NAME='Innodb_buffer_pool_read_requests',VARIABLE_VALUE,0)) AS rr FROM performance_schema.global_status WHERE VARIABLE_NAME IN ('Innodb_buffer_pool_reads','Innodb_buffer_pool_read_requests')) t;" | sqlx "$db" 2>/dev/null)"$'\n'
    rows+="$(printf '%s' "SELECT CONCAT_WS('|','MISS','${db}',t.TABLE_SCHEMA,t.TABLE_NAME,'no primary key') FROM information_schema.TABLES t LEFT JOIN information_schema.TABLE_CONSTRAINTS c ON c.TABLE_SCHEMA=t.TABLE_SCHEMA AND c.TABLE_NAME=t.TABLE_NAME AND c.CONSTRAINT_TYPE='PRIMARY KEY' WHERE t.TABLE_TYPE='BASE TABLE' AND t.TABLE_SCHEMA NOT IN ('mysql','information_schema','performance_schema','sys') AND c.CONSTRAINT_NAME IS NULL;" | sqlx "$db" 2>/dev/null)"$'\n'
done

printf '%s' "$rows" | python3 - <<'PY'
import json, sys, datetime
long_r, top, block, waits, miss = [], [], [], [], []
for line in sys.stdin.read().splitlines():
    line = line.rstrip()
    if not line or "|" not in line:
        continue
    tag = line.split("|", 1)[0]
    if tag == "LONG":
        _, db, pid, el, sqlt = (line.split("|", 4) + [""]*5)[:5]
        long_r.append({"database": db, "pid": pid, "elapsed_sec": el, "sql": sqlt})
    elif tag == "TOP":
        _, db, execs, act, sqlt = (line.split("|", 4) + [""]*5)[:5]
        top.append({"database": db, "executions": execs, "act_time_ms": act, "sql": sqlt})
    elif tag == "BLOCK":
        _, db, b, w, ws = (line.split("|", 4) + [""]*5)[:5]
        block.append({"database": db, "blocker_pid": b, "waiter_pid": w, "wait_sec": ws})
    elif tag == "WAIT":
        _, db, name, ratio = (line.split("|", 3) + [""]*4)[:4]
        waits.append({"database": db, "name": name.strip(), "hit_ratio_pct": ratio.strip()})
    elif tag == "MISS":
        _, db, sch, tbl, reason = (line.split("|", 4) + [""]*5)[:5]
        miss.append({"database": db, "schema": sch, "table": tbl, "reason": reason})
print(json.dumps({
    "timestamp": datetime.datetime.now().strftime("%Y-%m-%dT%H:%M:%S"),
    "long_running": long_r, "top_sql": top, "blocking": block,
    "waits": waits, "missing_indexes": miss,
}))
PY
