#!/usr/bin/env bash
# PerformanceReview.sh [db ...] — read-only Db2 performance review:
# long-running SQL (MON_CURRENT_SQL), top statements by activity time
# (MON_GET_PKG_CACHE_STMT), current lock waits (MON_LOCKWAITS), and buffer-pool
# hit ratios (MON_GET_BUFFERPOOL). Emits one JSON line consumed by the chatbot,
# which summarizes it and proposes remediations.
#
# Final JSON: {"timestamp",
#   "long_running":[{database,handle,elapsed_sec,sql}],
#   "top_sql":[{database,executions,act_time_ms,sql}],
#   "blocking":[{database,blocker_handle,waiter_handle,wait_sec}],
#   "bufferpools":[{database,name,hit_ratio_pct}]}
source "$(dirname "$0")/lib/db2_common.sh"

LONG_SECONDS="${LONG_SECONDS:-5}"
TOPN="${TOPN:-10}"
DBS="${*:-$(list_databases)}"
rows=""

for db in $DBS; do
    rows+="$(printf '%s' "SELECT 'LONG|${db}|' || APPLICATION_HANDLE || '|' || COALESCE(ELAPSED_TIME_SEC,0) || '|' || SUBSTR(COALESCE(STMT_TEXT,' '),1,300) FROM SYSIBMADM.MON_CURRENT_SQL WHERE COALESCE(ELAPSED_TIME_SEC,0) >= ${LONG_SECONDS};" | sqlx "$db" 2>/dev/null)"$'\n'
    rows+="$(printf '%s' "SELECT 'TOP|${db}|' || NUM_EXECUTIONS || '|' || CAST(TOTAL_ACT_TIME AS BIGINT) || '|' || SUBSTR(STMT_TEXT,1,300) FROM TABLE(MON_GET_PKG_CACHE_STMT(NULL,NULL,NULL,-2)) ORDER BY TOTAL_ACT_TIME DESC FETCH FIRST ${TOPN} ROWS ONLY;" | sqlx "$db" 2>/dev/null)"$'\n'
    rows+="$(printf '%s' "SELECT 'BLOCK|${db}|' || HLD_APPLICATION_HANDLE || '|' || REQ_APPLICATION_HANDLE || '|' || CAST(LOCK_WAIT_ELAPSED_TIME AS BIGINT) FROM SYSIBMADM.MON_LOCKWAITS;" | sqlx "$db" 2>/dev/null)"$'\n'
    rows+="$(printf '%s' "SELECT 'BP|${db}|' || BP_NAME || '|' || CAST(CASE WHEN (POOL_DATA_L_READS+POOL_INDEX_L_READS)=0 THEN 100 ELSE 100*(POOL_DATA_L_READS+POOL_INDEX_L_READS-POOL_DATA_P_READS-POOL_INDEX_P_READS)/(POOL_DATA_L_READS+POOL_INDEX_L_READS) END AS DEC(5,1)) FROM TABLE(MON_GET_BUFFERPOOL('',-2));" | sqlx "$db" 2>/dev/null)"$'\n'
done

printf '%s' "$rows" | python3 - <<'PY'
import json, sys, datetime
long_r, top, block, bp = [], [], [], []
for line in sys.stdin.read().splitlines():
    line = line.strip()
    if not line or "|" not in line:
        continue
    tag = line.split("|", 1)[0]
    if tag == "LONG":
        _, db, h, el, sqlt = (line.split("|", 4) + [""]*5)[:5]
        long_r.append({"database": db, "handle": h, "elapsed_sec": el, "sql": sqlt})
    elif tag == "TOP":
        _, db, execs, act, sqlt = (line.split("|", 4) + [""]*5)[:5]
        top.append({"database": db, "executions": execs, "act_time_ms": act, "sql": sqlt})
    elif tag == "BLOCK":
        _, db, b, w, ws = (line.split("|", 4) + [""]*5)[:5]
        block.append({"database": db, "blocker_handle": b, "waiter_handle": w, "wait_sec": ws})
    elif tag == "BP":
        _, db, name, ratio = (line.split("|", 3) + [""]*4)[:4]
        bp.append({"database": db, "name": name.strip(), "hit_ratio_pct": ratio.strip()})
print(json.dumps({
    "timestamp": datetime.datetime.now().strftime("%Y-%m-%dT%H:%M:%S"),
    "long_running": long_r, "top_sql": top, "blocking": block, "bufferpools": bp,
}))
PY
