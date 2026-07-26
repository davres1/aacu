#!/usr/bin/env bash
# pg_tablespaces.sh — CheckMK local check (5 min): per-database size, per-
# tablespace size, and the fullness of the data_directory filesystem.
# Output: <status> <item> <metrics> <text>
LIB="/opt/dba/scripts/lib/pg_common.sh"
[[ -f "$LIB" ]] || LIB="$(dirname "$0")/../../lib/pg_common.sh"
source "$LIB" 2>/dev/null || { echo "3 PostgreSQL_Tablespaces - pg_common.sh not found"; exit 0; }

WARN="$(get_threshold tablespace.used_pct_warn 85)"
CRIT="$(get_threshold tablespace.used_pct_crit 95)"

# Per-database size checks.
for db in $(list_databases); do
    # Database size in MB.
    size_mb="$(scalar "$db" \
        "SELECT ROUND(pg_database_size(current_database())/1048576.0)" 2>/dev/null)"
    size_mb="${size_mb:-0}"; [[ "$size_mb" =~ ^[0-9]+$ ]] || size_mb=0

    # data_directory for filesystem usage.
    datadir="$(scalar "$db" "SHOW data_directory" 2>/dev/null)"
    pct=""
    [[ -n "$datadir" ]] && pct="$(df -P "$datadir" 2>/dev/null | awk 'NR==2 {gsub(/%/,"",$5); print $5}')"
    pct="${pct:-0}"; pct="${pct%%.*}"; [[ "$pct" =~ ^[0-9]+$ ]] || pct=0

    st=0; (( pct >= WARN )) && st=1; (( pct >= CRIT )) && st=2
    emit_checkmk "$st" "PG_TS_${db}_datadir" \
        "used_pct=${pct};${WARN};${CRIT}|size_mb=${size_mb}" \
        "${db} datadir ${pct}% used, database ${size_mb}MB"

    # Per-tablespace sizes (instance-wide; report per db to allow filtering).
    while IFS='|' read -r spcname spc_mb; do
        [[ -z "$spcname" ]] && continue
        emit_checkmk 0 "PG_Spc_${db}_${spcname}" \
            "size_mb=${spc_mb}" \
            "${db} tablespace ${spcname} ${spc_mb}MB"
    done < <(printf '%s\n' \
        "SELECT spcname, ROUND(COALESCE(pg_tablespace_size(oid),0)/1048576.0)
         FROM pg_tablespace
         WHERE spcname != 'pg_global'
         ORDER BY spcname;" \
        | sqlx "$db" 2>/dev/null)
done

# General filesystem utilization (all real filesystems).
df -P 2>/dev/null | awk 'NR>1 && $1 !~ /tmpfs|devtmpfs|overlay/ {gsub(/%/,"",$5); print $6"|"$5}' \
  | while IFS='|' read -r mount used; do
      [[ -z "$mount" ]] && continue
      st=0; (( used >= 85 )) && st=1; (( used >= 95 )) && st=2
      emit_checkmk "$st" "PG_FS_${mount}" "used_pct=${used};85;95" "${mount} ${used}% used"
  done
