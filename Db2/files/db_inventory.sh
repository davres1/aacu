#!/usr/bin/env bash
# db_inventory.sh — Ansible facts.d collector for Db2 (LUW).
#
# Installed at /etc/ansible/facts.d/db_inventory.fact (mode 0755) so its JSON
# becomes ansible_local.db_inventory. Self-contained (does NOT source the DBA
# lib) because Ansible runs facts early, possibly before /opt/dba exists.
#
# Emits the SQL-Server-style instance->databases shape so the chatbot's catalogue
# generator and PDF inventory section parse it uniformly:
#   {"hostname","fqdn","collected_at",
#    "db2": {"<host>\\<instance>": {"instance_name","version","edition",
#                                   "databases":[{"name","status","size_mb"}]}}}
set -o pipefail

HOSTNAME_SHORT="$(hostname -s 2>/dev/null || hostname)"
FQDN="$(hostname -f 2>/dev/null || echo "$HOSTNAME_SHORT")"

# Source the instance profile if we can find one (run as db2inst1 ideally).
[[ -f ~/sqllib/db2profile ]] && source ~/sqllib/db2profile 2>/dev/null || true
INSTANCE="${DB2INSTANCE:-$(db2 get instance 2>/dev/null | awk -F'is: ' '/instance/{print $2; exit}')}"
INSTANCE="${INSTANCE:-db2inst1}"

LEVEL="$(db2level 2>/dev/null)"
VERSION="$(printf '%s' "$LEVEL" | grep -oE 'v[0-9]+\.[0-9.]+' | head -1)"
EDITION="$(printf '%s' "$LEVEL" | grep -oE '"[^"]*Edition[^"]*"' | head -1 | tr -d '"')"

# Database names from the local directory (indirect entries only).
DBS="$(db2 list database directory 2>/dev/null \
        | awk -F'= ' '/Database name/{print $2}' | tr -d ' ' | sort -u)"

# Per-DB status + size (best-effort; skip DBs we cannot connect to).
ROWS=""
for db in $DBS; do
    [[ -z "$db" ]] && continue
    status="$(db2 connect to "$db" >/dev/null 2>&1 && echo ACTIVE || echo INACTIVE)"
    size_mb=""
    if [[ "$status" == "ACTIVE" ]]; then
        size_mb="$(db2 -x "SELECT CAST(SUM(TBSP_TOTAL_SIZE_KB)/1024 AS BIGINT) FROM SYSIBMADM.TBSP_UTILIZATION" 2>/dev/null | tr -d ' ')"
        db2 connect reset >/dev/null 2>&1 || true
    fi
    ROWS+="${db}|${status}|${size_mb}"$'\n'
done

printf '%s' "$ROWS" | python3 - "$HOSTNAME_SHORT" "$FQDN" "$INSTANCE" "$VERSION" "$EDITION" <<'PY'
import json, sys
host, fqdn, inst, ver, edition = sys.argv[1:6]
dbs = []
for line in sys.stdin.read().splitlines():
    if not line.strip():
        continue
    parts = (line.split('|') + ['', '', ''])[:3]
    name, status, size_mb = parts
    row = {"name": name, "status": status}
    if size_mb:
        try: row["size_mb"] = int(size_mb)
        except ValueError: row["size_mb"] = size_mb
    dbs.append(row)
key = f"{host}\\{inst}"
out = {
    "hostname": host,
    "fqdn": fqdn,
    "collected_at": __import__("datetime").datetime.now().strftime("%Y-%m-%dT%H:%M:%S"),
    "db2": {
        key: {
            "instance_name": inst,
            "version": ver,
            "edition": edition,
            "database_count": len(dbs),
            "databases": dbs,
        }
    },
}
print(json.dumps(out))
PY
