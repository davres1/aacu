#!/usr/bin/env bash
# SecurityAudit.sh — comprehensive read-only Oracle security audit.
# Mirrors SecurityAudit.ps1 with Oracle-specific findings:
#   - DBA role members (count + list)
#   - SYS/SYSTEM password not default
#   - Profile FAILED_LOGIN_ATTEMPTS / PASSWORD_LIFE_TIME limits
#   - Default-password accounts (DBA_USERS_WITH_DEFPWD)
#   - GRANT to PUBLIC of dangerous objects (UTL_FILE, UTL_HTTP, DBMS_LOB, etc.)
#   - O7_DICTIONARY_ACCESSIBILITY parameter
#   - TDE encryption state of tablespaces
#   - Audit (UNIFIED) coverage

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/oracle_common.sh"

DBA_WARN_COUNT="${DBA_WARN_COUNT:-5}"
report='[]'

databases=("$@")
[[ ${#databases[@]} -eq 0 ]] && mapfile -t databases < <(list_databases)

for db in "${databases[@]}"; do
    log "→ $db"
    issues=()
    findings=$(sql "$db" sys <<'SQL' 2>/dev/null || true
SELECT '__DBA__|' || grantee FROM dba_role_privs
 WHERE granted_role = 'DBA' AND grantee NOT IN ('SYS','SYSTEM');

SELECT '__DEFPWD__|' || username FROM dba_users_with_defpwd;

SELECT '__PARAM__|' || name || '|' || value
  FROM v$parameter
 WHERE name IN ('o7_dictionary_accessibility','remote_login_passwordfile',
                'audit_trail','sec_case_sensitive_logon',
                'sec_max_failed_login_attempts','remote_os_authent');

SELECT '__PROFILE__|' || profile || '|' || resource_name || '|' || limit
  FROM dba_profiles
 WHERE resource_name IN ('FAILED_LOGIN_ATTEMPTS','PASSWORD_LIFE_TIME','PASSWORD_LOCK_TIME')
   AND profile = 'DEFAULT';

SELECT '__PUBLIC__|' || privilege || '|' || table_name
  FROM dba_tab_privs
 WHERE grantee = 'PUBLIC'
   AND table_name IN ('UTL_FILE','UTL_HTTP','UTL_TCP','UTL_SMTP','UTL_INADDR',
                      'DBMS_LOB','DBMS_OBFUSCATION_TOOLKIT','DBMS_LDAP',
                      'DBMS_RANDOM','DBMS_BACKUP_RESTORE');

SELECT '__TDE__|' || tablespace_name || '|' || encrypted
  FROM dba_tablespaces;

SELECT '__AUDIT__|' || policy_name || '|' || enabled_option
  FROM audit_unified_enabled_policies;
SQL
)

    dba_members='[]'; def_pwd='[]'; params='{}'; profiles='[]'; public_grants='[]'; tde='[]'; audit='[]'
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        case "$line" in
            __DBA__*)
                v="${line#__DBA__|}"
                dba_members=$(python3 -c "import json; r=json.loads('''$dba_members'''); r.append({'grantee':'$v'}); print(json.dumps(r))")
                ;;
            __DEFPWD__*)
                v="${line#__DEFPWD__|}"
                def_pwd=$(python3 -c "import json; r=json.loads('''$def_pwd'''); r.append({'user':'$v'}); print(json.dumps(r))")
                ;;
            __PARAM__*)
                IFS='|' read -r _ name val <<<"$line"
                params=$(python3 -c "import json; d=json.loads('''$params'''); d['$name']='$val'; print(json.dumps(d))")
                ;;
            __PROFILE__*)
                IFS='|' read -r _ prof res lim <<<"$line"
                profiles=$(python3 -c "import json; r=json.loads('''$profiles'''); r.append({'profile':'$prof','resource':'$res','limit':'$lim'}); print(json.dumps(r))")
                ;;
            __PUBLIC__*)
                IFS='|' read -r _ priv obj <<<"$line"
                public_grants=$(python3 -c "import json; r=json.loads('''$public_grants'''); r.append({'privilege':'$priv','object':'$obj'}); print(json.dumps(r))")
                ;;
            __TDE__*)
                IFS='|' read -r _ ts enc <<<"$line"
                tde=$(python3 -c "import json; r=json.loads('''$tde'''); r.append({'tablespace':'$ts','encrypted':'$enc' == 'YES'}); print(json.dumps(r))")
                ;;
            __AUDIT__*)
                IFS='|' read -r _ pol opt <<<"$line"
                audit=$(python3 -c "import json; r=json.loads('''$audit'''); r.append({'policy':'$pol','option':'$opt'}); print(json.dumps(r))")
                ;;
        esac
    done <<<"$findings"

    # Synthesize issues list
    dba_count=$(python3 -c "import json; print(len(json.loads('''$dba_members''')))")
    defpwd_count=$(python3 -c "import json; print(len(json.loads('''$def_pwd''')))")
    public_count=$(python3 -c "import json; print(len(json.loads('''$public_grants''')))")
    o7=$(python3 -c "import json; print(json.loads('''$params''').get('o7_dictionary_accessibility','FALSE'))")

    issues_json='[]'
    (( dba_count > DBA_WARN_COUNT )) && issues_json=$(python3 -c "import json; r=json.loads('''$issues_json'''); r.append(f'$dba_count DBA-role grantees'); print(json.dumps(r))")
    (( defpwd_count > 0 ))            && issues_json=$(python3 -c "import json; r=json.loads('''$issues_json'''); r.append(f'$defpwd_count account(s) with default password'); print(json.dumps(r))")
    (( public_count > 0 ))            && issues_json=$(python3 -c "import json; r=json.loads('''$issues_json'''); r.append(f'$public_count dangerous PUBLIC grants'); print(json.dumps(r))")
    [[ "$o7" == "TRUE" ]] && issues_json=$(python3 -c "import json; r=json.loads('''$issues_json'''); r.append('O7_DICTIONARY_ACCESSIBILITY=TRUE'); print(json.dumps(r))")

    db_entry=$(python3 -c "
import json
print(json.dumps({
    'database':'$db',
    'dba_members': json.loads('''$dba_members'''),
    'default_password': json.loads('''$def_pwd'''),
    'params': json.loads('''$params'''),
    'profiles': json.loads('''$profiles'''),
    'public_grants': json.loads('''$public_grants'''),
    'tde_state': json.loads('''$tde'''),
    'audit_policies': json.loads('''$audit'''),
    'issues': json.loads('''$issues_json'''),
}))")
    report=$(python3 -c "import json; r=json.loads('''$report'''); r.append(json.loads('''$db_entry''')); print(json.dumps(r))")
done

total_issues=$(python3 -c "import json; print(sum(len(d['issues']) for d in json.loads('''$report''')))")
summary="{\"timestamp\":\"$(ts)\",\"total_issues\":$total_issues,\"databases\":$report}"
write_status_file "security_audit" "$summary"
echo "$summary"
log "=== SecurityAudit total_issues=$total_issues ==="
exit $(( total_issues > 0 ? 1 : 0 ))
