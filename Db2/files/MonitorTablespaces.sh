#!/usr/bin/env bash
# MonitorTablespaces.sh [db ...] — per-tablespace usage (SYSIBMADM.TBSP_UTILIZATION)
# plus filesystem utilization (df). TEMP tablespaces are tagged so the chatbot's
# tempdb view can filter them client-side.
#
# Final JSON: {"timestamp","filesystems":[{mount,size,used,avail,pct}],
#              "databases":[{database,tablespaces:[{tablespace,contents,
#                            used_pct,used_mb,size_mb,severity}]}]}
source "$(dirname "$0")/lib/db2_common.sh"

WARN="$(get_threshold tablespace.used_pct_warn 85)"
CRIT="$(get_threshold tablespace.used_pct_crit 95)"
DBS="${*:-$(list_databases)}"

# Filesystems (skip pseudo/virtual).
fs="$(df -P -BG 2>/dev/null | awk 'NR>1 && $1 !~ /tmpfs|devtmpfs|overlay/ {gsub(/%/,"",$5); print $6"|"$2"|"$3"|"$4"|"$5}')"

ts_rows=""
for db in $DBS; do
    raw="$(printf '%s' "SELECT TBSP_NAME || '|' || TBSP_CONTENT_TYPE || '|' || CAST(TBSP_UTILIZATION_PERCENT AS DEC(5,1)) || '|' || CAST(TBSP_USED_SIZE_KB/1024 AS BIGINT) || '|' || CAST(TBSP_TOTAL_SIZE_KB/1024 AS BIGINT) FROM SYSIBMADM.TBSP_UTILIZATION;" | sqlx "$db" 2>/dev/null)"
    while IFS= read -r ln; do
        [[ -z "${ln// }" ]] && continue
        ts_rows+="${db}|${ln}"$'\n'
    done <<< "$raw"
done

printf '%s' "$ts_rows" | python3 - "$WARN" "$CRIT" "$fs" <<'PY'
import json, sys, datetime
warn, crit = float(sys.argv[1] or 85), float(sys.argv[2] or 95)
fs_blob = sys.argv[3] if len(sys.argv) > 3 else ""
filesystems = []
for line in fs_blob.splitlines():
    if not line.strip(): continue
    mount, size, used, avail, pct = (line.split('|') + ['']*5)[:5]
    try: pct = int(pct)
    except ValueError: pct = None
    filesystems.append({"mount": mount, "size": size, "used": used, "avail": avail, "pct": pct})
dbmap = {}
for line in sys.stdin.read().splitlines():
    if not line.strip(): continue
    db, name, content, used_pct, used_mb, size_mb = (line.split('|') + ['']*6)[:6]
    try: up = float(used_pct)
    except ValueError: up = 0.0
    sev = "critical" if up >= crit else ("warning" if up >= warn else "ok")
    dbmap.setdefault(db, []).append({
        "tablespace": name.strip(),
        "contents": content.strip(),
        "used_pct": up,
        "used_mb": (int(used_mb) if used_mb.strip().lstrip('-').isdigit() else used_mb.strip()),
        "size_mb": (int(size_mb) if size_mb.strip().lstrip('-').isdigit() else size_mb.strip()),
        "severity": sev,
    })
print(json.dumps({
    "timestamp": datetime.datetime.now().strftime("%Y-%m-%dT%H:%M:%S"),
    "filesystems": filesystems,
    "databases": [{"database": db, "tablespaces": ts} for db, ts in dbmap.items()],
}))
PY
