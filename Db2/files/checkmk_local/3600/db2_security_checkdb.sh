#!/usr/bin/env bash
# db2_security_checkdb.sh — CheckMK local check (hourly): DBADM grantee count +
# PUBLIC table grants per DB, and the cached INSPECT CHECK status.
# Output: <status> <item> <metrics> <text>
LIB="/opt/dba/scripts/lib/db2_common.sh"; [[ -f "$LIB" ]] || LIB="$(dirname "$0")/../../lib/db2_common.sh"
source "$LIB" 2>/dev/null || { echo "3 Db2_Security - db2_common.sh not found"; exit 0; }

DBADM_WARN="$(get_threshold security_audit.dbadm_warn_count 5)"

for db in $(list_databases); do
    dbadm="$(printf '%s' "SELECT COUNT(*) FROM SYSCAT.DBAUTH WHERE DBADMAUTH='Y';" | sqlx "$db" 2>/dev/null | tr -d ' ')"; dbadm="${dbadm:-0}"
    pub="$(printf '%s' "SELECT COUNT(*) FROM SYSCAT.TABAUTH WHERE GRANTEE='PUBLIC';" | sqlx "$db" 2>/dev/null | tr -d ' ')"; pub="${pub:-0}"
    issues=0; (( dbadm > DBADM_WARN )) && issues=$((issues+1)); (( pub > 0 )) && issues=$((issues+1))
    st=0; (( issues >= 1 )) && st=1; (( issues >= 5 )) && st=2
    emit_checkmk "$st" "Db2_Security_${db}" "issues=${issues};1;5|dbadm=${dbadm}|public=${pub}" "${issues} security issue(s)"
done

# Cached INSPECT CHECK summary.
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
    emit_checkmk "$st" "Db2_CheckDB" "errors=${errors}|failed=${failed}" "INSPECT CHECK: ${errors} error(s), ${failed} failed"
else
    emit_checkmk 3 "Db2_CheckDB" - "no cached INSPECT CHECK yet"
fi
