#!/usr/bin/env bash
# pg_patch.sh — CheckMK local check (daily): PostgreSQL server version and the
# age of the most recent OS package (patch currency proxy).
# Output: <status> <item> <metrics> <text>
LIB="/opt/dba/scripts/lib/pg_common.sh"
[[ -f "$LIB" ]] || LIB="$(dirname "$0")/../../lib/pg_common.sh"
source "$LIB" 2>/dev/null || { echo "3 PostgreSQL_Version - pg_common.sh not found"; exit 0; }

primary="$(list_databases | head -1)"
VERSION="$(scalar "$primary" "SHOW server_version" 2>/dev/null)"
FULL_VER="$(printf '%s\n' "SELECT version();" | sqlx "$primary" 2>/dev/null | head -1)"
emit_checkmk 0 "PG_Version" - "version=${VERSION:-unknown} (${FULL_VER:-?})"

WARN_DAYS="$(get_threshold patch.hotfix_warn_age_days 45)"
CRIT_DAYS="$(get_threshold patch.hotfix_crit_age_days 90)"

# RPM-based (RHEL/CentOS/Rocky) — try PostgreSQL packages first, then OS-wide.
last_pg_pkg="$(rpm -qa --last 'postgresql*' 2>/dev/null | head -1 | sed 's/^[^ ]* *//')"
last_os_pkg="$(rpm -qa --last 2>/dev/null | head -1 | sed 's/^[^ ]* *//')"

# DEB-based fallback (Ubuntu/Debian).
if [[ -z "$last_os_pkg" ]]; then
    last_os_pkg="$(grep 'install ' /var/log/dpkg.log 2>/dev/null | tail -1 || true)"
fi
if [[ -z "$last_pg_pkg" ]]; then
    last_pg_pkg="$(grep 'install postgresql' /var/log/dpkg.log 2>/dev/null | tail -1 || true)"
fi

emit_checkmk 0 "PG_Package" - "pg_pkg: ${last_pg_pkg:-unknown}  os_pkg: ${last_os_pkg:-unknown}"

if [[ -n "$last_os_pkg" ]]; then
    age_days="$(python3 - "$last_os_pkg" <<'PY'
import sys, datetime, re
raw = sys.argv[1].strip()
# Try RPM --last format: "Wed 23 Jul 2025 10:30:45 AM UTC"
fmts = [
    "%a %d %b %Y %I:%M:%S %p %Z",
    "%a %d %b %Y %H:%M:%S %Z",
    "%Y-%m-%d %H:%M:%S",
]
for fmt in fmts:
    try:
        dt = datetime.datetime.strptime(raw, fmt)
        print((datetime.datetime.now() - dt).days)
        raise SystemExit(0)
    except ValueError:
        pass
# DEB log line: "2025-07-23 10:30:45 install package:amd64 <none> 1.0"
m = re.match(r'(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})', raw)
if m:
    try:
        dt = datetime.datetime.strptime(m.group(1), "%Y-%m-%d %H:%M:%S")
        print((datetime.datetime.now() - dt).days)
        raise SystemExit(0)
    except ValueError:
        pass
print(0)
PY
)"
    st=0
    (( age_days >= WARN_DAYS )) && st=1
    (( age_days >= CRIT_DAYS )) && st=2
    emit_checkmk "$st" "Linux_LastPackage" \
        "age_days=${age_days};${WARN_DAYS};${CRIT_DAYS}" \
        "last OS package ${age_days}d ago"
fi
