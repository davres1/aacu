#!/usr/bin/env bash
# VerifyBackups.sh [db ...] — backup age + a lightweight integrity verify.
# MySQL backups are files on disk (there is no DB_HISTORY catalog), so ages are
# derived from the newest artifact under $BACKUP_ROOT/<db>/ (full_*.sql.gz) and
# the newest archived binlog under $BACKUP_ROOT/binlogs/. Flags anything older
# than the configured SLA (thresholds.json backups.full_max_age_hours /
# log_max_age_hours). The verify is a cheap `gzip -t` of the newest full dump.
#
# Final JSON: {"timestamp","stale_full","stale_log",
#              "ages":[{"database","last_full","full_age_h","full_stale",
#                       "last_log","log_age_h","log_stale"}],
#              "verifies":[{"database","verified","detail"}]}
source "$(dirname "$0")/lib/mysql_common.sh"

FULL_MAX_H="$(get_threshold backups.full_max_age_hours 24)"
LOG_MAX_H="$(get_threshold backups.log_max_age_hours 1)"
BACKUP_ROOT="${BACKUP_ROOT:-/backup/mysql}"
DBS="${*:-$(list_databases)}"
rows=""

# Archived binlogs are instance-wide; compute the newest one once.
last_log_epoch=""
last_log_file="$(ls -1t "$BACKUP_ROOT"/binlogs/* 2>/dev/null | head -1)"
if [ -n "$last_log_file" ] && [ -e "$last_log_file" ]; then
    last_log_epoch="$(date -r "$last_log_file" +%s 2>/dev/null)"
fi

for db in $DBS; do
    # Newest full logical dump for this schema.
    full_file="$(ls -1t "$BACKUP_ROOT/$db"/full_*.sql.gz 2>/dev/null | head -1)"
    full_epoch=""; verified="unknown"; detail=""
    if [ -n "$full_file" ] && [ -e "$full_file" ]; then
        full_epoch="$(date -r "$full_file" +%s 2>/dev/null)"
        # Lightweight verify: confirm the gzip stream is intact.
        if gzip -t "$full_file" >/dev/null 2>&1; then
            verified="ok"; detail="$(basename "$full_file") gzip ok"
        else
            verified="failed"; detail="$(basename "$full_file") gzip corrupt"
        fi
    else
        verified="missing"; detail="no full backup found"
    fi
    rows+="${db}|${full_epoch}|${last_log_epoch}|${verified}|${detail}"$'\n'
done

printf '%s' "$rows" | python3 - "$FULL_MAX_H" "$LOG_MAX_H" <<'PY'
import json, sys, datetime
full_max, log_max = float(sys.argv[1] or 24), float(sys.argv[2] or 1)
now = datetime.datetime.now()
def age_h(epoch):
    s = (epoch or '').strip()
    if not s:
        return None
    try:
        dt = datetime.datetime.fromtimestamp(int(s))
    except (ValueError, OSError):
        return None
    return round((now - dt).total_seconds() / 3600.0, 1)
def iso(epoch):
    s = (epoch or '').strip()
    if not s:
        return None
    try:
        return datetime.datetime.fromtimestamp(int(s)).strftime("%Y-%m-%dT%H:%M:%S")
    except (ValueError, OSError):
        return None
ages, verifies, stale_full, stale_log = [], [], 0, 0
for line in sys.stdin.read().splitlines():
    if not line.strip(): continue
    db, fe, le, verified, detail = (line.split('|') + ['']*5)[:5]
    fa, la = age_h(fe), age_h(le)
    fstale = fa is None or fa > full_max
    lstale = la is None or la > log_max
    if fstale: stale_full += 1
    if lstale: stale_log += 1
    ages.append({
        "database": db,
        "last_full": iso(fe), "full_age_h": fa, "full_stale": fstale,
        "last_log": iso(le), "log_age_h": la, "log_stale": lstale,
    })
    verifies.append({"database": db, "verified": verified, "detail": detail})
print(json.dumps({
    "timestamp": now.strftime("%Y-%m-%dT%H:%M:%S"),
    "stale_full": stale_full, "stale_log": stale_log,
    "ages": ages, "verifies": verifies,
}))
PY
