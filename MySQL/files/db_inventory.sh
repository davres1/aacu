#!/usr/bin/env bash
# db_inventory.sh — Ansible facts.d collector for MySQL / MariaDB.
#
# Installed at /etc/ansible/facts.d/db_inventory.fact (mode 0755) so its JSON
# becomes ansible_local.db_inventory. Self-contained (does NOT source the DBA
# lib) because Ansible gathers facts early, possibly before /opt/dba exists.
# It therefore connects with a plain local `mysql` client (socket / root, or the
# MYSQL_USER / MYSQL_PWD env vars) and prints ONLY JSON to stdout.
#
# Emits the SQL-Server-style instance->databases shape so the chatbot's catalogue
# generator and PDF inventory section parse it uniformly. TOP-LEVEL KEY IS "mysql":
#   {"hostname","computer_name","fqdn","collected_at",
#    "mysql": {"<host>\\<instance>": {"instance_name","version","edition",
#                "databases":[{"name","status","size_mb"}],
#                "cis_compliance":{"compliance_score":N},
#                "tablespaces":[...], "backups":[...]}}}
set -o pipefail

HOSTNAME_SHORT="$(hostname -s 2>/dev/null || hostname)"
FQDN="$(hostname -f 2>/dev/null || echo "$HOSTNAME_SHORT")"
INSTANCE="${MYSQL_INSTANCE:-mysql}"
BACKUP_DIR="${MYSQL_BACKUP_DIR:-/var/backups/mysql}"

# Plain local client. MYSQL_PWD (if exported) is picked up automatically.
myq() {
    mysql -N -B ${MYSQL_USER:+-u"$MYSQL_USER"} -e "$1" 2>/dev/null
}
trim() { printf '%s' "$1" | tr -d '[:space:]'; }

VERSION="$(trim "$(myq 'SELECT VERSION();')")"
EDITION="$(myq 'SELECT @@version_comment;' | head -1)"

# Databases: name, status, size_mb.
DB_ROWS="$(myq "SELECT CONCAT_WS('|','DB',s.SCHEMA_NAME,'ONLINE',COALESCE(ROUND(SUM(t.DATA_LENGTH+t.INDEX_LENGTH)/1048576),0)) FROM information_schema.SCHEMATA s LEFT JOIN information_schema.TABLES t ON t.TABLE_SCHEMA=s.SCHEMA_NAME WHERE s.SCHEMA_NAME NOT IN ('information_schema','performance_schema','sys','mysql') GROUP BY s.SCHEMA_NAME;")"

# InnoDB tablespaces (best-effort).
TS_ROWS="$(myq "SELECT CONCAT_WS('|','TS',NAME,COALESCE(ROUND(FILE_SIZE/1048576),0)) FROM information_schema.INNODB_TABLESPACES ORDER BY FILE_SIZE DESC LIMIT 25;")"

# CIS-style compliance inputs.
WEAK="$(trim "$(myq "SELECT COUNT(*) FROM mysql.user WHERE plugin IN ('mysql_native_password','caching_sha2_password','') AND (authentication_string='' OR authentication_string IS NULL);")")"
WILDCARD="$(trim "$(myq "SELECT COUNT(*) FROM mysql.user WHERE host='%';")")"
VP_ACTIVE="$(trim "$(myq "SELECT COUNT(*) FROM information_schema.PLUGINS WHERE PLUGIN_NAME LIKE 'validate_password%' AND PLUGIN_STATUS='ACTIVE';")")"

# Backups (best-effort filesystem scan).
BK_ROWS=""
if [[ -d "$BACKUP_DIR" ]]; then
    BK_ROWS="$(find "$BACKUP_DIR" -maxdepth 2 -type f \( -name '*.sql' -o -name '*.sql.gz' -o -name '*.gz' -o -name '*.xb' -o -name '*.xbstream' \) -printf 'BK|%f|%s|%TY-%Tm-%TdT%TH:%TM\n' 2>/dev/null | sort -t'|' -k4 -r | head -20)"
fi

printf '%s\n%s\n%s' "$DB_ROWS" "$TS_ROWS" "$BK_ROWS" | python3 - \
    "$HOSTNAME_SHORT" "$FQDN" "$INSTANCE" "$VERSION" "$EDITION" \
    "${WEAK:-0}" "${WILDCARD:-0}" "${VP_ACTIVE:-0}" <<'PY'
import json, sys, datetime
host, fqdn, inst, ver, edition, weak, wildcard, vp = sys.argv[1:9]
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
score = 100
if n(weak) > 0:     score -= 25
if n(wildcard) > 0: score -= 15
if n(vp) == 0:      score -= 20
score = max(score, 0)

key = f"{host}\\{inst}"
out = {
    "hostname": host,
    "computer_name": host,
    "fqdn": fqdn,
    "collected_at": datetime.datetime.now().strftime("%Y-%m-%dT%H:%M:%S"),
    "mysql": {
        key: {
            "instance_name": inst,
            "version": ver,
            "edition": edition,
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
