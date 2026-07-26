#!/usr/bin/env bash
# db_inventory.sh — Ansible facts.d collector for PostgreSQL.
#
# Installed at /etc/ansible/facts.d/db_inventory.fact (mode 0755) so its JSON
# becomes ansible_local.db_inventory. Self-contained (does NOT source the DBA
# lib) because Ansible gathers facts early, possibly before /opt/dba exists.
# It therefore connects with a plain local `psql` client (peer/socket as the
# postgres OS user, or the PG_USER / PGPASSWORD env vars) and prints ONLY JSON
# to stdout.
#
# Emits the SQL-Server-style instance->databases shape so the chatbot's catalogue
# generator and PDF inventory section parse it uniformly. TOP-LEVEL KEY IS "postgresql":
#   {"hostname","computer_name","fqdn","collected_at",
#    "postgresql": {"<host>/<instance>": {"instance_name","version","edition",
#                "databases":[{"name","status","size_mb"}],
#                "cis_compliance":{"compliance_score":N},
#                "tablespaces":[...], "backups":[...]}}}
set -o pipefail

HOSTNAME_SHORT="$(hostname -s 2>/dev/null || hostname)"
FQDN="$(hostname -f 2>/dev/null || echo "$HOSTNAME_SHORT")"
INSTANCE="${PG_INSTANCE:-postgresql}"
BACKUP_DIR="${PG_BACKUP_DIR:-/var/backups/postgresql}"
PG_USER="${PG_USER:-postgres}"

# Plain local client. PGPASSWORD (if exported) is picked up automatically.
pgq() {
    PGPASSWORD="${PGPASSWORD:-}" psql -U "$PG_USER" -t -A -F'|' -c "$1" 2>/dev/null
}
trim() { printf '%s' "$1" | tr -d '[:space:]'; }

VERSION="$(trim "$(pgq 'SELECT version();')")"
VERSION_SHORT="$(trim "$(pgq 'SHOW server_version;')")"

# Databases: name, status, size_mb.
DB_ROWS="$(pgq "SELECT 'DB|' || datname || '|ONLINE|' || ROUND(pg_database_size(datname)/1048576.0)
               FROM pg_database
               WHERE datistemplate = false
               ORDER BY datname;")"

# Tablespaces.
TS_ROWS="$(pgq "SELECT 'TS|' || spcname || '|' || COALESCE(ROUND(pg_tablespace_size(oid)/1048576.0), 0)
               FROM pg_tablespace
               ORDER BY spcname;" 2>/dev/null || true)"

# CIS-style compliance inputs.
SUPERUSER_COUNT="$(trim "$(pgq "SELECT COUNT(*) FROM pg_roles WHERE rolsuper = true;")")"
TRUST_COUNT="$(trim "$(pgq "SELECT COUNT(*) FROM pg_hba_file_rules WHERE auth_method = 'trust';" 2>/dev/null || echo 0)")"
SSL_ON="$(trim "$(pgq "SHOW ssl;")")"

# Backups (best-effort filesystem scan).
BK_ROWS=""
if [[ -d "$BACKUP_DIR" ]]; then
    BK_ROWS="$(find "$BACKUP_DIR" -maxdepth 3 -type f \
        \( -name '*.sql' -o -name '*.sql.gz' -o -name '*.tar' -o -name '*.tar.gz' -o -name '*.dump' \) \
        -printf 'BK|%f|%s|%TY-%Tm-%TdT%TH:%TM\n' 2>/dev/null | sort -t'|' -k4 -r | head -20)"
fi

printf '%s\n%s\n%s' "$DB_ROWS" "$TS_ROWS" "$BK_ROWS" | python3 - \
    "$HOSTNAME_SHORT" "$FQDN" "$INSTANCE" "$VERSION_SHORT" "$VERSION" \
    "${SUPERUSER_COUNT:-0}" "${TRUST_COUNT:-0}" "${SSL_ON:-off}" <<'PY'
import json, sys, datetime
host, fqdn, inst, ver_short, ver_full, su_count, trust_count, ssl = sys.argv[1:9]
dbs, tablespaces, backups = [], [], []
for line in sys.stdin.read().splitlines():
    if not line.strip() or "|" not in line:
        continue
    tag = line.split("|", 1)[0]
    if tag == "DB":
        _, name, status, size_mb = (line.split("|") + ['']*4)[:4]
        row = {"name": name, "status": status}
        try: row["size_mb"] = int(size_mb)
        except ValueError: row["size_mb"] = 0
        dbs.append(row)
    elif tag == "TS":
        _, name, size_mb = (line.split("|") + ['']*3)[:3]
        try: sz = int(size_mb)
        except ValueError: sz = 0
        tablespaces.append({"name": name, "size_mb": sz})
    elif tag == "BK":
        _, fn, size, mtime = (line.split("|") + ['']*4)[:4]
        try: sz = int(size)
        except ValueError: sz = 0
        backups.append({"file": fn, "size_bytes": sz, "modified": mtime})

def n(x):
    try: return int(x)
    except (TypeError, ValueError): return 0

# CIS scoring: superusers, trust auth, ssl
score = 100
if n(su_count) > 3:     score -= 25
if n(trust_count) > 0:  score -= 30
if ssl.strip().lower() not in ('on', 'yes', 'true'): score -= 20
score = max(score, 0)

key = f"{host}/{inst}"
out = {
    "hostname": host,
    "computer_name": host,
    "fqdn": fqdn,
    "collected_at": datetime.datetime.now().strftime("%Y-%m-%dT%H:%M:%S"),
    "postgresql": {
        key: {
            "instance_name": inst,
            "version": ver_short,
            "edition": ver_full,
            "database_count": len(dbs),
            "databases": dbs,
            "cis_compliance": {"compliance_score": score},
            "tablespaces": tablespaces,
            "backups": backups,
        }
    },
}
print(json.dumps(out))
PY
