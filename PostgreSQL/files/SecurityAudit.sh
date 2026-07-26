#!/usr/bin/env bash
# SecurityAudit.sh [db ...] — read-only PostgreSQL security audit.
# Per connection (mirrors the Db2 per-database loop) it reports:
#   * sysadmins    — roles with superuser privilege (SECADM/DBADM analog)
#   * weak_logins  — roles that can login but have no password set
#   * stale_logins — roles not seen active in the last N days (pg_stat_activity proxy)
#   * public_perms — roles with GRANT OPTION (privilege escalation risk)
#   * issues       — human-readable findings (trust auth, ssl off, no password policy)
#
# Final JSON: {"timestamp","total_issues",
#   "instances":[{database,sysadmins:[{grantee}],weak_logins:[{grantee}],
#                 stale_logins:[{grantee}],public_perms:[{grantee}],issues:[...]}]}
source "$(dirname "$0")/lib/pg_common.sh"

SYSADMIN_WARN="$(get_threshold security_audit.sysadmin_warn_count 5)"
STALE_DAYS="$(get_threshold security_audit.stale_days 365)"
DBS="${*:-$(list_databases)}"
rows=""

for db in $DBS; do
    sysadmins="$(printf '%s\n' \
        "SELECT usename FROM pg_user WHERE usesuper = true ORDER BY usename;" \
        | sqlx "$db" 2>/dev/null | awk 'NF{print}' | paste -sd, -)"

    weak="$(printf '%s\n' \
        "SELECT rolname FROM pg_authid
         WHERE rolcanlogin = true AND rolpassword IS NULL AND NOT rolsuper
         ORDER BY rolname;" \
        | sqlx "$db" 2>/dev/null | awk 'NF{print}' | paste -sd, -)"

    stale="$(printf '%s\n' \
        "SELECT r.rolname
         FROM pg_roles r
         WHERE r.rolcanlogin = true
           AND NOT r.rolsuper
           AND r.rolname NOT IN (
               SELECT DISTINCT usename FROM pg_stat_activity
               WHERE query_start > now() - interval '${STALE_DAYS} days'
               AND usename IS NOT NULL
           )
         ORDER BY r.rolname;" \
        | sqlx "$db" 2>/dev/null | awk 'NF{print}' | paste -sd, -)"

    public="$(printf '%s\n' \
        "SELECT DISTINCT grantee
         FROM information_schema.role_table_grants
         WHERE is_grantable = 'YES'
           AND grantee NOT IN ('postgres','pg_monitor','pg_read_all_stats')
         ORDER BY grantee;" \
        | sqlx "$db" 2>/dev/null | awk 'NF{print}' | paste -sd, -)"

    ssl_on="$(scalar "$db" "SHOW ssl")"

    trust_count="$(scalar "$db" \
        "SELECT COUNT(*) FROM pg_hba_file_rules WHERE auth_method = 'trust'" 2>/dev/null || echo 0)"

    rows+="${db}|${sysadmins}|${weak}|${stale}|${public}|${ssl_on:-off}|${trust_count:-0}"$'\n'
done

printf '%s' "$rows" | python3 - "$SYSADMIN_WARN" "$STALE_DAYS" <<'PY'
import json, sys, datetime
sysadmin_warn = int(sys.argv[1] or 5)
stale_days = sys.argv[2] or "365"
insts, total = [], 0
for line in sys.stdin.read().splitlines():
    if not line.strip():
        continue
    db, sysadmins, weak, stale, public, ssl, trust = (line.split('|') + ['']*7)[:7]
    sysadmin_m = [x for x in sysadmins.split(',') if x]
    weak_m     = [x for x in weak.split(',')     if x]
    stale_m    = [x for x in stale.split(',')    if x]
    public_m   = [x for x in public.split(',')   if x]
    ssl_on = ssl.strip().lower() in ('on', 'yes', 'true')
    try: trust_n = int(trust)
    except ValueError: trust_n = 0
    issues = []
    if len(sysadmin_m) > sysadmin_warn:
        issues.append(f"{len(sysadmin_m)} superuser roles (warn>{sysadmin_warn})")
    if weak_m:
        issues.append(f"{len(weak_m)} logins with no password set")
    if stale_m:
        issues.append(f"{len(stale_m)} login roles inactive > {stale_days} days")
    if public_m:
        issues.append(f"{len(public_m)} roles have GRANT OPTION (privilege escalation risk)")
    if not ssl_on:
        issues.append("ssl is OFF — connections are unencrypted")
    if trust_n > 0:
        issues.append(f"{trust_n} pg_hba trust auth entr(ies) — no password required")
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
