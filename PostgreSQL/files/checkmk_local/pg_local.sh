#!/usr/bin/env bash
# pg_local.sh — fast CheckMK local check (default interval ~60s):
# instance up (pg_isready), connection usage, replication state per standby in
# pg_stat_replication, and per-database lock waits.
# Output format:  <status> <item> <metrics> <text>
LIB="/opt/dba/scripts/lib/pg_common.sh"
[[ -f "$LIB" ]] || LIB="$(dirname "$0")/../lib/pg_common.sh"
source "$LIB" 2>/dev/null || { echo "3 PostgreSQL_Agent - pg_common.sh not found"; exit 0; }

DBS="$(list_databases)"
primary="$(printf '%s\n' "$DBS" | head -1)"

# --- Instance up + server-wide metrics ---
if [[ -n "$primary" ]] && [[ "$(scalar "$primary" "SELECT 1" 2>/dev/null)" == "1" ]]; then
    emit_checkmk 0 PostgreSQL_Instance - "instance reachable via ${primary}"

    # Connection count vs max_connections.
    conn="$(scalar "$primary" "SELECT count(*) FROM pg_stat_activity" 2>/dev/null)"
    maxc="$(scalar "$primary" "SHOW max_connections" 2>/dev/null)"
    conn="${conn:-0}"; maxc="${maxc:-100}"
    [[ "$conn" =~ ^[0-9]+$ ]] || conn=0
    [[ "$maxc" =~ ^[0-9]+$ ]] || maxc=100
    pct=0; (( maxc > 0 )) && pct=$(( conn * 100 / maxc ))
    st=0; (( pct >= 80 )) && st=1; (( pct >= 90 )) && st=2
    emit_checkmk "$st" PostgreSQL_Connections \
        "conn=${conn};;;0;${maxc}|used_pct=${pct};80;90" \
        "${conn}/${maxc} connections (${pct}%)"

    # --- Replication: report each standby from pg_stat_replication ---
    LAG_WARN="$(get_threshold replication.lag_warn_sec 30)"
    LAG_CRIT="$(get_threshold replication.lag_crit_sec 120)"

    in_recovery="$(scalar "$primary" "SELECT pg_is_in_recovery()" 2>/dev/null)"
    if [ "${in_recovery,,}" = "f" ] || [ "${in_recovery,,}" = "false" ]; then
        while IFS='|' read -r client_addr state replay_lag sync_state; do
            [[ -z "$client_addr" ]] && continue
            try_lag="${replay_lag:-0}"; [[ "$try_lag" =~ ^[0-9]+$ ]] || try_lag=0
            st=0
            [[ "$state" != "streaming" ]] && st=2
            (( try_lag >= LAG_WARN )) && (( st < 1 )) && st=1
            (( try_lag >= LAG_CRIT )) && st=2
            safe_addr="${client_addr//\//_}"
            emit_checkmk "$st" "PG_Replication_${safe_addr}" \
                "replay_lag=${try_lag};${LAG_WARN};${LAG_CRIT}" \
                "standby=${client_addr} state=${state} lag=${try_lag}s sync=${sync_state}"
        done < <(printf '%s\n' \
            "SELECT COALESCE(client_addr::text,'socket'),
                    state,
                    COALESCE(EXTRACT(EPOCH FROM replay_lag)::int::text,'0'),
                    sync_state
             FROM pg_stat_replication;" \
            | sqlx "$primary" 2>/dev/null)
    else
        # Standby: check WAL receiver status.
        wal_status="$(scalar "$primary" \
            "SELECT status FROM pg_stat_wal_receiver LIMIT 1" 2>/dev/null)"
        lag_sec="$(scalar "$primary" \
            "SELECT EXTRACT(EPOCH FROM (now()-last_msg_receipt_time))::int
             FROM pg_stat_wal_receiver LIMIT 1" 2>/dev/null)"
        lag_sec="${lag_sec:-0}"; [[ "$lag_sec" =~ ^[0-9]+$ ]] || lag_sec=0
        st=0; (( lag_sec >= LAG_WARN )) && st=1; (( lag_sec >= LAG_CRIT )) && st=2
        [[ -z "$wal_status" ]] && st=2
        emit_checkmk "$st" "PG_WAL_Receiver" \
            "lag=${lag_sec};${LAG_WARN};${LAG_CRIT}" \
            "wal_receiver=${wal_status:-unknown} lag=${lag_sec}s"
    fi
else
    emit_checkmk 2 PostgreSQL_Instance - "instance DOWN (no database reachable)"
fi

# --- Quick per-database checks: current lock waits ---
for db in $DBS; do
    blk="$(scalar "$db" "SELECT COUNT(*) FROM pg_locks WHERE NOT granted" 2>/dev/null)"
    blk="${blk:-0}"; [[ "$blk" =~ ^[0-9]+$ ]] || blk=0
    st=0; (( blk >= 1 )) && st=1; (( blk >= 10 )) && st=2
    emit_checkmk "$st" "PG_Blocking_${db}" \
        "blocked=${blk};1;10" "${blk} lock wait(s) in ${db}"
done
