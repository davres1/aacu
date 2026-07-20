#!/usr/bin/env bash
# MonitorReplication.sh [db ...] — replica role + lag, ported from the Db2 HADR
# monitor (SYSIBMADM.SNAPHADR). Uses SHOW REPLICA STATUS (falls back to
# SHOW SLAVE STATUS on older MySQL / MariaDB) for Seconds_Behind_Source and the
# IO/SQL thread state, and GTID sets (gtid_executed vs. the received set) for the
# apply gap. Db2's HADR_ROLE maps to PRIMARY / REPLICA / STANDALONE.
# Emits the same shape as the Db2 monitor so the shared replication view renders.
#
# Final JSON: {"timestamp","critical","warning",
#              "databases":[{database,role,state,
#                            lag_metrics:[{name,value}],severity}]}
source "$(dirname "$0")/lib/mysql_common.sh"

LAG_WARN="$(get_threshold replication.lag_warn_sec 30)"
LAG_CRIT="$(get_threshold replication.lag_crit_sec 120)"
GAP_WARN="$(get_threshold replication.gtid_gap_warn 100)"
DBS="${*:-$(list_databases)}"
rows=""

for db in $DBS; do
    repl="$(printf '%s' "SHOW REPLICA STATUS\G" | sqlx "$db" 2>/dev/null)"
    [[ -z "${repl// }" ]] && repl="$(printf '%s' "SHOW SLAVE STATUS\G" | sqlx "$db" 2>/dev/null)"

    getf() { printf '%s\n' "$repl" | sed -n "s/^[[:space:]]*$1:[[:space:]]//p" | head -1; }

    if [[ -n "${repl// }" ]]; then
        role="REPLICA"
        io="$(getf 'Replica_IO_Running')";  [[ -z "$io" ]]   && io="$(getf 'Slave_IO_Running')"
        sqlr="$(getf 'Replica_SQL_Running')"; [[ -z "$sqlr" ]] && sqlr="$(getf 'Slave_SQL_Running')"
        lag="$(getf 'Seconds_Behind_Source')"; [[ -z "$lag" ]] && lag="$(getf 'Seconds_Behind_Master')"
        executed="$(scalar "$db" "SELECT @@GLOBAL.gtid_executed")"
        retrieved="$(scalar "$db" "SELECT RECEIVED_TRANSACTION_SET FROM performance_schema.replication_connection_status LIMIT 1")"
    else
        downstream="$(printf '%s' "SHOW REPLICAS;" | sqlx "$db" 2>/dev/null)"
        [[ -z "${downstream// }" ]] && downstream="$(printf '%s' "SHOW SLAVE HOSTS;" | sqlx "$db" 2>/dev/null)"
        if [[ -n "${downstream// }" ]]; then role="PRIMARY"; else role="STANDALONE"; fi
        io=""; sqlr=""; lag="0"; executed=""; retrieved=""
    fi

    rows+="${db}|${role}|${io}|${sqlr}|${lag}|${retrieved}|${executed}"$'\n'
done

printf '%s' "$rows" | python3 - "$LAG_WARN" "$LAG_CRIT" "$GAP_WARN" <<'PY'
import json, sys, datetime
lag_warn, lag_crit, gap_warn = float(sys.argv[1]), float(sys.argv[2]), float(sys.argv[3])

def parse_gtid(s):
    # "uuid:1-5:8,uuid2:1-3" -> {uuid: [(start,end),...]}
    out = {}
    for tok in (s or '').replace('\n', '').split(','):
        tok = tok.strip()
        if not tok or ':' not in tok:
            continue
        parts = tok.split(':')
        uuid = parts[0]
        for iv in parts[1:]:
            iv = iv.strip()
            if not iv:
                continue
            if '-' in iv:
                a, b = iv.split('-', 1)
            else:
                a = b = iv
            try:
                out.setdefault(uuid, []).append((int(a), int(b)))
            except ValueError:
                pass
    return out

def gtid_gap(retrieved, executed):
    # count of transactions in `retrieved` not present in `executed`
    r, e = parse_gtid(retrieved), parse_gtid(executed)
    gap = 0
    for uuid, ivs in r.items():
        done = e.get(uuid, [])
        for a, b in ivs:
            for txid in range(a, b + 1):
                if not any(x <= txid <= y for x, y in done):
                    gap += 1
    return gap

dbs, crit, warn = [], 0, 0
for line in sys.stdin.read().splitlines():
    if not line.strip():
        continue
    db, role, io, sqlr, lag, retrieved, executed = (line.split('|') + ['']*7)[:7]
    role = role.strip() or "STANDALONE"
    io, sqlr = io.strip(), sqlr.strip()

    lag_raw = lag.strip()
    lag_null = (lag_raw == '' or lag_raw.upper() == 'NULL')
    try:
        lag_val = float(lag_raw) if not lag_null else 0.0
    except ValueError:
        lag_val, lag_null = 0.0, True

    gap = gtid_gap(retrieved, executed) if role == "REPLICA" else 0

    if role == "REPLICA":
        running = (io == "Yes" and sqlr == "Yes")
        state = "running" if running else "stopped"
        sev = "ok"
        if not running or lag_null or lag_val >= lag_crit:
            sev = "critical"
        elif lag_val >= lag_warn or gap >= gap_warn:
            sev = "warning"
        lag_metrics = [
            {"name": "lag", "value": ("n/a" if lag_null else "%.0fs" % lag_val)},
            {"name": "gtid gap", "value": "%d trx" % gap},
            {"name": "io/sql", "value": "%s/%s" % (io or "?", sqlr or "?")},
        ]
    else:
        state = "primary" if role == "PRIMARY" else "standalone"
        sev = "ok"
        lag_metrics = [
            {"name": "lag", "value": "0s"},
            {"name": "gtid gap", "value": "0 trx"},
        ]

    if sev == "critical":
        crit += 1
    elif sev == "warning":
        warn += 1

    dbs.append({
        "database": db, "role": role, "state": state,
        "lag_metrics": lag_metrics, "severity": sev,
    })

print(json.dumps({
    "timestamp": datetime.datetime.now().strftime("%Y-%m-%dT%H:%M:%S"),
    "critical": crit, "warning": warn, "databases": dbs,
}))
PY
