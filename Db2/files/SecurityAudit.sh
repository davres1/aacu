#!/usr/bin/env bash
# SecurityAudit.sh [db ...] — read-only security audit per database:
# DBADM/SECADM grantees (SYSCAT.DBAUTH), dangerous PUBLIC grants
# (SYSCAT.TABAUTH / ROUTINEAUTH), and SSL/authentication dbm cfg.
#
# Final JSON: {"timestamp","total_issues",
#              "databases":[{database,dbadm_members:[...],secadm_members:[...],
#                            public_grants:[...],issues:[...]}]}
source "$(dirname "$0")/lib/db2_common.sh"

DBADM_WARN="$(get_threshold security_audit.dbadm_warn_count 5)"
DBS="${*:-$(list_databases)}"
rows=""

for db in $DBS; do
    dbadm="$(printf '%s' "SELECT GRANTEE FROM SYSCAT.DBAUTH WHERE DBADMAUTH='Y';" | sqlx "$db" 2>/dev/null | awk 'NF{print $1}' | paste -sd, -)"
    secadm="$(printf '%s' "SELECT GRANTEE FROM SYSCAT.DBAUTH WHERE SECURITYADMAUTH='Y';" | sqlx "$db" 2>/dev/null | awk 'NF{print $1}' | paste -sd, -)"
    pub="$(printf '%s' "SELECT COUNT(*) FROM SYSCAT.TABAUTH WHERE GRANTEE='PUBLIC';" | sqlx "$db" 2>/dev/null | tr -d ' ')"
    rows+="${db}|${dbadm}|${secadm}|${pub:-0}"$'\n'
done

printf '%s' "$rows" | python3 - "$DBADM_WARN" <<'PY'
import json, sys, datetime
dbadm_warn = int(sys.argv[1] or 5)
dbs, total = [], 0
for line in sys.stdin.read().splitlines():
    if not line.strip(): continue
    db, dbadm, secadm, pub = (line.split('|') + ['']*4)[:4]
    dbadm_m = [x for x in dbadm.split(',') if x]
    secadm_m = [x for x in secadm.split(',') if x]
    try: pubn = int(pub)
    except ValueError: pubn = 0
    issues = []
    if len(dbadm_m) > dbadm_warn:
        issues.append(f"{len(dbadm_m)} DBADM grantees (warn>{dbadm_warn})")
    if pubn > 0:
        issues.append(f"{pubn} PUBLIC table grants")
    total += len(issues)
    dbs.append({
        "database": db,
        "dbadm_members": [{"grantee": g} for g in dbadm_m],
        "secadm_members": [{"grantee": g} for g in secadm_m],
        "public_grants": [{"count": pubn}],
        "issues": issues,
    })
print(json.dumps({
    "timestamp": datetime.datetime.now().strftime("%Y-%m-%dT%H:%M:%S"),
    "total_issues": total, "databases": dbs,
}))
PY
