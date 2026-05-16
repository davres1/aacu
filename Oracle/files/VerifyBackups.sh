#!/usr/bin/env bash
# VerifyBackups.sh — RMAN VALIDATE on the last good backup of each DB + age
# check. Emits a JSON summary and a status file consumed by CheckMK.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/oracle_common.sh"

FULL_MAX_AGE_H="${FULL_MAX_AGE_H:-30}"
LOG_MAX_AGE_H="${LOG_MAX_AGE_H:-2}"
report='[]'

databases=("$@")
[[ ${#databases[@]} -eq 0 ]] && mapfile -t databases < <(list_databases)

for db in "${databases[@]}"; do
    log "→ $db"
    # Pull last full + last archive log timestamp from v$rman_backup_job_details.
    ages=$(sql "$db" sys <<'SQL' 2>/dev/null || true
SELECT '__FULL__|' ||
       TO_CHAR(NVL(MAX(end_time), TO_DATE('1900-01-01','YYYY-MM-DD')),
               'YYYY-MM-DD"T"HH24:MI:SS')
  FROM v$rman_backup_job_details
 WHERE input_type IN ('DB FULL','DB INCR')
   AND status = 'COMPLETED';
SELECT '__LOG__|' ||
       TO_CHAR(NVL(MAX(end_time), TO_DATE('1900-01-01','YYYY-MM-DD')),
               'YYYY-MM-DD"T"HH24:MI:SS')
  FROM v$rman_backup_job_details
 WHERE input_type = 'ARCHIVELOG'
   AND status = 'COMPLETED';
SQL
)
    last_full=$(echo "$ages" | awk -F'\\|' '/__FULL__/{print $2}' | tr -d '[:space:]')
    last_log=$(echo  "$ages" | awk -F'\\|' '/__LOG__/{print $2}'  | tr -d '[:space:]')

    full_age_h=$(python3 -c "
import sys
from datetime import datetime
try: dt = datetime.strptime('$last_full', '%Y-%m-%dT%H:%M:%S')
except Exception: print(999999); sys.exit(0)
print(round((datetime.now() - dt).total_seconds() / 3600, 1))
" 2>/dev/null || echo "999999")
    log_age_h=$(python3 -c "
import sys
from datetime import datetime
try: dt = datetime.strptime('$last_log', '%Y-%m-%dT%H:%M:%S')
except Exception: print(999999); sys.exit(0)
print(round((datetime.now() - dt).total_seconds() / 3600, 1))
" 2>/dev/null || echo "999999")

    full_stale=$(python3 -c "print(1 if $full_age_h > $FULL_MAX_AGE_H else 0)")
    log_stale=$(python3 -c "print(1 if $log_age_h > $LOG_MAX_AGE_H else 0)")

    # RMAN VALIDATE the last full backupset (fast: header-only check by default).
    verified="unknown"
    creds=$(db_credentials "$db" sys 2>/dev/null || echo "")
    if [[ -n "$creds" ]]; then
        u="${creds%% *}"; p="${creds#* }"
        if rman target "$u/$p@$db AS SYSDBA" log="$LOG_DIR/rmanvalidate_${db}_$(date +%Y%m%d_%H%M%S).log" >>"$LOG_FILE" 2>&1 <<'RMAN'
VALIDATE BACKUPSET COMPLETED AFTER 'SYSDATE-7';
RMAN
        then verified="ok"
        else verified="failed"
        fi
    fi

    item=$(python3 -c "
import json
print(json.dumps({
    'database':'$db', 'last_full': '$last_full', 'last_log': '$last_log',
    'full_age_h': float('$full_age_h'), 'log_age_h': float('$log_age_h'),
    'full_stale': bool($full_stale), 'log_stale': bool($log_stale),
    'verified': '$verified',
}))")
    report=$(python3 -c "import json; r=json.loads('''$report'''); r.append(json.loads('''$item''')); print(json.dumps(r))")

    [[ $full_stale -eq 1 ]] && warn "STALE full $db: ${full_age_h}h"
    [[ $log_stale -eq 1 ]] && warn "STALE log $db: ${log_age_h}h"
done

stale_full=$(python3 -c "import json; print(sum(1 for x in json.loads('''$report''') if x['full_stale']))")
stale_log=$(python3 -c "import json; print(sum(1 for x in json.loads('''$report''')  if x['log_stale']))")
verify_failed=$(python3 -c "import json; print(sum(1 for x in json.loads('''$report''') if x['verified'] == 'failed'))")

summary=$(python3 -c "
import json
print(json.dumps({
  'timestamp': '$(ts)',
  'stale_full': $stale_full,
  'stale_log':  $stale_log,
  'verify_failed': $verify_failed,
  'items': json.loads('''$report'''),
}))")
write_status_file "verify_backups" "$summary"
echo "$summary"
log "=== VerifyBackups stale_full=$stale_full stale_log=$stale_log failed=$verify_failed ==="
exit $(( stale_full + stale_log + verify_failed > 0 ? 1 : 0 ))
