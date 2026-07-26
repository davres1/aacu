#!/usr/bin/env bash
# MonitorTablespaces.sh [db ...] — capacity view for PostgreSQL.
# Db2's SYSIBMADM.TBSP_UTILIZATION is mapped to:
#   * data_directory filesystem utilisation (df of the mount hosting SHOW data_directory)
#   * per-database size from pg_database_size()
#   * per-tablespace size from pg_tablespace_size()
# Each database is reported as one row so the chatbot's existing per-database
# tablespace view renders unchanged; the data_directory mount carries a
# severity so a full disk is flagged.
#
# Final JSON: {"timestamp","filesystems":[{mount,size,used,avail,pct,is_datadir,severity}],
#              "databases":[{database,tablespaces:[{tablespace,contents,
#                            used_pct,used_mb,size_mb,severity}]}]}
source "$(dirname "$0")/lib/pg_common.sh"

require_cmd python3 df >/dev/null 2>&1 || true

WARN="$(get_threshold tablespace.used_pct_warn 85)"
CRIT="$(get_threshold tablespace.used_pct_crit 95)"
DBS="${*:-$(list_databases)}"

# Real (non-pseudo) filesystems in GB — same shape as the Db2/MySQL port.
fs="$(df -P -BG 2>/dev/null | awk 'NR>1 && $1 !~ /tmpfs|devtmpfs|overlay/ {gsub(/%/,"",$5); print $6"|"$2"|"$3"|"$4"|"$5}')"

ts_rows=""
for db in $DBS; do
    # data_directory (used to attribute disk usage to a mount point).
    datadir="$(scalar "$db" "SHOW data_directory")"

    # Per-database size in MB.
    db_mb="$(scalar "$db" "SELECT ROUND(pg_database_size(current_database())/1048576.0)")"
    db_mb="${db_mb:-0}"

    # Per-tablespace sizes for tablespaces this database can see.
    ts_raw="$(printf '%s\n' \
        "SELECT spcname, ROUND(COALESCE(pg_tablespace_size(oid),0)/1048576.0)
         FROM pg_tablespace
         ORDER BY spcname;" | sqlx "$db" 2>/dev/null)"

    ts_list=""
    while IFS='|' read -r spcname spc_mb; do
        [[ -z "$spcname" ]] && continue
        ts_list+="${spcname}:${spc_mb:-0},"
    done <<< "$ts_raw"

    ts_rows+="${db}|${db_mb}|${datadir}|${ts_list%,}"$'\n'
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
    best, best_len = None, -1
    for f in filesystems:
        m = f["mount"]
        if path == m or path.startswith(m.rstrip('/') + '/') or m == '/':
            if len(m) > best_len:
                best, best_len = f, len(m)
    return best

dbmap = {}
order = []
for line in sys.stdin.read().splitlines():
    if not line.strip():
        continue
    parts = line.split('|', 3)
    db = parts[0]
    try: db_mb = int(parts[1])
    except (IndexError, ValueError): db_mb = 0
    datadir = parts[2] if len(parts) > 2 else ''
    ts_blob = parts[3] if len(parts) > 3 else ''

    if db not in dbmap:
        dbmap[db] = []
        order.append(db)

    # Primary tablespace entry = the database itself.
    up = 0.0  # We don't know the max; rely on filesystem for used_pct.
    dbmap[db].append({
        "tablespace": db,
        "contents": "DATABASE",
        "used_pct": up,
        "used_mb": db_mb,
        "size_mb": db_mb,
        "severity": "ok",
    })

    # Additional tablespace entries.
    for ts_entry in ts_blob.split(','):
        if not ts_entry or ':' not in ts_entry:
            continue
        spcname, spc_mb_s = ts_entry.split(':', 1)
        try: spc_mb = int(spc_mb_s)
        except ValueError: spc_mb = 0
        dbmap[db].append({
            "tablespace": spcname,
            "contents": "TABLESPACE",
            "used_pct": 0.0,
            "used_mb": spc_mb,
            "size_mb": spc_mb,
            "severity": "ok",
        })

    # Tag + set severity on the data_directory's filesystem.
    m = mount_for((datadir or '').strip())
    if m is not None:
        m["is_datadir"] = True
        m["severity"] = sev_for(m["pct"])

print(json.dumps({
    "timestamp": datetime.datetime.now().strftime("%Y-%m-%dT%H:%M:%S"),
    "filesystems": filesystems,
    "databases": [{"database": db, "tablespaces": dbmap[db]} for db in order],
}))
PY
