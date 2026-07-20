#!/usr/bin/env bash
# mysql_security_checkdb.sh — CheckMK local check (hourly): per-schema security
# posture (grantable schema privileges + wildcard-host grantees) and the cached
# CHECK TABLE integrity result. Output: <status> <item> <metrics> <text>
LIB="/opt/dba/scripts/lib/mariadb_common.sh"; [[ -f "$LIB" ]] || LIB="$(dirname "$0")/../../lib/mariadb_common.sh"
source "$LIB" 2>/dev/null || { echo "3 MariaDB_Security - mariadb_common.sh not found"; exit 0; }

DBADM_WARN="$(get_threshold security_audit.dbadm_warn_count 5)"

for db in $(list_databases); do
    # grantees holding WITH GRANT OPTION on the schema (privilege-escalation risk)
    admin="$(scalar "$db" "SELECT COUNT(*) FROM information_schema.SCHEMA_PRIVILEGES WHERE TABLE_SCHEMA='${db}' AND IS_GRANTABLE='YES'" 2>/dev/null)"
    admin="${admin:-0}"; [[ "$admin" =~ ^[0-9]+$ ]] || admin=0
    # grantees reachable from any host (GRANTEE ending in @'%') — PUBLIC-like exposure
    pub="$(scalar "$db" "SELECT COUNT(*) FROM information_schema.SCHEMA_PRIVILEGES WHERE TABLE_SCHEMA='${db}' AND GRANTEE LIKE '%@''%'''" 2>/dev/null)"
    pub="${pub:-0}"; [[ "$pub" =~ ^[0-9]+$ ]] || pub=0

    issues=0; (( admin > DBADM_WARN )) && issues=$((issues+1)); (( pub > 0 )) && issues=$((issues+1))
    st=0; (( issues >= 1 )) && st=1; (( issues >= 5 )) && st=2
    emit_checkmk "$st" "MariaDB_Security_${db}" "issues=${issues};1;5|admin=${admin}|public=${pub}" "${issues} security issue(s)"
done

# Cached CHECK TABLE summary (the heavy integrity scan runs out-of-band and
# writes its result here; this read-only plugin just surfaces it).
CDB="$STATUS_DIR/checkdb_status.json"
if [[ -f "$CDB" ]]; then
    read -r errors failed <<< "$(python3 - "$CDB" <<'PY'
import json,sys
try: d=json.load(open(sys.argv[1]))
except Exception: print("0 0"); raise SystemExit
print(d.get("errors",0), d.get("failed",0))
PY
)"
    st=0; (( errors + failed >= 1 )) && st=2
    emit_checkmk "$st" "MariaDB_CheckDB" "errors=${errors}|failed=${failed}" "CHECK TABLE: ${errors} error(s), ${failed} failed"
else
    emit_checkmk 3 "MariaDB_CheckDB" - "no cached CHECK TABLE result yet"
fi
