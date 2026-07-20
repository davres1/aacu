#!/usr/bin/env bash
# mysql_patch.sh — CheckMK local check (daily): MySQL/MariaDB server version and
# the age of the most recent OS package. Output: <status> <item> <metrics> <text>
LIB="/opt/dba/scripts/lib/mysql_common.sh"; [[ -f "$LIB" ]] || LIB="$(dirname "$0")/../../lib/mysql_common.sh"
source "$LIB" 2>/dev/null || { echo "3 MySQL_Version - mysql_common.sh not found"; exit 0; }

primary="$(list_databases | head -1)"
VERSION="$(scalar "$primary" "SELECT VERSION()" 2>/dev/null)"
COMMENT="$(printf '%s' "SELECT @@version_comment" | sqlx "$primary" 2>/dev/null | head -1)"
emit_checkmk 0 "MySQL_Version" - "version=${VERSION:-unknown} (${COMMENT:-?})"

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
