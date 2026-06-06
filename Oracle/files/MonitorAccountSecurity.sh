#!/usr/bin/env bash
# MonitorAccountSecurity.sh — Oracle equivalent of MonitorAccountSecurity.ps1.
# Detects:
#   - Accounts with failed-login counts at threshold
#   - LOCKED / LOCKED(TIMED) accounts that should re-open
#   - Default-password accounts (DBA_USERS_WITH_DEFPWD)
#   - Expired or about-to-expire passwords
# Auto-locks accounts that exceed the failed-attempt threshold (matches the
# original SQL Server behaviour).

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/oracle_common.sh"

FAILED_THRESHOLD="${FAILED_THRESHOLD:-5}"
AUTO_LOCK="${AUTO_LOCK:-1}"
report='[]'

databases=("$@")
[[ ${#databases[@]} -eq 0 ]] && mapfile -t databases < <(list_databases)

for db in "${databases[@]}"; do
    log "→ $db"
    rows=$(sql "$db" sys <<SQL 2>/dev/null || true
SELECT '__BADTRY__|' || u.username || '|' || u.failed_login_attempts
  FROM (
    SELECT u.username, p.limit AS max_attempts
      FROM dba_users u
      JOIN dba_profiles p
        ON p.profile = u.profile AND p.resource_name = 'FAILED_LOGIN_ATTEMPTS'
     WHERE u.account_status NOT LIKE 'LOCKED%'
       AND u.username NOT IN ('SYS','SYSTEM')
  ) u
  JOIN (
    SELECT username,
           NVL(MAX(returncode), 0) AS failed_login_attempts
      FROM dba_audit_session
     WHERE timestamp > SYSDATE - 1
       AND action_name = 'LOGON'
       AND returncode != 0
     GROUP BY username
  ) f ON u.username = f.username
 WHERE f.failed_login_attempts >= $FAILED_THRESHOLD;

SELECT '__LOCKED__|' || username || '|' || account_status
  FROM dba_users
 WHERE account_status LIKE 'LOCKED%';

SELECT '__DEFPWD__|' || username
  FROM dba_users_with_defpwd
 WHERE username NOT IN ('XS\$NULL');

SELECT '__EXPIRING__|' || username || '|' ||
       TO_CHAR(expiry_date, 'YYYY-MM-DD')
  FROM dba_users
 WHERE expiry_date BETWEEN SYSDATE AND SYSDATE + 14;
SQL
)

    bad='[]'; locked='[]'; defpwd='[]'; expiring='[]'; auto_locked='[]'
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        if [[ "$line" == __BADTRY__* ]]; then
            IFS='|' read -r _ u cnt <<<"$line"
            row=$(python3 -c "import json; print(json.dumps({'user':'$u','failed_attempts':int('$cnt' or 0)}))")
            bad=$(python3 -c "import json; r=json.loads('''$bad'''); r.append(json.loads('''$row''')); print(json.dumps(r))")
            if (( AUTO_LOCK )); then
                warn "   AUTO-LOCKING $u ($cnt failed attempts)"
                if sql "$db" sys <<SLQ >/dev/null 2>&1
ALTER USER "$u" ACCOUNT LOCK;
SLQ
                then
                    row=$(python3 -c "import json; print(json.dumps({'user':'$u'}))")
                    auto_locked=$(python3 -c "import json; r=json.loads('''$auto_locked'''); r.append(json.loads('''$row''')); print(json.dumps(r))")
                fi
            fi
        elif [[ "$line" == __LOCKED__* ]]; then
            IFS='|' read -r _ u st <<<"$line"
            row=$(python3 -c "import json; print(json.dumps({'user':'$u','status':'$st'}))")
            locked=$(python3 -c "import json; r=json.loads('''$locked'''); r.append(json.loads('''$row''')); print(json.dumps(r))")
        elif [[ "$line" == __DEFPWD__* ]]; then
            IFS='|' read -r _ u <<<"$line"
            row=$(python3 -c "import json; print(json.dumps({'user':'$u'}))")
            defpwd=$(python3 -c "import json; r=json.loads('''$defpwd'''); r.append(json.loads('''$row''')); print(json.dumps(r))")
        elif [[ "$line" == __EXPIRING__* ]]; then
            IFS='|' read -r _ u dt <<<"$line"
            row=$(python3 -c "import json; print(json.dumps({'user':'$u','expires':'$dt'}))")
            expiring=$(python3 -c "import json; r=json.loads('''$expiring'''); r.append(json.loads('''$row''')); print(json.dumps(r))")
        fi
    done <<<"$rows"

    db_entry=$(python3 -c "
import json
print(json.dumps({
    'database':'$db',
    'failed_login_accounts': json.loads('''$bad'''),
    'locked_accounts':       json.loads('''$locked'''),
    'default_password':      json.loads('''$defpwd'''),
    'expiring_passwords':    json.loads('''$expiring'''),
    'auto_locked':           json.loads('''$auto_locked'''),
}))")
    report=$(python3 -c "import json; r=json.loads('''$report'''); r.append(json.loads('''$db_entry''')); print(json.dumps(r))")
done

summary="{\"timestamp\":\"$(ts)\",\"failed_threshold\":$FAILED_THRESHOLD,\"databases\":$report}"
write_status_file "account_security" "$summary"
echo "$summary"
log "=== MonitorAccountSecurity done ==="
