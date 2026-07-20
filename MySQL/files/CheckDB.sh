#!/usr/bin/env bash
# CheckDB.sh [db ...] — logical/physical integrity via mysqlcheck (CHECK TABLE).
# Writes the result to $STATUS_DIR/checkdb_status.json (read back, fast, by
# GetCheckDBStatus.sh). For InnoDB, CHECK TABLE is a lightweight logical scan;
# deep page-level corruption is caught at the engine level (innodb checksums) —
# note this is not a full physical verify. Heavy-ish — scheduled, not run from
# the chatbot.
#
# Final JSON: {"timestamp","total","clean","errors","failed",
#              "items":[{"database","status","duration_sec","log"}]}
source "$(dirname "$0")/lib/mysql_common.sh"

DBS="${*:-$(list_databases)}"
rows=""

# Private [client] defaults file so the password never hits the process list.
make_cnf() {
    local db="$1" creds user pw host port f
    creds="$(db_credentials "$db")" || return 2
    IFS=$'\t' read -r user pw host port <<<"$creds"
    f="$(mktemp)"; chmod 600 "$f"
    {
        printf '[client]\n'
        printf 'user=%s\n' "$user"
        [ -n "$pw"   ] && printf 'password=%s\n' "$pw"
        [ -n "$host" ] && printf 'host=%s\n' "$host"
        [ -n "$port" ] && printf 'port=%s\n' "$port"
    } > "$f"
    printf '%s' "$f"
}

for db in $DBS; do
    logf="$LOG_DIR/checkdb_${db}_$(date +%Y%m%d_%H%M%S).out"
    start=$(date +%s)
    if [ "$(scalar "$db" "SELECT 1")" = "1" ]; then
        cnf="$(make_cnf "$db")"
        if [ -z "$cnf" ]; then
            status="failed"; printf 'no credentials for %s\n' "$db" >"$logf"
        elif mysqlcheck --defaults-extra-file="$cnf" --check --databases "$db" >"$logf" 2>&1; then
            # mysqlcheck exits 0 even when a table reports a problem, so scan
            # the output for anything that isn't a clean "OK" line.
            if grep -qiE 'error|corrupt|crashed' "$logf"; then
                status="errors"
            else
                status="clean"
            fi
        else
            status="errors"
        fi
        [ -n "$cnf" ] && rm -f "$cnf"
    else
        status="failed"
        printf 'connection to %s failed\n' "$db" >"$logf"
    fi
    dur=$(( $(date +%s) - start ))
    rows+="${db}|${status}|${dur}|${logf}"$'\n'
done

result="$(printf '%s' "$rows" | python3 - <<'PY'
import json, sys, datetime
items, clean, errors, failed = [], 0, 0, 0
for line in sys.stdin.read().splitlines():
    if not line.strip(): continue
    db, status, dur, logf = (line.split('|') + ['']*4)[:4]
    if status == "clean": clean += 1
    elif status == "errors": errors += 1
    else: failed += 1
    items.append({"database": db, "status": status,
                  "duration_sec": int(dur or 0), "log": logf})
print(json.dumps({
    "timestamp": datetime.datetime.now().strftime("%Y-%m-%dT%H:%M:%S"),
    "total": len(items), "clean": clean, "errors": errors, "failed": failed,
    "items": items,
}))
PY
)"
write_status_file checkdb_status "$result"
printf '%s\n' "$result"
