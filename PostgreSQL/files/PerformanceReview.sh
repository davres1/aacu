#!/usr/bin/env bash
# PerformanceReview.sh [db ...] — read-only PostgreSQL performance review.
# Long-running queries (pg_stat_activity), top SQL by total execution time
# (pg_stat_statements), current lock waits (pg_locks + pg_stat_activity),
# buffer cache hit ratio (pg_statio_user_tables), and tables missing a primary
# key. Emits one flat JSON line for the chatbot.
#
# Final JSON: {"timestamp",
#   "long_running":[{database,pid,elapsed_sec,sql}],
#   "top_sql":[{database,executions,act_time_ms,sql}],
#   "blocking":[{database,blocker_pid,waiter_pid,wait_sec}],
#   "waits":[{database,name,hit_ratio_pct}],
#   "missing_indexes":[{database,schema,table,reason}]}
source "$(dirname "$0")/lib/pg_common.sh"

LONG_SECONDS="${LONG_SECONDS:-5}"
TOPN="${TOPN:-10}"
DBS="${*:-$(list_databases)}"
rows=""

for db in $DBS; do
    # Long-running active queries.
    rows+="$(printf '%s\n' \
        "SELECT 'LONG'||'|'||'${db}'||'|'||pid::text||'|'||
                EXTRACT(EPOCH FROM (now()-query_start))::int::text||'|'||
                REPLACE(REPLACE(SUBSTRING(COALESCE(query,''),1,300),E'\n',' '),'|',' ')
         FROM pg_stat_activity
         WHERE state = 'active'
           AND query_start < now() - interval '${LONG_SECONDS} seconds'
           AND pid <> pg_backend_pid();" \
        | sqlx "$db" 2>/dev/null)"$'\n'

    # Top SQL by total execution time (pg_stat_statements if available).
    have_ss="$(scalar "$db" \
        "SELECT COUNT(*) FROM pg_extension WHERE extname='pg_stat_statements'" 2>/dev/null || echo 0)"
    if [ "${have_ss:-0}" = "1" ]; then
        rows+="$(printf '%s\n' \
            "SELECT 'TOP'||'|'||'${db}'||'|'||calls::text||'|'||
                    ROUND(total_exec_time)::text||'|'||
                    REPLACE(REPLACE(SUBSTRING(COALESCE(query,''),1,300),E'\n',' '),'|',' ')
             FROM pg_stat_statements
             WHERE dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
             ORDER BY total_exec_time DESC
             LIMIT ${TOPN};" \
            | sqlx "$db" 2>/dev/null)"$'\n'
    fi

    # Current lock waits.
    rows+="$(printf '%s\n' \
        "SELECT 'BLOCK'||'|'||'${db}'||'|'||blocking.pid::text||'|'||
                blocked.pid::text||'|'||
                EXTRACT(EPOCH FROM (now()-blocked_act.query_start))::int::text
         FROM pg_locks blocked
         JOIN pg_stat_activity blocked_act ON blocked_act.pid = blocked.pid
         JOIN pg_locks blocking
             ON blocking.locktype = blocked.locktype
             AND blocking.database IS NOT DISTINCT FROM blocked.database
             AND blocking.relation IS NOT DISTINCT FROM blocked.relation
             AND blocking.pid != blocked.pid
             AND blocking.granted
         WHERE NOT blocked.granted
         LIMIT 20;" \
        | sqlx "$db" 2>/dev/null)"$'\n'

    # Buffer cache hit ratio.
    rows+="$(printf '%s\n' \
        "SELECT 'WAIT'||'|'||'${db}'||'|''shared_buffers_hit_ratio'||'|'||
                ROUND(100.0 * SUM(heap_blks_hit) /
                      NULLIF(SUM(heap_blks_hit) + SUM(heap_blks_read), 0), 2)::text
         FROM pg_statio_user_tables;" \
        | sqlx "$db" 2>/dev/null)"$'\n'

    # Tables missing a primary key.
    rows+="$(printf '%s\n' \
        "SELECT 'MISS'||'|'||'${db}'||'|'||schemaname||'|'||tablename||'|''no primary key'
         FROM pg_tables
         WHERE schemaname NOT IN ('pg_catalog','information_schema','pg_toast')
           AND tablename NOT IN (
               SELECT conrelid::regclass::text
               FROM pg_constraint
               WHERE contype = 'p'
           )
         LIMIT 50;" \
        | sqlx "$db" 2>/dev/null)"$'\n'
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
