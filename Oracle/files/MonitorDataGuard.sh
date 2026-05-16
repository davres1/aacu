#!/usr/bin/env bash
# MonitorDataGuard.sh — Oracle equivalent of MonitorAlwaysOn.ps1 for Data Guard.
# Reports:
#   - Primary/standby role of each database
#   - Apply / transport lag (V$DATAGUARD_STATS)
#   - V$DATAGUARD_STATUS error severity in the last 30 min
#   - Standby database open mode / managed-recovery state

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/oracle_common.sh"

LAG_WARN_SEC="${LAG_WARN_SEC:-30}"
LAG_CRIT_SEC="${LAG_CRIT_SEC:-120}"
report='[]'

databases=("$@")
[[ ${#databases[@]} -eq 0 ]] && mapfile -t databases < <(list_databases)

for db in "${databases[@]}"; do
    log "→ $db"
    rows=$(sql "$db" sys <<'SQL' 2>/dev/null || true
SELECT '__ROLE__|' || database_role || '|' || open_mode || '|' || protection_mode || '|' || protection_level
  FROM v$database;

SELECT '__LAG__|' || name || '|' || value || '|' || time_computed
  FROM v$dataguard_stats
 WHERE name IN ('apply lag','transport lag','apply finish time');

SELECT '__ERR__|' || severity || '|' || TO_CHAR(timestamp,'YYYY-MM-DD HH24:MI:SS') || '|' || SUBSTR(message, 1, 200)
  FROM v$dataguard_status
 WHERE timestamp > SYSDATE - 30/1440
   AND severity IN ('Error','Fatal','Warning')
 ORDER BY timestamp DESC
 FETCH FIRST 20 ROWS ONLY;
SQL
)

    role=""; open_mode=""; protect=""; level=""
    lag_rows='[]'; err_rows='[]'
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        if [[ "$line" == __ROLE__* ]]; then
            IFS='|' read -r _ role open_mode protect level <<<"$line"
        elif [[ "$line" == __LAG__* ]]; then
            IFS='|' read -r _ name val computed <<<"$line"
            row=$(python3 -c "
import json
print(json.dumps({'name':'$name','value':'$val','computed':'$computed'}))")
            lag_rows=$(python3 -c "import json; r=json.loads('''$lag_rows'''); r.append(json.loads('''$row''')); print(json.dumps(r))")
        elif [[ "$line" == __ERR__* ]]; then
            IFS='|' read -r _ sev when msg <<<"$line"
            row=$(python3 -c "
import json
print(json.dumps({'severity':'$sev','timestamp':'$when','message':'$msg'}))")
            err_rows=$(python3 -c "import json; r=json.loads('''$err_rows'''); r.append(json.loads('''$row''')); print(json.dumps(r))")
        fi
    done <<<"$rows"

    # If this isn't a DG-enabled DB, skip lag severity.
    severity="ok"
    if [[ -n "$role" && "$role" != "PRIMARY" ]]; then
        # Standby — compute apply-lag severity
        apply_lag_sec=$(python3 -c "
import json
for r in json.loads('''$lag_rows'''):
    if r['name'] == 'apply lag':
        v = r['value']
        # value format '+00 00:00:30'
        try:
            sign = 1 if v.startswith('+') else -1
            rest = v[1:] if v[0] in '+-' else v
            d, hms = rest.split(' ')
            h, m, s = hms.split(':')
            print(sign * (int(d)*86400 + int(h)*3600 + int(m)*60 + int(s)))
            break
        except Exception:
            print(0); break
else:
    print(0)
" 2>/dev/null || echo "0")
        if (( apply_lag_sec >= LAG_CRIT_SEC )); then severity="critical"
        elif (( apply_lag_sec >= LAG_WARN_SEC )); then severity="warning"; fi
        [[ "$severity" != "ok" ]] && warn "   $db apply lag ${apply_lag_sec}s ($severity)"
    fi
    if python3 -c "import json,sys; sys.exit(0 if any(r['severity'] in ('Error','Fatal') for r in json.loads('''$err_rows''')) else 1)"; then
        severity="critical"
    fi

    db_entry=$(python3 -c "
import json
print(json.dumps({
    'database':'$db','role':'$role','open_mode':'$open_mode',
    'protection_mode':'$protect','protection_level':'$level',
    'lag_metrics': json.loads('''$lag_rows'''),
    'recent_errors': json.loads('''$err_rows'''),
    'severity':'$severity',
}))")
    report=$(python3 -c "import json; r=json.loads('''$report'''); r.append(json.loads('''$db_entry''')); print(json.dumps(r))")
done

critical=$(python3 -c "import json; print(sum(1 for d in json.loads('''$report''') if d['severity']=='critical'))")
warning=$(python3 -c "import json; print(sum(1 for d in json.loads('''$report''') if d['severity']=='warning'))")
summary="{\"timestamp\":\"$(ts)\",\"critical\":$critical,\"warning\":$warning,\"databases\":$report}"
write_status_file "dataguard" "$summary"
echo "$summary"
log "=== MonitorDataGuard crit=$critical warn=$warning ==="
exit $(( critical > 0 ? 1 : 0 ))
