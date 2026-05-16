#!/usr/bin/env bash
# CheckMK local plugin (daily) — Oracle DB version per DB + latest opatch
# bundle + last OS package install date.

set -uo pipefail
LIB="${ORACLE_DBA_LIB:-/opt/dba/scripts/lib/oracle_common.sh}"
[[ -f "$LIB" ]] && source "$LIB" || { echo "3 Oracle_Patch - UNKNOWN - $LIB not found"; exit 0; }

WARN=$(get_threshold patch.hotfix_warn_age_days 45)
CRIT=$(get_threshold patch.hotfix_crit_age_days 90)

# Per-DB version
for db in $(list_databases); do
    if ! db_credentials "$db" >/dev/null 2>&1; then continue; fi
    ver=$(scalar "$db" "SELECT version FROM v\$instance;" 2>/dev/null)
    [[ -n "$ver" ]] && emit_checkmk 0 "Oracle_Version_$db" - "version=$ver"
done

# Latest opatch on each ORACLE_HOME
if [[ -f /etc/oratab ]]; then
    awk -F: '!/^#/ && NF >= 2 && $1 != "*" {print $2}' /etc/oratab | sort -u | while read -r home; do
        [[ -x "$home/OPatch/opatch" ]] || continue
        out=$(su - oracle -c "ORACLE_HOME=$home $home/OPatch/opatch lsinventory" 2>/dev/null | head -40)
        latest=$(grep -E '^Patch  ' <<<"$out" | tail -1)
        if [[ -n "$latest" ]]; then
            emit_checkmk 0 "Oracle_OPatch_$(basename "$home")" - "latest: $latest"
        else
            emit_checkmk 1 "Oracle_OPatch_$(basename "$home")" - "no patches recorded"
        fi
    done
fi

# Last OS hotfix
if command -v rpm >/dev/null 2>&1; then
    last=$(rpm -qa --last 2>/dev/null | head -1)
    pkg=$(echo "$last" | awk '{print $1}')
    when=$(echo "$last" | awk '{print $2, $3, $4, $5}')
    age_d=$(python3 -c "
from datetime import datetime
try: dt = datetime.strptime('$when'.strip(),'%a %d %b %Y %I:%M:%S %p %Z')
except Exception: print(999999)
else: print(int((datetime.now()-dt).total_seconds()/86400))
" 2>/dev/null)
    age_d="${age_d:-999999}"
    sev=0
    (( age_d >= CRIT )) && sev=2
    (( age_d >= WARN && age_d < CRIT )) && sev=1
    emit_checkmk $sev "Linux_LastHotfix" "age_days=$age_d;$WARN;$CRIT" "last package $pkg installed ${age_d}d ago"
fi
