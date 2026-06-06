#!/usr/bin/env bash
# db2_local.sh — fast CheckMK local check (default interval): instance up,
# blocking-session count and HADR state per database. Output format:
#   <status> <item> <metrics> <text>
LIB="/opt/dba/scripts/lib/db2_common.sh"; [[ -f "$LIB" ]] || LIB="$(dirname "$0")/../lib/db2_common.sh"
source "$LIB" 2>/dev/null || { echo "3 Db2_Agent - db2_common.sh not found"; exit 0; }

if db2pd - >/dev/null 2>&1; then
    emit_checkmk 0 Db2_Instance - "instance ${DB2INSTANCE:-db2inst1} running"
else
    emit_checkmk 2 Db2_Instance - "instance ${DB2INSTANCE:-db2inst1} DOWN"
fi

for db in $(list_databases); do
    blk="$(printf '%s' "SELECT COUNT(*) FROM SYSIBMADM.MON_LOCKWAITS;" | sqlx "$db" 2>/dev/null | tr -d ' ')"
    blk="${blk:-0}"
    st=0; [[ "$blk" -ge 1 ]] && st=1; [[ "$blk" -ge 10 ]] && st=2
    emit_checkmk "$st" "Db2_Blocking_${db}" "blocked=${blk};1;10" "${blk} lock wait(s) in ${db}"

    role="$(printf '%s' "SELECT HADR_ROLE FROM SYSIBMADM.SNAPHADR FETCH FIRST 1 ROWS ONLY;" | sqlx "$db" 2>/dev/null | tr -d ' ')"
    if [[ -n "$role" && "$role" != "STANDARD" ]]; then
        state="$(printf '%s' "SELECT HADR_STATE FROM SYSIBMADM.SNAPHADR FETCH FIRST 1 ROWS ONLY;" | sqlx "$db" 2>/dev/null | tr -d ' ')"
        st=0; [[ "$state" != "PEER" ]] && st=1
        emit_checkmk "$st" "Db2_HADR_${db}" - "HADR ${role} state=${state:-unknown}"
    fi
done
