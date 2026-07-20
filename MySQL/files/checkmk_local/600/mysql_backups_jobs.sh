#!/usr/bin/env bash
# mysql_backups_jobs.sh — CheckMK local check (10 min): age of the newest backup
# artifact and the count of disabled/errored scheduled EVENTS per schema.
# Output: <status> <item> <metrics> <text>
LIB="/opt/dba/scripts/lib/mysql_common.sh"; [[ -f "$LIB" ]] || LIB="$(dirname "$0")/../../lib/mysql_common.sh"
source "$LIB" 2>/dev/null || { echo "3 MySQL_Backups - mysql_common.sh not found"; exit 0; }

FULL_MAX_H="$(get_threshold backups.full_max_age_hours 24)"
FULL_CRIT_H=$(( FULL_MAX_H * 2 ))
BACKUP_ROOT="${BACKUP_ROOT:-/var/backups/mysql}"

for db in $(list_databases); do
    # --- last backup age: newest file under the schema's backup directory ---
    bdir="$(db_section_value "$db" backupdir 2>/dev/null)"
    [[ -z "$bdir" ]] && bdir="$BACKUP_ROOT/$db"
    newest=""
    [[ -d "$bdir" ]] && newest="$(find "$bdir" -type f -printf '%T@\n' 2>/dev/null | sort -nr | head -1)"

    if [[ -z "$newest" ]]; then
        emit_checkmk 2 "MySQL_Backup_Full_${db}" - "no backup file found for ${db} under ${bdir}"
    else
        age_h=$(( ( $(date +%s) - ${newest%.*} ) / 3600 ))
        st=0; (( age_h >= FULL_MAX_H )) && st=1; (( age_h >= FULL_CRIT_H )) && st=2
        emit_checkmk "$st" "MySQL_Backup_Full_${db}" "age_h=${age_h};${FULL_MAX_H};${FULL_CRIT_H}" "last backup ${age_h}h ago (${bdir})"
    fi

    # --- scheduled EVENTS (jobs) that are not ENABLED for this schema ---
    disabled="$(scalar "$db" "SELECT COUNT(*) FROM information_schema.EVENTS WHERE EVENT_SCHEMA='${db}' AND STATUS<>'ENABLED'" 2>/dev/null)"
    disabled="${disabled:-0}"; [[ "$disabled" =~ ^[0-9]+$ ]] || disabled=0
    st=0; (( disabled >= 1 )) && st=1; (( disabled >= 5 )) && st=2
    emit_checkmk "$st" "MySQL_Events_${db}" "disabled=${disabled};1;5" "${disabled} disabled/errored event(s) in ${db}"
done
