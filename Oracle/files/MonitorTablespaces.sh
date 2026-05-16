#!/usr/bin/env bash
# MonitorTablespaces.sh — Oracle equivalent of MonitorDiskSpace.ps1 +
# MonitorTempDB.ps1. Reports per-tablespace used %, datafile autoextend
# capacity, and TEMP / UNDO usage. Also reports OS filesystems via df.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/oracle_common.sh"

WARN_PCT="${WARN_PCT:-85}"
CRIT_PCT="${CRIT_PCT:-95}"
report='[]'

# OS filesystem usage (only ones likely to be Oracle-relevant)
fs_report=$(df -hP --output=source,size,used,avail,pcent,target \
            | awk 'NR>1 && $6 ~ /(oracle|u0[0-9]|backup|fra|data|recovery)/ {
                gsub("%","",$5);
                print "{\"mount\":\""$6"\",\"size\":\""$2"\",\"used\":\""$3"\",\"avail\":\""$4"\",\"pct\":"$5"}"
              }' | paste -sd, -)
[[ -z "$fs_report" ]] && fs_report=""

databases=("$@")
[[ ${#databases[@]} -eq 0 ]] && mapfile -t databases < <(list_databases)

for db in "${databases[@]}"; do
    log "→ $db"
    rows=$(sql "$db" <<'SQL' 2>/dev/null || true
SELECT '__TS__|' || m.tablespace_name || '|' ||
       NVL(t.contents,'PERMANENT') || '|' ||
       ROUND(m.used_percent, 1)    || '|' ||
       ROUND(m.used_space*8/1024)  || '|' ||
       ROUND(m.tablespace_size*8/1024)
  FROM dba_tablespace_usage_metrics m
  JOIN dba_tablespaces t ON m.tablespace_name = t.tablespace_name;
SELECT '__TEMP__|' || tablespace_name || '|' ||
       ROUND(SUM(bytes_used)/1024/1024)  || '|' ||
       ROUND(SUM(bytes_free)/1024/1024)
  FROM v$temp_space_header
 GROUP BY tablespace_name;
SQL
)

    ts_rows='[]'
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        if [[ "$line" == __TS__* ]]; then
            IFS='|' read -r _ name kind pct used_mb size_mb <<<"$line"
            sev="ok"
            if   (( $(printf '%.0f' "$pct") >= CRIT_PCT )); then sev="critical"
            elif (( $(printf '%.0f' "$pct") >= WARN_PCT )); then sev="warning"; fi
            row=$(python3 -c "
import json
print(json.dumps({'tablespace':'$name','contents':'$kind','used_pct':float('$pct'),
                  'used_mb':int('$used_mb'),'size_mb':int('$size_mb'),'severity':'$sev'}))")
            ts_rows=$(python3 -c "import json; r=json.loads('''$ts_rows'''); r.append(json.loads('''$row''')); print(json.dumps(r))")
            [[ "$sev" != "ok" ]] && warn "   $name $pct% used ($sev)"
        elif [[ "$line" == __TEMP__* ]]; then
            IFS='|' read -r _ name used_mb free_mb <<<"$line"
            total=$(( used_mb + free_mb ))
            (( total == 0 )) && total=1
            pct=$(python3 -c "print(round($used_mb / $total * 100, 1))")
            row=$(python3 -c "
import json
print(json.dumps({'tablespace':'$name','contents':'TEMP-DETAIL','used_mb':int('$used_mb'),
                  'free_mb':int('$free_mb'),'used_pct':float('$pct')}))")
            ts_rows=$(python3 -c "import json; r=json.loads('''$ts_rows'''); r.append(json.loads('''$row''')); print(json.dumps(r))")
        fi
    done <<<"$rows"

    db_entry=$(python3 -c "
import json
print(json.dumps({'database':'$db','tablespaces':json.loads('''$ts_rows''')}))")
    report=$(python3 -c "import json; r=json.loads('''$report'''); r.append(json.loads('''$db_entry''')); print(json.dumps(r))")
done

summary="{\"timestamp\":\"$(ts)\",\"filesystems\":[${fs_report}],\"databases\":$report}"
write_status_file "tablespaces" "$summary"
echo "$summary"
log "=== MonitorTablespaces done ==="
