#!/usr/bin/env bash
# mysql_local.sh — fast CheckMK local check (default interval): instance up,
# connection usage, uptime, replication state and per-schema lock waits.
# Output format:  <status> <item> <metrics> <text>
LIB="/opt/dba/scripts/lib/mariadb_common.sh"; [[ -f "$LIB" ]] || LIB="$(dirname "$0")/../lib/mariadb_common.sh"
source "$LIB" 2>/dev/null || { echo "3 MariaDB_Agent - mariadb_common.sh not found"; exit 0; }

DBS="$(list_databases)"
primary="$(printf '%s\n' "$DBS" | head -1)"

# --- Instance up + server-wide metrics (via the first configured schema) ---
if [[ -n "$primary" ]] && [[ "$(scalar "$primary" "SELECT 1" 2>/dev/null)" == "1" ]]; then
    emit_checkmk 0 MariaDB_Instance - "instance reachable via ${primary}"

    uptime="$(printf '%s' "SHOW GLOBAL STATUS LIKE 'Uptime'" | sqlx "$primary" 2>/dev/null | awk '{print $2}')"
    uptime="${uptime:-0}"; [[ "$uptime" =~ ^[0-9]+$ ]] || uptime=0
    emit_checkmk 0 MariaDB_Uptime "uptime=${uptime}" "up $(( uptime / 86400 ))d (${uptime}s)"

    conn="$(printf '%s' "SHOW GLOBAL STATUS LIKE 'Threads_connected'" | sqlx "$primary" 2>/dev/null | awk '{print $2}')"; conn="${conn:-0}"
    maxc="$(printf '%s' "SHOW GLOBAL VARIABLES LIKE 'max_connections'" | sqlx "$primary" 2>/dev/null | awk '{print $2}')"; maxc="${maxc:-0}"
    [[ "$conn" =~ ^[0-9]+$ ]] || conn=0; [[ "$maxc" =~ ^[0-9]+$ ]] || maxc=0
    pct=0; (( maxc > 0 )) && pct=$(( conn * 100 / maxc ))
    st=0; (( pct >= 80 )) && st=1; (( pct >= 90 )) && st=2
    emit_checkmk "$st" MariaDB_Connections "conn=${conn};;;0;${maxc}|used_pct=${pct};80;90" "${conn}/${maxc} connections (${pct}%)"

    # --- Replication (server-wide; SHOW REPLICA STATUS with SHOW SLAVE fallback) ---
    LAG_WARN="$(get_threshold replication.lag_warn_sec 30)"
    LAG_CRIT="$(get_threshold replication.lag_crit_sec 300)"
    repl="$(printf '%s' "SHOW REPLICA STATUS\G" | sql "$primary" 2>/dev/null)"
    [[ -z "$repl" ]] && repl="$(printf '%s' "SHOW SLAVE STATUS\G" | sql "$primary" 2>/dev/null)"
    if printf '%s' "$repl" | grep -qE 'IO_Running:'; then
        io="$(printf '%s\n' "$repl"  | grep -E 'Replica_IO_Running:|Slave_IO_Running:'   | head -1 | sed 's/.*: *//' | tr -d ' ')"
        sqlt="$(printf '%s\n' "$repl" | grep -E 'Replica_SQL_Running:|Slave_SQL_Running:' | head -1 | sed 's/.*: *//' | tr -d ' ')"
        lag="$(printf '%s\n' "$repl"  | grep -E 'Seconds_Behind_Source:|Seconds_Behind_Master:' | head -1 | sed 's/.*: *//' | tr -d ' ')"
        [[ "$lag" =~ ^[0-9]+$ ]] || lag=""
        st=0
        [[ "$io" != "Yes" || "$sqlt" != "Yes" ]] && st=2
        if [[ -n "$lag" ]]; then
            (( lag >= LAG_WARN )) && (( st < 1 )) && st=1
            (( lag >= LAG_CRIT )) && st=2
        fi
        emit_checkmk "$st" "MariaDB_Repl_${primary}" "lag=${lag:-0};${LAG_WARN};${LAG_CRIT}" "IO=${io:-?} SQL=${sqlt:-?} lag=${lag:-?}s"
    fi
else
    emit_checkmk 2 MariaDB_Instance - "instance DOWN (no schema reachable)"
fi

# --- Quick per-schema checks: current InnoDB lock waits ---
for db in $DBS; do
    blk="$(scalar "$db" "SELECT COUNT(*) FROM performance_schema.data_lock_waits" 2>/dev/null)"
    blk="${blk:-0}"; [[ "$blk" =~ ^[0-9]+$ ]] || blk=0
    st=0; (( blk >= 1 )) && st=1; (( blk >= 10 )) && st=2
    emit_checkmk "$st" "MariaDB_Blocking_${db}" "blocked=${blk};1;10" "${blk} lock wait(s) in ${db}"
done
