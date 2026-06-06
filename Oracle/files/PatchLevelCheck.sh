#!/usr/bin/env bash
# PatchLevelCheck.sh — Oracle equivalent of PatchLevelCheck.ps1.
# Reports per-Oracle-home patch level (opatch lsinventory) + per-database
# DBA_REGISTRY_HISTORY (which PSU/RU is applied).

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/oracle_common.sh"

BUILD_MAX_AGE_DAYS="${BUILD_MAX_AGE_DAYS:-180}"
homes_report='[]'
db_report='[]'

# 1. Oracle home patches — iterate over unique homes in /etc/oratab
homes=()
if [[ -f /etc/oratab ]]; then
    mapfile -t homes < <(awk -F: '!/^#/ && NF >= 2 && $1 != "*" {print $2}' /etc/oratab | sort -u)
fi
for home in "${homes[@]}"; do
    [[ -d "$home" ]] || continue
    if [[ -x "$home/OPatch/opatch" ]]; then
        log "→ opatch $home"
        inv_out="$(su - oracle -c "ORACLE_HOME=$home $home/OPatch/opatch lsinventory -bugs_fixed 2>&1" | head -200 || true)"
        # Pull "Patches (n):" line + latest patch ID + version
        version=$(grep -m1 "Oracle Database" <<<"$inv_out" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1)
        patch_count=$(grep -c '^Patch  ' <<<"$inv_out" || true)
        # Get the most recent applied date
        last_patch=$(grep -E '^Patch  ' <<<"$inv_out" | tail -1 | awk '{print $2}')
        row=$(python3 -c "
import json
print(json.dumps({'home':'$home','version':'$version','patches':$patch_count,
                  'last_patch_id':'$last_patch'}))")
        homes_report=$(python3 -c "import json; r=json.loads('''$homes_report'''); r.append(json.loads('''$row''')); print(json.dumps(r))")
    else
        warn "opatch not found at $home/OPatch/opatch"
    fi
done

# 2. Per-database registry history
databases=()
mapfile -t databases < <(list_databases)
for db in "${databases[@]}"; do
    log "→ registry $db"
    rows=$(sql "$db" sys <<'SQL' 2>/dev/null || true
SELECT '__REG__|' ||
       TO_CHAR(action_time, 'YYYY-MM-DD HH24:MI:SS') || '|' ||
       action || '|' || NVL(namespace,'') || '|' || NVL(version,'') || '|' ||
       NVL(id,'') || '|' || NVL(comments,'')
  FROM dba_registry_history
 ORDER BY action_time DESC
 FETCH FIRST 20 ROWS ONLY;
SQL
)
    items='[]'
    while IFS= read -r line; do
        [[ "$line" != __REG__* ]] && continue
        IFS='|' read -r _ when action ns ver id comments <<<"$line"
        row=$(python3 -c "
import json
print(json.dumps({'action_time':'$when','action':'$action','namespace':'$ns',
                  'version':'$ver','id':'$id','comments':'$comments'}))")
        items=$(python3 -c "import json; r=json.loads('''$items'''); r.append(json.loads('''$row''')); print(json.dumps(r))")
    done <<<"$rows"
    db_row=$(python3 -c "import json; print(json.dumps({'database':'$db','registry_history':json.loads('''$items''')}))")
    db_report=$(python3 -c "import json; r=json.loads('''$db_report'''); r.append(json.loads('''$db_row''')); print(json.dumps(r))")
done

# 3. OS-level: last yum/dnf transaction
last_pkg=$(rpm -qa --last 2>/dev/null | head -1 | awk '{print $NF, $(NF-1), $(NF-2)}')

summary="{\"timestamp\":\"$(ts)\",\"oracle_homes\":$homes_report,\"databases\":$db_report,\"last_os_package\":\"$last_pkg\"}"
write_status_file "patch_level" "$summary"
echo "$summary"
log "=== PatchLevelCheck done ==="
