#!/usr/bin/env bash
# db2_backups_jobs.sh — CheckMK local check (10 min): last full-backup age and
# administrative-task failure count per DB. Output: <status> <item> <metrics> <text>
LIB="/opt/dba/scripts/lib/db2_common.sh"; [[ -f "$LIB" ]] || LIB="$(dirname "$0")/../../lib/db2_common.sh"
source "$LIB" 2>/dev/null || { echo "3 Db2_Backups - db2_common.sh not found"; exit 0; }

FULL_MAX_H="$(get_threshold backups.full_max_age_hours 24)"
FULL_CRIT_H=$(( FULL_MAX_H * 2 ))

for db in $(list_databases); do
    last_full="$(printf '%s' "SELECT MAX(START_TIME) FROM SYSIBMADM.DB_HISTORY WHERE OPERATION='B';" | sqlx "$db" 2>/dev/null | tr -d ' ')"
    age_h="$(python3 - "$last_full" <<'PY'
import sys, datetime
s = (sys.argv[1] or '').strip()
if len(s) < 14: print(""); raise SystemExit(0)
try:
    dt = datetime.datetime.strptime(s[:14], "%Y%m%d%H%M%S")
    print(int((datetime.datetime.now()-dt).total_seconds()//3600))
except ValueError:
    print("")
PY
)"
    if [[ -z "$age_h" ]]; then
        emit_checkmk 2 "Db2_Backup_Full_${db}" - "no full backup found in history for ${db}"
    else
        st=0; (( age_h >= FULL_MAX_H )) && st=1; (( age_h >= FULL_CRIT_H )) && st=2
        emit_checkmk "$st" "Db2_Backup_Full_${db}" "age_h=${age_h};${FULL_MAX_H};${FULL_CRIT_H}" "last full ${age_h}h ago"
    fi

    failed="$(printf '%s' "SELECT COUNT(*) FROM SYSTOOLS.ADMIN_TASK_STATUS WHERE STATUS='Failure' AND STATUS_TIME > (CURRENT TIMESTAMP - 24 HOURS);" | sqlx "$db" 2>/dev/null | tr -d ' ')"
    failed="${failed:-0}"
    st=0; (( failed >= 1 )) && st=1; (( failed >= 5 )) && st=2
    emit_checkmk "$st" "Db2_AdminTask_${db}" "failed=${failed};1;5" "${failed} admin-task failure(s) in 24h"
done
