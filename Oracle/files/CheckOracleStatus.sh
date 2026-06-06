#!/usr/bin/env bash
# CheckOracleStatus.sh — equivalent of CheckmssqlStatus.ps1 for Oracle.
# Verifies (and restarts) on each local SID:
#   - Listener (lsnrctl)
#   - Database instance (pmon process)
# Loops every SID in /etc/oratab. Emits JSON summary on stdout.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/oracle_common.sh"

report=()

# 1. Listener
listener_state="unknown"
if pgrep -f tnslsnr >/dev/null 2>&1; then
    listener_state="running"
else
    warn "TNS listener not running; attempting restart"
    if su - oracle -c "lsnrctl start" >>"$LOG_FILE" 2>&1; then
        listener_state="restarted"
    else
        listener_state="failed_to_start"
    fi
fi
report+=("{\"item\":\"listener\",\"state\":\"$listener_state\"}")

# 2. Each SID
mapfile -t SIDS < <(awk -F: '!/^#/ && NF >= 2 && $1 != "*" {print $1}' /etc/oratab 2>/dev/null)
for sid in "${SIDS[@]}"; do
    [[ -z "$sid" ]] && continue
    pmon_state="unknown"
    if pgrep -f "ora_pmon_${sid}$" >/dev/null 2>&1; then
        pmon_state="running"
    else
        warn "Instance $sid (pmon) not running; attempting startup"
        # Use sqlplus / as sysdba within the SID's environment
        if su - oracle -c "
            export ORACLE_SID=$sid
            ORACLE_HOME=\$(awk -F: -v s=$sid '\$1 == s {print \$2; exit}' /etc/oratab)
            export ORACLE_HOME
            export PATH=\$ORACLE_HOME/bin:\$PATH
            export LD_LIBRARY_PATH=\$ORACLE_HOME/lib
            echo 'STARTUP;' | sqlplus -S -L '/ as sysdba'
        " >>"$LOG_FILE" 2>&1; then
            pmon_state="restarted"
        else
            pmon_state="failed_to_start"
        fi
    fi
    report+=("{\"item\":\"$sid\",\"state\":\"$pmon_state\"}")
done

# Emit JSON summary
items_csv="$(IFS=,; echo "${report[*]}")"
ts_iso="$(date -Iseconds 2>/dev/null || date +%FT%T%z)"
problems=$(printf '%s\n' "${report[@]}" | grep -c 'failed_to_start' || true)
restarted=$(printf '%s\n' "${report[@]}" | grep -c 'restarted' || true)

summary="{\"timestamp\":\"$ts_iso\",\"host\":\"$(hostname -s)\",\"restarted\":$restarted,\"failed\":$problems,\"items\":[$items_csv]}"
write_status_file "oracle_status" "$summary"
echo "$summary"

log "=== CheckOracleStatus restarted=$restarted failed=$problems ==="
exit $(( problems > 0 ? 2 : (restarted > 0 ? 1 : 0) ))
