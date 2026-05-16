#!/usr/bin/env bash
# CheckMK local plugin (5 min) — tablespace usage + TEMP/UNDO per DB +
# filesystem free space.

set -uo pipefail
LIB="${ORACLE_DBA_LIB:-/opt/dba/scripts/lib/oracle_common.sh}"
[[ -f "$LIB" ]] && source "$LIB" || { echo "3 Oracle_Tablespaces - UNKNOWN - $LIB not found"; exit 0; }

WARN=$(get_threshold tablespace.used_pct_warn 85)
CRIT=$(get_threshold tablespace.used_pct_crit 95)

# Filesystem usage on common Oracle mounts
while IFS= read -r line; do
    mount=$(echo "$line" | awk '{print $6}')
    pct=$(echo "$line" | awk '{gsub("%","",$5); print $5}')
    free=$(echo "$line" | awk '{print $4}')
    case "$mount" in
        /u0*|/oracle*|/backup*|/fra*|/data*|/recovery*)
            sev=0
            (( pct >= CRIT )) && sev=2
            (( pct >= WARN && pct < CRIT )) && sev=1
            item="FS_$(echo "$mount" | tr -d /)"
            emit_checkmk $sev "$item" "used_pct=$pct;$WARN;$CRIT" "$free free on $mount ($pct% used)"
            ;;
    esac
done < <(df -hP | tail -n +2)

# Per-tablespace usage (every DB in databases.ini)
for db in $(list_databases); do
    if ! db_credentials "$db" >/dev/null 2>&1; then continue; fi
    rows=$(sql "$db" <<'SQL' 2>/dev/null
SELECT '__TS__|' || tablespace_name || '|' ||
       ROUND(used_percent, 1)        || '|' ||
       ROUND(used_space*8/1024)      || '|' ||
       ROUND(tablespace_size*8/1024)
  FROM dba_tablespace_usage_metrics;
SQL
)
    while IFS= read -r line; do
        [[ "$line" != __TS__* ]] && continue
        IFS='|' read -r _ ts pct used_mb size_mb <<<"$line"
        sev=0
        pct_int=$(printf '%.0f' "$pct")
        (( pct_int >= CRIT )) && sev=2
        (( pct_int >= WARN && pct_int < CRIT )) && sev=1
        item="Oracle_TS_${db}_${ts}"
        item="${item//[^A-Za-z0-9_-]/_}"
        emit_checkmk $sev "$item" "used_pct=$pct;$WARN;$CRIT|size_mb=$size_mb|used_mb=$used_mb" "$ts $pct% used in $db"
    done <<<"$rows"
done
