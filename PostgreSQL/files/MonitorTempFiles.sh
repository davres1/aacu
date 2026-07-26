#!/usr/bin/env bash
# MonitorTempFiles.sh [db ...] — report PostgreSQL temp file usage and background
# writer statistics. Temp file usage in pg_stat_database indicates sorts/hashes
# that overflowed work_mem to disk. High temp file counts or sizes suggest
# work_mem is too small or queries need optimization.
#
# Final JSON: {"timestamp",
#   "temp_activity":[{database,temp_files,temp_bytes,temp_size}],
#   "bgwriter":{checkpoints_timed,checkpoints_req,buffers_checkpoint,
#               buffers_clean,maxwritten_clean,buffers_backend,buffers_alloc}}
source "$(dirname "$0")/lib/pg_common.sh"

DBS="${*:-$(list_databases)}"
temp_rows=""
bgwriter_row=""

# Per-database temp file stats.
for db in $DBS; do
    raw="$(printf '%s\n' \
        "SELECT datname,
                temp_files,
                temp_bytes,
                pg_size_pretty(temp_bytes)
         FROM pg_stat_database
         WHERE datname = current_database()
           AND temp_files > 0;" \
        | sqlx "$db" 2>/dev/null | head -1)"
    [[ -z "${raw// }" ]] && continue
    IFS='|' read -r dname tf tb tsize <<<"$raw"
    temp_rows+="${dname}|${tf}|${tb}|${tsize}"$'\n'
done

# pg_stat_bgwriter is instance-wide — read from the first available database.
first_db="$(list_databases | head -1)"
if [ -n "$first_db" ]; then
    bgwriter_row="$(printf '%s\n' \
        "SELECT checkpoints_timed,
                checkpoints_req,
                buffers_checkpoint,
                buffers_clean,
                maxwritten_clean,
                buffers_backend,
                buffers_alloc
         FROM pg_stat_bgwriter;" \
        | sqlx "$first_db" 2>/dev/null | head -1)"
fi

printf '%s' "$temp_rows" | python3 - "$bgwriter_row" <<'PY'
import json, sys, datetime

bgwriter_raw = sys.argv[1] if len(sys.argv) > 1 else ""
bgw_fields = bgwriter_raw.split('|') if bgwriter_raw else []
def n(i):
    try: return int(bgw_fields[i])
    except (IndexError, ValueError): return 0

bgwriter = {
    "checkpoints_timed":   n(0),
    "checkpoints_req":     n(1),
    "buffers_checkpoint":  n(2),
    "buffers_clean":       n(3),
    "maxwritten_clean":    n(4),
    "buffers_backend":     n(5),
    "buffers_alloc":       n(6),
}

temp_activity = []
for line in sys.stdin.read().splitlines():
    if not line.strip():
        continue
    dname, tf, tb, tsize = (line.split('|') + ['']*4)[:4]
    try: tf_i = int(tf)
    except ValueError: tf_i = 0
    try: tb_i = int(tb)
    except ValueError: tb_i = 0
    temp_activity.append({
        "database":   dname,
        "temp_files": tf_i,
        "temp_bytes": tb_i,
        "temp_size":  tsize.strip(),
    })

print(json.dumps({
    "timestamp":     datetime.datetime.now().strftime("%Y-%m-%dT%H:%M:%S"),
    "temp_activity": temp_activity,
    "bgwriter":      bgwriter,
}))
PY
