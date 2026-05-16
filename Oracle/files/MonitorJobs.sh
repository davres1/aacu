#!/usr/bin/env bash
# MonitorJobs.sh — Oracle equivalent of MonitorAgentJobs.ps1.
# Reports failed / long-running DBA_SCHEDULER + DBMS_JOB executions in the
# last $LOOKBACK_HOURS.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/oracle_common.sh"

LOOKBACK_HOURS="${LOOKBACK_HOURS:-24}"
LONG_MINUTES="${LONG_MINUTES:-60}"
report='[]'

databases=("$@")
[[ ${#databases[@]} -eq 0 ]] && mapfile -t databases < <(list_databases)

for db in "${databases[@]}"; do
    log "→ $db"
    rows=$(sql "$db" <<SQL 2>/dev/null || true
SELECT '__FAIL__|' || owner || '|' || job_name || '|' ||
       TO_CHAR(actual_start_date, 'YYYY-MM-DD HH24:MI:SS') || '|' ||
       ROUND(EXTRACT(SECOND FROM run_duration) + EXTRACT(MINUTE FROM run_duration)*60) || '|' ||
       NVL(error#, 0) || '|' || NVL(SUBSTR(additional_info, 1, 200), '')
  FROM dba_scheduler_job_run_details
 WHERE status IN ('FAILED','STOPPED')
   AND actual_start_date > SYSDATE - $LOOKBACK_HOURS/24;

SELECT '__LONG__|' || owner || '|' || job_name || '|' ||
       TO_CHAR(actual_start_date, 'YYYY-MM-DD HH24:MI:SS') || '|' ||
       ROUND((EXTRACT(SECOND FROM run_duration) + EXTRACT(MINUTE FROM run_duration)*60 + EXTRACT(HOUR FROM run_duration)*3600) / 60, 1)
  FROM dba_scheduler_job_run_details
 WHERE status = 'SUCCEEDED'
   AND actual_start_date > SYSDATE - $LOOKBACK_HOURS/24
   AND EXTRACT(SECOND FROM run_duration) + EXTRACT(MINUTE FROM run_duration)*60 + EXTRACT(HOUR FROM run_duration)*3600 > $LONG_MINUTES*60;

SELECT '__DISABLED__|' || owner || '|' || job_name
  FROM dba_scheduler_jobs
 WHERE enabled = 'FALSE'
   AND owner NOT IN ('SYS','SYSTEM','XDB','MDSYS','CTXSYS','APEX_PUBLIC_USER');
SQL
)

    failed='[]'; long='[]'; disabled='[]'
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        if [[ "$line" == __FAIL__* ]]; then
            IFS='|' read -r _ own name when dur_s errno msg <<<"$line"
            row=$(python3 -c "
import json
print(json.dumps({'owner':'$own','job':'$name','run_date':'$when',
                  'duration_sec':int('$dur_s' or 0),'error_code':int('$errno' or 0),
                  'message':'$msg'.strip()}))")
            failed=$(python3 -c "import json; r=json.loads('''$failed'''); r.append(json.loads('''$row''')); print(json.dumps(r))")
        elif [[ "$line" == __LONG__* ]]; then
            IFS='|' read -r _ own name when dur_min <<<"$line"
            row=$(python3 -c "
import json
print(json.dumps({'owner':'$own','job':'$name','run_date':'$when','duration_min':float('$dur_min')}))")
            long=$(python3 -c "import json; r=json.loads('''$long'''); r.append(json.loads('''$row''')); print(json.dumps(r))")
        elif [[ "$line" == __DISABLED__* ]]; then
            IFS='|' read -r _ own name <<<"$line"
            row=$(python3 -c "
import json
print(json.dumps({'owner':'$own','job':'$name'}))")
            disabled=$(python3 -c "import json; r=json.loads('''$disabled'''); r.append(json.loads('''$row''')); print(json.dumps(r))")
        fi
    done <<<"$rows"

    db_entry=$(python3 -c "
import json
fl, lo, di = json.loads('''$failed'''), json.loads('''$long'''), json.loads('''$disabled''')
print(json.dumps({'database':'$db','failed':fl,'long_running':lo,'disabled':di,
                  'failed_count':len(fl),'long_running_count':len(lo),'disabled_jobs':len(di)}))")
    report=$(python3 -c "import json; r=json.loads('''$report'''); r.append(json.loads('''$db_entry''')); print(json.dumps(r))")
done

total_failed=$(python3 -c "import json; print(sum(x['failed_count'] for x in json.loads('''$report''')))")
summary="{\"timestamp\":\"$(ts)\",\"lookback_hours\":$LOOKBACK_HOURS,\"failed_count\":$total_failed,\"databases\":$report}"
write_status_file "jobs" "$summary"
echo "$summary"
log "=== MonitorJobs failed=$total_failed in ${LOOKBACK_HOURS}h ==="
exit $(( total_failed > 0 ? 1 : 0 ))
