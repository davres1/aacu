#!/usr/bin/env bash
# db2_tablespaces.sh — CheckMK local check (5 min): tablespace usage per DB
# plus filesystem utilization. Output: <status> <item> <metrics> <text>
LIB="/opt/dba/scripts/lib/db2_common.sh"; [[ -f "$LIB" ]] || LIB="$(dirname "$0")/../../lib/db2_common.sh"
source "$LIB" 2>/dev/null || { echo "3 Db2_Tablespaces - db2_common.sh not found"; exit 0; }

WARN="$(get_threshold tablespace.used_pct_warn 85)"
CRIT="$(get_threshold tablespace.used_pct_crit 95)"

for db in $(list_databases); do
    while IFS='|' read -r name pct; do
        name="$(echo "$name" | tr -d ' ')"; [[ -z "$name" ]] && continue
        pct="$(echo "$pct" | tr -d ' ')"; pct="${pct%%.*}"; pct="${pct:-0}"
        st=0; (( pct >= WARN )) && st=1; (( pct >= CRIT )) && st=2
        emit_checkmk "$st" "Db2_TS_${db}_${name}" "used_pct=${pct};${WARN};${CRIT}" "${name} ${pct}% used in ${db}"
    done <<< "$(printf '%s' "SELECT TBSP_NAME || '|' || CAST(TBSP_UTILIZATION_PERCENT AS DEC(5,1)) FROM SYSIBMADM.TBSP_UTILIZATION;" | sqlx "$db" 2>/dev/null)"
done

df -P 2>/dev/null | awk 'NR>1 && $1 !~ /tmpfs|devtmpfs|overlay/ {gsub(/%/,"",$5); print $6"|"$5}' \
  | while IFS='|' read -r mount used; do
      [[ -z "$mount" ]] && continue
      st=0; (( used >= 85 )) && st=1; (( used >= 95 )) && st=2
      emit_checkmk "$st" "Db2_FS_${mount}" "used_pct=${used};85;95" "${mount} ${used}% used"
  done
