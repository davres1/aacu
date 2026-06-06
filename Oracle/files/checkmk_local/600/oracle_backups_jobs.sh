#!/usr/bin/env bash
# CheckMK local plugin (10 min) — backup age + scheduler job failures per DB.

set -uo pipefail
LIB="${ORACLE_DBA_LIB:-/opt/dba/scripts/lib/oracle_common.sh}"
[[ -f "$LIB" ]] && source "$LIB" || { echo "3 Oracle_Backups - UNKNOWN - $LIB not found"; exit 0; }

FULL_WARN=$(get_threshold backups.full_max_age_hours 30)
FULL_CRIT=$(get_threshold backups.full_crit_age_hours 48)
LOG_WARN=$(get_threshold backups.log_max_age_hours 2)
LOG_CRIT=$(get_threshold backups.log_crit_age_hours 6)
JOB_LOOKBACK=$(get_threshold agent_jobs.lookback_hours 24)

for db in $(list_databases); do
    if ! db_credentials "$db" >/dev/null 2>&1; then continue; fi

    # Backup ages
    blob=$(sql "$db" <<SQL 2>/dev/null
SELECT '__FULL__|' ||
       NVL(TO_CHAR(MAX(end_time),'YYYY-MM-DD HH24:MI:SS'), '1900-01-01 00:00:00')
  FROM v\$rman_backup_job_details
 WHERE input_type IN ('DB FULL','DB INCR') AND status='COMPLETED';
SELECT '__LOG__|' ||
       NVL(TO_CHAR(MAX(end_time),'YYYY-MM-DD HH24:MI:SS'), '1900-01-01 00:00:00')
  FROM v\$rman_backup_job_details
 WHERE input_type='ARCHIVELOG' AND status='COMPLETED';
SELECT '__JOBS__|' ||
       COUNT(CASE WHEN status IN ('FAILED','STOPPED') THEN 1 END) || '|' ||
       COUNT(*)
  FROM dba_scheduler_job_run_details
 WHERE actual_start_date > SYSDATE - $JOB_LOOKBACK/24;
SQL
)
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        if [[ "$line" == __FULL__* ]]; then
            when="${line#__FULL__|}"
            ageh=$(python3 -c "
from datetime import datetime
try: dt = datetime.strptime('$when', '%Y-%m-%d %H:%M:%S')
except Exception: print(999999);
else: print(round((datetime.now()-dt).total_seconds()/3600,1))" 2>/dev/null || echo 999999)
            sev=0
            ageh_int=$(printf '%.0f' "$ageh")
            (( ageh_int >= FULL_CRIT )) && sev=2
            (( ageh_int >= FULL_WARN && ageh_int < FULL_CRIT )) && sev=1
            emit_checkmk $sev "Oracle_Backup_Full_$db" "age_h=$ageh;$FULL_WARN;$FULL_CRIT" "last full $ageh h ago"
        elif [[ "$line" == __LOG__* ]]; then
            when="${line#__LOG__|}"
            ageh=$(python3 -c "
from datetime import datetime
try: dt = datetime.strptime('$when', '%Y-%m-%d %H:%M:%S')
except Exception: print(999999)
else: print(round((datetime.now()-dt).total_seconds()/3600,1))" 2>/dev/null || echo 999999)
            sev=0
            ageh_int=$(printf '%.0f' "$ageh")
            (( ageh_int >= LOG_CRIT )) && sev=2
            (( ageh_int >= LOG_WARN && ageh_int < LOG_CRIT )) && sev=1
            emit_checkmk $sev "Oracle_Backup_Log_$db" "age_h=$ageh;$LOG_WARN;$LOG_CRIT" "last log $ageh h ago"
        elif [[ "$line" == __JOBS__* ]]; then
            IFS='|' read -r _ failed total <<<"$line"
            sev=0
            (( failed >= 5 )) && sev=2
            (( failed >= 1 && failed < 5 )) && sev=1
            emit_checkmk $sev "Oracle_Jobs_$db" "failed=$failed;1;5|total=$total" "$failed failed of $total job runs in ${JOB_LOOKBACK}h"
        fi
    done <<<"$blob"
done
