#!/usr/bin/env bash
# CheckMK local plugin (hourly) — DBA-role count, default-password accounts,
# o7_dictionary_accessibility, PUBLIC grants on dangerous packages, plus
# cached CheckDB status read from the JSON status file.

set -uo pipefail
LIB="${ORACLE_DBA_LIB:-/opt/dba/scripts/lib/oracle_common.sh}"
[[ -f "$LIB" ]] && source "$LIB" || { echo "3 Oracle_Security - UNKNOWN - $LIB not found"; exit 0; }

DBA_WARN=$(get_threshold security_audit.dba_warn_count 5)

# Security summary per DB
for db in $(list_databases); do
    if ! db_credentials "$db" >/dev/null 2>&1; then continue; fi
    blob=$(sql "$db" sys <<SQL 2>/dev/null
SELECT '__DBA__|' ||
       (SELECT COUNT(*) FROM dba_role_privs WHERE granted_role='DBA' AND grantee NOT IN ('SYS','SYSTEM'));
SELECT '__DEFPWD__|' || (SELECT COUNT(*) FROM dba_users_with_defpwd);
SELECT '__O7__|' || (SELECT value FROM v\$parameter WHERE name='o7_dictionary_accessibility');
SELECT '__PUB__|' || (
  SELECT COUNT(*) FROM dba_tab_privs
   WHERE grantee='PUBLIC'
     AND table_name IN ('UTL_FILE','UTL_HTTP','UTL_TCP','UTL_SMTP','UTL_INADDR',
                        'DBMS_LOB','DBMS_LDAP','DBMS_OBFUSCATION_TOOLKIT')
);
SQL
)
    dba=0; defpwd=0; o7=FALSE; pub=0
    while IFS= read -r line; do
        case "$line" in
            __DBA__*)    dba="${line#__DBA__|}"; dba="${dba//[[:space:]]/}";;
            __DEFPWD__*) defpwd="${line#__DEFPWD__|}"; defpwd="${defpwd//[[:space:]]/}";;
            __O7__*)     o7="${line#__O7__|}"; o7="${o7//[[:space:]]/}";;
            __PUB__*)    pub="${line#__PUB__|}"; pub="${pub//[[:space:]]/}";;
        esac
    done <<<"$blob"

    issues=0
    issue_msgs=()
    (( dba > DBA_WARN )) && { ((issues++)); issue_msgs+=("$dba DBA grantees"); }
    (( defpwd > 0 ))     && { ((issues++)); issue_msgs+=("$defpwd default-pwd"); }
    [[ "$o7" == "TRUE" ]] && { ((issues++)); issue_msgs+=("O7_DICTIONARY_ACCESSIBILITY=TRUE"); }
    (( pub > 0 ))        && { ((issues++)); issue_msgs+=("$pub PUBLIC grants"); }

    sev=0
    (( issues >= 5 )) && sev=2
    (( issues >= 1 && issues < 5 )) && sev=1
    msg="${issue_msgs[*]:-no issues}"
    [[ "${#issue_msgs[@]}" -gt 0 ]] && msg="${issue_msgs[*]}"
    emit_checkmk $sev "Oracle_Security_$db" "issues=$issues;1;5|dba=$dba|defpwd=$defpwd|public=$pub" "$msg"
done

# Cached CheckDB result (produced by CheckDB.sh)
status_file="${STATUS_DIR}/checkdb_status.json"
if [[ -f "$status_file" ]]; then
    python3 - "$status_file" <<'PY'
import json, sys
from datetime import datetime
try:
    b = json.load(open(sys.argv[1]))
    age_h = round((datetime.now() - datetime.strptime(b['timestamp'][:19],'%Y-%m-%d %H:%M:%S')).total_seconds()/3600,1)
    errors = int(b.get('errors',0)); failed = int(b.get('failed',0)); clean = int(b.get('clean',0))
    sev = 0
    if errors or failed: sev = 2
    elif age_h > 192:     sev = 2
    elif age_h > 168:     sev = 1
    print(f"{sev} Oracle_CheckDB clean={clean}|errors={errors};1;1|failed={failed};1;1|age_h={age_h};168;192 last run {age_h}h ago: clean={clean} errors={errors} failed={failed}")
except Exception as e:
    print(f"3 Oracle_CheckDB - UNKNOWN - {e}")
PY
else
    emit_checkmk 3 "Oracle_CheckDB" - "no $status_file yet (run CheckDB.sh)"
fi
