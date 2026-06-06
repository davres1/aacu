#!/usr/bin/env bash
# db2_patch.sh — CheckMK local check (daily): Db2 install version / fixpack and
# the age of the most recent OS package. Output: <status> <item> <metrics> <text>
LIB="/opt/dba/scripts/lib/db2_common.sh"; [[ -f "$LIB" ]] || LIB="$(dirname "$0")/../../lib/db2_common.sh"
source "$LIB" 2>/dev/null || { echo "3 Db2_Version - db2_common.sh not found"; exit 0; }

LEVEL="$(db2level 2>/dev/null)"
VERSION="$(printf '%s' "$LEVEL" | grep -oE 'v[0-9]+\.[0-9.]+' | head -1)"
FIXPACK="$(printf '%s' "$LEVEL" | grep -oE 'Fix Pack[^"]*"[0-9]+"' | grep -oE '[0-9]+$')"
emit_checkmk 0 "Db2_Version" - "version=${VERSION:-unknown} fixpack=${FIXPACK:-?}"

WARN_DAYS="$(get_threshold patch.hotfix_warn_age_days 45)"
CRIT_DAYS="$(get_threshold patch.hotfix_crit_age_days 90)"
last_pkg_date="$(rpm -qa --last 2>/dev/null | head -1 | sed 's/^[^ ]* *//')"
if [[ -n "$last_pkg_date" ]]; then
    age_days="$(python3 - "$last_pkg_date" <<'PY'
import sys, datetime
try:
    dt = datetime.datetime.strptime(sys.argv[1].strip(), "%a %d %b %Y %I:%M:%S %p %Z")
    print((datetime.datetime.now()-dt).days)
except Exception:
    print(0)
PY
)"
    st=0; (( age_days >= WARN_DAYS )) && st=1; (( age_days >= CRIT_DAYS )) && st=2
    emit_checkmk "$st" "Linux_LastPackage" "age_days=${age_days};${WARN_DAYS};${CRIT_DAYS}" "last OS package ${age_days}d ago"
fi
