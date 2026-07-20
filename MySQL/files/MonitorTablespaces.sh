#!/usr/bin/env bash
# MonitorTablespaces.sh [db ...] — capacity view for MySQL / MariaDB.
# Db2's SYSIBMADM.TBSP_UTILIZATION has no direct equivalent, so the
# "tablespace" concept is mapped to:
#   * datadir filesystem utilisation (df of the mount that hosts @@datadir),
#   * per-schema InnoDB size from information_schema.TABLES
#     (SUM(DATA_LENGTH + INDEX_LENGTH), plus reclaimable DATA_FREE).
# Each schema is reported as one "tablespace" row so the chatbot's existing
# per-database tablespace view renders unchanged; the datadir mount carries a
# severity so a full disk is flagged.
#
# Final JSON: {"timestamp","filesystems":[{mount,size,used,avail,pct,is_datadir,severity}],
#              "databases":[{database,tablespaces:[{tablespace,contents,
#                            used_pct,used_mb,size_mb,severity}]}]}
source "$(dirname "$0")/lib/mysql_common.sh"

require_cmd python3 df >/dev/null 2>&1 || true

WARN="$(get_threshold tablespace.used_pct_warn 85)"
CRIT="$(get_threshold tablespace.used_pct_crit 95)"
DBS="${*:-$(list_databases)}"

# Real (non-pseudo) filesystems, in GB. Same shape as the Db2 port.
fs="$(df -P -BG 2>/dev/null | awk 'NR>1 && $1 !~ /tmpfs|devtmpfs|overlay/ {gsub(/%/,"",$5); print $6"|"$2"|"$3"|"$4"|"$5}')"

ts_rows=""
for db in $DBS; do
    # datadir of the server backing this schema (used to attribute disk usage).
    datadir="$(scalar "$db" "SELECT @@datadir")"
    # Per-schema InnoDB footprint (MB): used = data+index, free = reclaimable.
    raw="$(printf '%s' "SELECT
              COALESCE(GROUP_CONCAT(DISTINCT ENGINE),'DATA'),
              CAST(ROUND(COALESCE(SUM(DATA_LENGTH+INDEX_LENGTH),0)/1048576) AS SIGNED),
              CAST(ROUND(COALESCE(SUM(DATA_FREE),0)/1048576) AS SIGNED)
            FROM information_schema.TABLES
            WHERE TABLE_SCHEMA = DATABASE()
              AND ENGINE IS NOT NULL;" | sqlx "$db" 2>/dev/null | head -1)"
    [[ -z "${raw// }" ]] && raw=$'DATA\t0\t0'
    IFS=$'\t' read -r engine used_mb free_mb <<<"$raw"
    ts_rows+="${db}|${engine}|${used_mb:-0}|${free_mb:-0}|${datadir}"$'\n'
done

printf '%s' "$ts_rows" | python3 - "$WARN" "$CRIT" "$fs" <<'PY'
import json, sys, datetime
warn, crit = float(sys.argv[1] or 85), float(sys.argv[2] or 95)
fs_blob = sys.argv[3] if len(sys.argv) > 3 else ""

filesystems = []
for line in fs_blob.splitlines():
    if not line.strip():
        continue
    mount, size, used, avail, pct = (line.split('|') + ['']*5)[:5]
    try:
        pct = int(pct)
    except ValueError:
        pct = None
    filesystems.append({"mount": mount, "size": size, "used": used,
                        "avail": avail, "pct": pct,
                        "is_datadir": False, "severity": "ok"})

def sev_for(pct):
    if pct is None:
        return "ok"
    if pct >= crit:
        return "critical"
    if pct >= warn:
        return "warning"
    return "ok"

def mount_for(path):
    # Longest mount point that is a prefix of the datadir path.
    best, best_len = None, -1
    for f in filesystems:
        m = f["mount"]
        if path == m or path.startswith(m.rstrip('/') + '/') or m == '/':
            if len(m) > best_len:
                best, best_len = f, len(m)
    return best

dbmap = {}
for line in sys.stdin.read().splitlines():
    if not line.strip():
        continue
    db, contents, used_mb, free_mb, datadir = (line.split('|') + ['']*5)[:5]
    try:
        used = int(used_mb)
    except ValueError:
        used = 0
    try:
        free = int(free_mb)
    except ValueError:
        free = 0
    size = used + free
    up = round(100.0 * used / size, 1) if size > 0 else 0.0
    dbmap.setdefault(db, []).append({
        "tablespace": db,
        "contents": (contents or "DATA").strip(),
        "used_pct": up,
        "used_mb": used,
        "size_mb": size,
        "severity": sev_for(up),
    })
    # Tag + set severity on the datadir's filesystem.
    m = mount_for((datadir or '').strip())
    if m is not None:
        m["is_datadir"] = True
        m["severity"] = sev_for(m["pct"])

print(json.dumps({
    "timestamp": datetime.datetime.now().strftime("%Y-%m-%dT%H:%M:%S"),
    "filesystems": filesystems,
    "databases": [{"database": db, "tablespaces": ts} for db, ts in dbmap.items()],
}))
PY
