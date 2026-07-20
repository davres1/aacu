#!/usr/bin/env bash
# SecurityAudit.sh [db ...] — read-only MariaDB/MariaDB security audit.
# Per connection (mirrors the Db2 per-database loop) it reports:
#   * sysadmins    — accounts with SUPER or ALL PRIVILEGES (DBADM/SECADM analog)
#   * weak_logins  — password-plugin accounts with an empty authentication string
#   * stale_logins — accounts whose password_last_changed is older than a threshold
#   * public_perms — accounts reachable from any host ('%') — the PUBLIC analog
#   * issues       — human-readable findings (incl. absent validate_password,
#                    skip-grant-tables)
#
# Final JSON: {"timestamp","total_issues",
#   "instances":[{database,sysadmins:[{grantee}],weak_logins:[{grantee}],
#                 stale_logins:[{grantee}],public_perms:[{grantee}],issues:[...]}]}
source "$(dirname "$0")/lib/mariadb_common.sh"

SYSADMIN_WARN="$(get_threshold security_audit.sysadmin_warn_count 5)"
STALE_DAYS="$(get_threshold security_audit.stale_days 365)"
DBS="${*:-$(list_databases)}"
rows=""

for db in $DBS; do
    sysadmins="$(printf '%s' "SELECT DISTINCT GRANTEE FROM information_schema.USER_PRIVILEGES WHERE PRIVILEGE_TYPE IN ('SUPER','ALL PRIVILEGES');" | sqlx "$db" 2>/dev/null | sed "s/'//g" | awk 'NF{print}' | paste -sd, -)"
    weak="$(printf '%s' "SELECT CONCAT(user,'@',host) FROM mysql.user WHERE plugin IN ('mysql_native_password','caching_sha2_password','') AND (authentication_string='' OR authentication_string IS NULL);" | sqlx "$db" 2>/dev/null | awk 'NF{print}' | paste -sd, -)"
    stale="$(printf '%s' "SELECT CONCAT(user,'@',host) FROM mysql.user WHERE password_last_changed IS NOT NULL AND password_last_changed < (NOW() - INTERVAL ${STALE_DAYS} DAY);" | sqlx "$db" 2>/dev/null | awk 'NF{print}' | paste -sd, -)"
    public="$(printf '%s' "SELECT CONCAT(user,'@',host) FROM mysql.user WHERE host='%';" | sqlx "$db" 2>/dev/null | awk 'NF{print}' | paste -sd, -)"
    vp_active="$(scalar "$db" "SELECT COUNT(*) FROM information_schema.PLUGINS WHERE PLUGIN_NAME LIKE 'validate_password%' AND PLUGIN_STATUS='ACTIVE';")"
    skip_grant="$(scalar "$db" "SELECT @@GLOBAL.skip_grant_tables;")"
    rows+="${db}|${sysadmins}|${weak}|${stale}|${public}|${vp_active:-0}|${skip_grant:-0}"$'\n'
done

printf '%s' "$rows" | python3 - "$SYSADMIN_WARN" "$STALE_DAYS" <<'PY'
import json, sys, datetime
sysadmin_warn = int(sys.argv[1] or 5)
stale_days = sys.argv[2] or "365"
insts, total = [], 0
for line in sys.stdin.read().splitlines():
    if not line.strip():
        continue
    db, sysadmins, weak, stale, public, vp, skip = (line.split('|') + ['']*7)[:7]
    sysadmin_m = [x for x in sysadmins.split(',') if x]
    weak_m     = [x for x in weak.split(',')     if x]
    stale_m    = [x for x in stale.split(',')    if x]
    public_m   = [x for x in public.split(',')   if x]
    try: vp_active = int(vp)
    except ValueError: vp_active = 0
    try: skip_on = int(skip)
    except ValueError: skip_on = 0
    issues = []
    if len(sysadmin_m) > sysadmin_warn:
        issues.append(f"{len(sysadmin_m)} SUPER/ALL-PRIVILEGES grantees (warn>{sysadmin_warn})")
    if weak_m:
        issues.append(f"{len(weak_m)} logins with empty password")
    if stale_m:
        issues.append(f"{len(stale_m)} logins unchanged > {stale_days} days")
    if public_m:
        issues.append(f"{len(public_m)} accounts allow any host ('%')")
    if vp_active == 0:
        issues.append("validate_password plugin not active")
    if skip_on == 1:
        issues.append("skip-grant-tables is enabled")
    total += len(issues)
    insts.append({
        "database": db,
        "sysadmins":    [{"grantee": g} for g in sysadmin_m],
        "weak_logins":  [{"grantee": g} for g in weak_m],
        "stale_logins": [{"grantee": g} for g in stale_m],
        "public_perms": [{"grantee": g} for g in public_m],
        "issues": issues,
    })
print(json.dumps({
    "timestamp": datetime.datetime.now().strftime("%Y-%m-%dT%H:%M:%S"),
    "total_issues": total, "instances": insts,
}))
PY
