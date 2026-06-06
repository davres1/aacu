#!/usr/bin/env bash
# MonitorHADR.sh [db ...] — HADR role + log gap / lag from SYSIBMADM.SNAPHADR
# (falls back to `db2pd -hadr`). Emits the same shape as the Oracle Data Guard
# monitor so the chatbot's shared alwayson_status view renders it.
#
# Final JSON: {"timestamp","critical","warning",
#              "databases":[{database,role,state,
#                            lag_metrics:[{name,value}],severity}]}
source "$(dirname "$0")/lib/db2_common.sh"

LAG_WARN="$(get_threshold hadr.lag_warn_sec 30)"
LAG_CRIT="$(get_threshold hadr.lag_crit_sec 120)"
GAP_WARN_KB="$(get_threshold hadr.log_gap_warn_kb 10240)"
DBS="${*:-$(list_databases)}"
rows=""

for db in $DBS; do
    # role | state | log gap (bytes) | primary-to-standby lag (seconds)
    raw="$(printf '%s' "SELECT HADR_ROLE || '|' || HADR_STATE || '|' || CAST(COALESCE(HADR_LOG_GAP,0) AS BIGINT) || '|' || CAST(COALESCE(STANDBY_REPLAY_DELAY,0) AS BIGINT) FROM SYSIBMADM.SNAPHADR FETCH FIRST 1 ROWS ONLY;" | sqlx "$db" 2>/dev/null | head -1)"
    [[ -z "${raw// }" ]] && raw="STANDARD|DISCONNECTED|0|0"
    rows+="${db}|${raw}"$'\n'
done

printf '%s' "$rows" | python3 - "$LAG_WARN" "$LAG_CRIT" "$GAP_WARN_KB" <<'PY'
import json, sys, datetime
lag_warn, lag_crit, gap_warn_kb = float(sys.argv[1]), float(sys.argv[2]), float(sys.argv[3])
dbs, crit, warn = [], 0, 0
for line in sys.stdin.read().splitlines():
    if not line.strip(): continue
    db, role, state, gap_b, lag_s = (line.split('|') + ['']*5)[:5]
    try: gap_kb = float(gap_b or 0) / 1024.0
    except ValueError: gap_kb = 0.0
    try: lag = float(lag_s or 0)
    except ValueError: lag = 0.0
    sev = "ok"
    if role.strip().upper() != "STANDARD":
        if lag >= lag_crit or state.strip().upper() not in ("PEER", "REMOTE_CATCHUP"):
            sev = "critical"
        elif lag >= lag_warn or gap_kb >= gap_warn_kb:
            sev = "warning"
    if sev == "critical": crit += 1
    elif sev == "warning": warn += 1
    dbs.append({
        "database": db, "role": role.strip(), "state": state.strip(),
        "lag_metrics": [
            {"name": "replay lag", "value": f"{lag:.0f}s"},
            {"name": "log gap", "value": f"{gap_kb:.0f}KB"},
        ],
        "severity": sev,
    })
print(json.dumps({
    "timestamp": datetime.datetime.now().strftime("%Y-%m-%dT%H:%M:%S"),
    "critical": crit, "warning": warn, "databases": dbs,
}))
PY
