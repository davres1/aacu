#!/usr/bin/env bash
# pg_backups_jobs.sh — CheckMK local check (10 min): age of the newest backup
# artifact per database, and failed pg_cron job runs (if pg_cron is installed).
# Output: <status> <item> <metrics> <text>
LIB="/opt/dba/scripts/lib/pg_common.sh"
[[ -f "$LIB" ]] || LIB="$(dirname "$0")/../../lib/pg_common.sh"
source "$LIB" 2>/dev/null || { echo "3 PostgreSQL_Backups - pg_common.sh not found"; exit 0; }

FULL_MAX_H="$(get_threshold backups.full_max_age_hours 24)"
FULL_CRIT_H=$(( FULL_MAX_H * 2 ))
BACKUP_ROOT="${BACKUP_ROOT:-/backup/postgresql}"

for db in $(list_databases); do
    # --- Last backup age: newest file under the database's backup directory ---
    bdir="$(db_section_value "$db" backupdir 2>/dev/null)"
    [[ -z "$bdir" ]] && bdir="$BACKUP_ROOT/$db"
    newest=""
    if [[ -d "$bdir" ]]; then
        newest="$(find "$bdir" -type f \
            \( -name '*.dump' -o -name '*.sql.gz' -o -name '*.tar.gz' \) \
            -printf '%T@\n' 2>/dev/null | sort -nr | head -1)"
    fi

    if [[ -z "$newest" ]]; then
        emit_checkmk 2 "PG_Backup_Full_${db}" - \
            "no backup file found for ${db} under ${bdir}"
    else
        age_h=$(( ( $(date +%s) - ${newest%.*} ) / 3600 ))
        st=0
        (( age_h >= FULL_MAX_H )) && st=1
        (( age_h >= FULL_CRIT_H )) && st=2
        emit_checkmk "$st" "PG_Backup_Full_${db}" \
            "age_h=${age_h};${FULL_MAX_H};${FULL_CRIT_H}" \
            "last backup ${age_h}h ago (${bdir})"
    fi

    # --- pg_cron job failures (last 24 hours) ---
    have_cron="$(scalar "$db" \
        "SELECT COUNT(*) FROM pg_extension WHERE extname='pg_cron'" 2>/dev/null || echo 0)"
    if [[ "${have_cron:-0}" == "1" ]]; then
        failed="$(scalar "$db" \
            "SELECT COUNT(*) FROM cron.job_run_details
             WHERE status IN ('failed','error')
               AND start_time > now() - interval '24 hours'" 2>/dev/null)"
        failed="${failed:-0}"; [[ "$failed" =~ ^[0-9]+$ ]] || failed=0
        st=0; (( failed >= 1 )) && st=1; (( failed >= 5 )) && st=2
        emit_checkmk "$st" "PG_CronJobs_${db}" \
            "failed=${failed};1;5" "${failed} failed pg_cron job run(s) in last 24h (${db})"
    fi
done
