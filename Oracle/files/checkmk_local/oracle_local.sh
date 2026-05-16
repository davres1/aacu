#!/usr/bin/env bash
# CheckMK local plugin (~60s) — fast Oracle health signals.
# Service status (listener + pmon per SID), current blocking count, Data Guard
# apply-lag for standby DBs. Drop in: /usr/lib/check_mk_agent/local/
#
# Reads DB credentials from /etc/oracle/databases.ini using the shared lib.

set -uo pipefail
LIB="${ORACLE_DBA_LIB:-/opt/dba/scripts/lib/oracle_common.sh}"
[[ -f "$LIB" ]] && source "$LIB" || { echo "3 Oracle_DBA_LIB - UNKNOWN - $LIB not found"; exit 0; }

# Listener
if pgrep -f tnslsnr >/dev/null 2>&1; then
    emit_checkmk 0 Oracle_Listener - "Listener running"
else
    emit_checkmk 2 Oracle_Listener - "Listener NOT running"
fi

# Per-SID pmon check
if [[ -f /etc/oratab ]]; then
    while IFS=: read -r sid home auto _; do
        [[ -z "$sid" || "$sid" == \#* || "$sid" == "*" ]] && continue
        if pgrep -f "ora_pmon_${sid}$" >/dev/null 2>&1; then
            emit_checkmk 0 "Oracle_Instance_$sid" - "pmon up"
        else
            emit_checkmk 2 "Oracle_Instance_$sid" - "pmon DOWN"
        fi
    done < /etc/oratab
fi

# DB-level: blocking + Data Guard lag per DB
for db in $(list_databases); do
    if ! db_credentials "$db" >/dev/null 2>&1; then continue; fi

    # Blocking count
    blocked=$(scalar "$db" "SELECT COUNT(*) FROM v\$session WHERE blocking_session IS NOT NULL;" 2>/dev/null)
    if [[ -n "$blocked" ]]; then
        sev=0
        (( blocked >= 10 )) && sev=2
        (( blocked >= 1 && blocked < 10 )) && sev=1
        emit_checkmk $sev "Oracle_Blocking_$db" "blocked=$blocked;1;10" "blocked sessions=$blocked"
    else
        emit_checkmk 3 "Oracle_Blocking_$db" - "could not probe"
    fi

    # Data Guard apply lag (only if not PRIMARY)
    dg=$(sql "$db" sys <<'SQL' 2>/dev/null
SELECT '__DG__|' ||
       (SELECT database_role FROM v$database) || '|' ||
       NVL((SELECT value FROM v$dataguard_stats WHERE name='apply lag'), '00 00:00:00');
SQL
)
    if [[ "$dg" == *"__DG__"* ]]; then
        IFS='|' read -r _ role lagval <<<"$(echo "$dg" | grep __DG__ | head -1)"
        if [[ "$role" != "PRIMARY" && -n "$lagval" ]]; then
            lag_sec=$(python3 -c "
v = '$lagval'.lstrip('+-')
try:
    d, hms = v.split(' '); h, m, s = hms.split(':')
    print(int(d)*86400 + int(h)*3600 + int(m)*60 + int(s))
except Exception:
    print(0)" 2>/dev/null)
            lagWarn=$(get_threshold dataguard.lag_warn_sec 30)
            lagCrit=$(get_threshold dataguard.lag_crit_sec 120)
            sev=0
            (( lag_sec >= lagCrit )) && sev=2
            (( lag_sec >= lagWarn && lag_sec < lagCrit )) && sev=1
            emit_checkmk $sev "Oracle_DG_${db}" "lag_sec=${lag_sec};${lagWarn};${lagCrit}" "role=$role apply_lag=${lag_sec}s"
        fi
    fi
done
