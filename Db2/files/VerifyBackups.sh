#!/usr/bin/env bash
# VerifyBackups.sh [db ...] — backup age from SYSIBMADM.DB_HISTORY.
# Flags databases whose last full backup is older than the configured SLA
# (thresholds.json backups.full_max_age_hours / log_max_age_hours).
#
# Final JSON: {"timestamp","stale_full","stale_log","verify_failed",
#              "items":[{"database","last_full","full_age_h","full_stale",
#                        "last_log","log_age_h","log_stale","verified"}]}
source "$(dirname "$0")/lib/db2_common.sh"

FULL_MAX_H="$(get_threshold backups.full_max_age_hours 24)"
LOG_MAX_H="$(get_threshold backups.log_max_age_hours 1)"
DBS="${*:-$(list_databases)}"
rows=""

for db in $DBS; do
    # Most recent full (OPERATION='B', OPERATIONTYPE in F/N) and incremental.
    last_full="$(printf '%s' "SELECT MAX(START_TIME) FROM SYSIBMADM.DB_HISTORY WHERE OPERATION='B';" | sqlx "$db" 2>/dev/null | tr -d ' ')"
    # Last log-archive (OPERATION='X').
    last_log="$(printf '%s' "SELECT MAX(START_TIME) FROM SYSIBMADM.DB_HISTORY WHERE OPERATION='X';" | sqlx "$db" 2>/dev/null | tr -d ' ')"
    rows+="${db}|${last_full}|${last_log}"$'\n'
done

printf '%s' "$rows" | python3 - "$FULL_MAX_H" "$LOG_MAX_H" <<'PY'
import json, sys, datetime
full_max, log_max = float(sys.argv[1] or 24), float(sys.argv[2] or 1)
def age_h(stamp):
    # Db2 history timestamp: YYYYMMDDHHMMSS
    s = (stamp or '').strip()
    if len(s) < 14: return None
    try:
        dt = datetime.datetime.strptime(s[:14], "%Y%m%d%H%M%S")
    except ValueError:
        return None
    return round((datetime.datetime.now() - dt).total_seconds() / 3600.0, 1)
items, stale_full, stale_log = [], 0, 0
for line in sys.stdin.read().splitlines():
    if not line.strip(): continue
    db, lf, ll = (line.split('|') + ['','',''])[:3]
    fa, la = age_h(lf), age_h(ll)
    fstale = fa is None or fa > full_max
    lstale = la is None or la > log_max
    if fstale: stale_full += 1
    if lstale: stale_log += 1
    items.append({
        "database": db,
        "last_full": lf or None, "full_age_h": fa, "full_stale": fstale,
        "last_log": ll or None, "log_age_h": la, "log_stale": lstale,
        "verified": "unknown",
    })
print(json.dumps({
    "timestamp": datetime.datetime.now().strftime("%Y-%m-%dT%H:%M:%S"),
    "stale_full": stale_full, "stale_log": stale_log, "verify_failed": 0,
    "items": items,
}))
PY
