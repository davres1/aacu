#!/usr/bin/env bash
# mysql_tablespaces.sh — CheckMK local check (5 min): per-schema data size and
# the fullness of the datadir filesystem that holds it, plus general filesystem
# utilization. Output: <status> <item> <metrics> <text>
LIB="/opt/dba/scripts/lib/mariadb_common.sh"; [[ -f "$LIB" ]] || LIB="$(dirname "$0")/../../lib/mariadb_common.sh"
source "$LIB" 2>/dev/null || { echo "3 MariaDB_Tablespaces - mariadb_common.sh not found"; exit 0; }

WARN="$(get_threshold tablespace.used_pct_warn 85)"
CRIT="$(get_threshold tablespace.used_pct_crit 95)"

for db in $(list_databases); do
    # InnoDB data for a schema lives on the server's datadir filesystem; its
    # fullness is the meaningful "tablespace" signal in MariaDB/MariaDB.
    datadir="$(scalar "$db" "SELECT @@datadir" 2>/dev/null)"
    size_mb="$(scalar "$db" "SELECT IFNULL(ROUND(SUM(data_length+index_length)/1048576),0) FROM information_schema.tables WHERE table_schema='${db}'" 2>/dev/null)"
    size_mb="${size_mb:-0}"; [[ "$size_mb" =~ ^[0-9]+$ ]] || size_mb=0

    pct=""
    [[ -n "$datadir" ]] && pct="$(df -P "$datadir" 2>/dev/null | awk 'NR==2 {gsub(/%/,"",$5); print $5}')"
    pct="${pct:-0}"; pct="${pct%%.*}"; [[ "$pct" =~ ^[0-9]+$ ]] || pct=0

    st=0; (( pct >= WARN )) && st=1; (( pct >= CRIT )) && st=2
    emit_checkmk "$st" "MariaDB_TS_${db}_datadir" "used_pct=${pct};${WARN};${CRIT}|size_mb=${size_mb}" "${db} datadir ${pct}% used, schema ${size_mb}MB"
done

df -P 2>/dev/null | awk 'NR>1 && $1 !~ /tmpfs|devtmpfs|overlay/ {gsub(/%/,"",$5); print $6"|"$5}' \
  | while IFS='|' read -r mount used; do
      [[ -z "$mount" ]] && continue
      st=0; (( used >= 85 )) && st=1; (( used >= 95 )) && st=2
      emit_checkmk "$st" "MariaDB_FS_${mount}" "used_pct=${used};85;95" "${mount} ${used}% used"
  done
