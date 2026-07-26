#!/usr/bin/env bash
# MonitorReplication.sh [db ...] — replica role + lag, ported from the Db2 HADR
# monitor (SYSIBMADM.SNAPHADR). Uses pg_stat_replication on the primary to see
# connected standbys, and pg_stat_wal_receiver on standbys to get receive lag.
# Role is detected via SELECT pg_is_in_recovery(). Db2's HADR_ROLE maps to
# PRIMARY / STANDBY / STANDALONE.
# Emits the same shape as the Db2/MySQL monitor so the shared replication view
# renders unchanged.
#
# Final JSON: {"timestamp","critical","warning",
#              "databases":[{database,role,state,
#                            lag_metrics:[{name,value}],severity}]}
source "$(dirname "$0")/lib/pg_common.sh"

LAG_WARN="$(get_threshold replication.lag_warn_sec 30)"
LAG_CRIT="$(get_threshold replication.lag_crit_sec 120)"
DBS="${*:-$(list_databases)}"
rows=""

for db in $DBS; do
    # Detect role.
    in_recovery="$(scalar "$db" "SELECT pg_is_in_recovery()")"

    if [ "${in_recovery,,}" = "f" ] || [ "${in_recovery,,}" = "false" ]; then
        # PRIMARY: read pg_stat_replication for connected standbys.
        replicas="$(printf '%s\n' \
            "SELECT client_addr::text,
                    state,
                    COALESCE(EXTRACT(EPOCH FROM write_lag)::int::text, '0'),
                    COALESCE(EXTRACT(EPOCH FROM flush_lag)::int::text, '0'),
                    COALESCE(EXTRACT(EPOCH FROM replay_lag)::int::text, '0'),
                    sync_state
             FROM pg_stat_replication
             ORDER BY client_addr;" \
            | sqlx "$db" 2>/dev/null)"

        if [ -n "${replicas// }" ]; then
            role="PRIMARY"
        else
            # Check if it's a standalone or just has no connected standbys.
            role="PRIMARY"
        fi
        rows+="${db}|${role}|${replicas}"$'\n'
    else
        # STANDBY: read pg_stat_wal_receiver.
        wal_rcv="$(printf '%s\n' \
            "SELECT status,
                    received_lsn::text,
                    COALESCE(EXTRACT(EPOCH FROM (now() - last_msg_receipt_time))::int::text, '-1')
             FROM pg_stat_wal_receiver
             LIMIT 1;" \
            | sqlx "$db" 2>/dev/null | head -1)"
        rows+="${db}|STANDBY|${wal_rcv}"$'\n'
    fi
done

printf '%s' "$rows" | python3 - "$LAG_WARN" "$LAG_CRIT" <<'PY'
import json, sys, datetime
lag_warn, lag_crit = float(sys.argv[1]), float(sys.argv[2])

dbs, crit, warn = [], 0, 0
for line in sys.stdin.read().splitlines():
    if not line.strip():
        continue
    parts = line.split('|')
    db = parts[0]
    role = parts[1] if len(parts) > 1 else "STANDALONE"

    if role == "PRIMARY":
        # parts[2:] are replica rows (each pipe-joined).
        # Collect all replica data for lag metrics.
        replica_rows = []
        for rline in parts[2:]:
            if not rline.strip():
                continue
            # Each rline: client_addr|state|write_lag|flush_lag|replay_lag|sync_state
            rf = (rline.split('|') + ['']*6)[:6]
            replica_rows.append(rf)

        max_replay_lag = 0
        lag_parts = []
        for rf in replica_rows:
            addr, state, wlag, flag, rlag, sync = rf
            try: rlag_v = int(rlag)
            except ValueError: rlag_v = 0
            max_replay_lag = max(max_replay_lag, rlag_v)
            lag_parts.append(f"{addr}:{rlag_v}s({sync})")

        state_str = "primary"
        sev = "ok"
        if lag_parts:
            if max_replay_lag >= lag_crit:
                sev = "critical"
            elif max_replay_lag >= lag_warn:
                sev = "warning"
        lag_metrics = [
            {"name": "max_replay_lag", "value": f"{max_replay_lag}s"},
            {"name": "standbys", "value": str(len(replica_rows))},
            {"name": "replica_detail", "value": ", ".join(lag_parts) or "none"},
        ]

    elif role == "STANDBY":
        # parts[2]: status|received_lsn|lag_sec (from pg_stat_wal_receiver)
        wal_raw = parts[2] if len(parts) > 2 else ""
        rf = (wal_raw.split('|') + ['', '', '-1'])[:3]
        wal_status, received_lsn, lag_sec_s = rf
        try: lag_sec = int(lag_sec_s)
        except ValueError: lag_sec = -1

        state_str = wal_status.strip() or "unknown"
        sev = "ok"
        if lag_sec < 0 or wal_status.strip() == "":
            sev = "critical"
        elif lag_sec >= lag_crit:
            sev = "critical"
        elif lag_sec >= lag_warn:
            sev = "warning"
        lag_metrics = [
            {"name": "lag", "value": f"{lag_sec}s" if lag_sec >= 0 else "n/a"},
            {"name": "wal_status", "value": wal_status.strip() or "unknown"},
            {"name": "received_lsn", "value": received_lsn.strip()},
        ]
    else:
        state_str = "standalone"
        sev = "ok"
        lag_metrics = [{"name": "lag", "value": "0s"}]

    if sev == "critical":
        crit += 1
    elif sev == "warning":
        warn += 1

    dbs.append({
        "database": db, "role": role, "state": state_str,
        "lag_metrics": lag_metrics, "severity": sev,
    })

print(json.dumps({
    "timestamp": datetime.datetime.now().strftime("%Y-%m-%dT%H:%M:%S"),
    "critical": crit, "warning": warn, "databases": dbs,
}))
PY
