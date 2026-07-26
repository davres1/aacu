#!/usr/bin/env bash
# pg_security_checkdb.sh — CheckMK local check (hourly): per-database security
# posture (superuser count, roles with GRANT OPTION, ssl status) and the cached
# amcheck integrity result. Output: <status> <item> <metrics> <text>
LIB="/opt/dba/scripts/lib/pg_common.sh"
[[ -f "$LIB" ]] || LIB="$(dirname "$0")/../../lib/pg_common.sh"
source "$LIB" 2>/dev/null || { echo "3 PostgreSQL_Security - pg_common.sh not found"; exit 0; }

SUPERUSER_WARN="$(get_threshold security_audit.sysadmin_warn_count 5)"

for db in $(list_databases); do
    # Count superusers.
    su_count="$(scalar "$db" \
        "SELECT COUNT(*) FROM pg_roles WHERE rolsuper = true" 2>/dev/null)"
    su_count="${su_count:-0}"; [[ "$su_count" =~ ^[0-9]+$ ]] || su_count=0

    # Count roles with GRANT OPTION (privilege escalation risk).
    grant_opt="$(scalar "$db" \
        "SELECT COUNT(DISTINCT grantee)
         FROM information_schema.role_table_grants
         WHERE is_grantable = 'YES'
           AND grantee NOT IN ('postgres','pg_monitor','pg_read_all_stats')" 2>/dev/null)"
    grant_opt="${grant_opt:-0}"; [[ "$grant_opt" =~ ^[0-9]+$ ]] || grant_opt=0

    # SSL status.
    ssl="$(scalar "$db" "SHOW ssl" 2>/dev/null)"
    ssl_ok=1; [[ "${ssl,,}" != "on" ]] && ssl_ok=0

    issues=0
    (( su_count > SUPERUSER_WARN )) && issues=$((issues+1))
    (( grant_opt > 0 ))             && issues=$((issues+1))
    (( ssl_ok == 0 ))               && issues=$((issues+1))

    st=0; (( issues >= 1 )) && st=1; (( issues >= 3 )) && st=2
    emit_checkmk "$st" "PG_Security_${db}" \
        "issues=${issues};1;3|superusers=${su_count}|grant_opt=${grant_opt}|ssl_ok=${ssl_ok}" \
        "${issues} security issue(s) (superusers=${su_count}, grant_opt=${grant_opt}, ssl=${ssl:-off})"
done

# Cached amcheck / bt_index_check summary.
CDB="$STATUS_DIR/checkdb_status.json"
if [[ -f "$CDB" ]]; then
    read -r errors failed <<< "$(python3 - "$CDB" <<'PY'
import json, sys
try: d = json.load(open(sys.argv[1]))
except Exception: print("0 0"); raise SystemExit
print(d.get("errors", 0), d.get("failed", 0))
PY
)"
    st=0; (( errors + failed >= 1 )) && st=2
    emit_checkmk "$st" "PG_CheckDB" \
        "errors=${errors}|failed=${failed}" \
        "amcheck: ${errors} error(s), ${failed} failed"
else
    emit_checkmk 3 "PG_CheckDB" - "no cached amcheck result yet (see CheckDB.sh)"
fi
