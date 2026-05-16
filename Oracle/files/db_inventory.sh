#!/usr/bin/env bash
# db_inventory.sh — Ansible facts.d collector for Oracle databases.
#
# Install path:  /etc/ansible/facts.d/db_inventory.fact   (mode 0755)
# Ansible merges this script's stdout JSON into `ansible_local.db_inventory`
# on every fact-gathering run.
#
# Output shape:
# {
#   "hostname": "...",
#   "fqdn": "...",
#   "collected_at": "ISO-8601",
#   "listener": "running"|"down",
#   "oratab_path": "/etc/oratab",
#   "databases": [
#     {
#       "sid": "ORCL",
#       "oracle_home": "/u01/app/oracle/product/19c/dbhome_1",
#       "autostart": "Y"|"N",
#       "pmon": "running"|"down",
#       "db_name": "ORCL",
#       "db_unique_name": "ORCL",
#       "instance_name": "ORCL",
#       "version": "19.0.0.0.0",
#       "open_mode": "READ WRITE",
#       "log_mode": "ARCHIVELOG",
#       "database_role": "PRIMARY",
#       "cdb": "YES"|"NO",
#       "startup_time": "YYYY-MM-DD HH24:MI:SS",
#       "total_size_mb": "...",
#       "host_name": "..."
#     }, ...
#   ]
# }
#
# Self-contained — does NOT depend on oracle_common.sh because Ansible runs
# this before /opt/dba/scripts may exist on a fresh host.

set -uo pipefail

ts() { date -Iseconds 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S%z'; }

HOSTNAME_SHORT="$(hostname -s 2>/dev/null || echo '?')"
HOSTNAME_FQDN="$(hostname -f 2>/dev/null || echo "$HOSTNAME_SHORT")"
COLLECTED_AT="$(ts)"

# Listener state — same check Oracle's own scripts use.
LISTENER_STATE="down"
pgrep -f tnslsnr >/dev/null 2>&1 && LISTENER_STATE="running"

# Gather raw per-SID data into a temp file as TSV-style lines:
#   SID<TAB>FIELD<TAB>VALUE
RAW="$(mktemp)"
trap 'rm -f "$RAW"' EXIT

oratab_path="/etc/oratab"
[[ -r "$oratab_path" ]] || oratab_path="/var/opt/oracle/oratab"
[[ -r "$oratab_path" ]] || oratab_path=""

if [[ -n "$oratab_path" && -f "$oratab_path" ]]; then
    while IFS=: read -r sid home autostart _; do
        [[ -z "$sid" || "$sid" == \#* || "$sid" == "*" ]] && continue
        autostart="${autostart:-N}"

        pmon_state="down"
        pgrep -f "ora_pmon_${sid}$" >/dev/null 2>&1 && pmon_state="running"

        printf '%s\t%s\t%s\n' "$sid" "sid"         "$sid"         >> "$RAW"
        printf '%s\t%s\t%s\n' "$sid" "oracle_home" "$home"        >> "$RAW"
        printf '%s\t%s\t%s\n' "$sid" "autostart"   "$autostart"   >> "$RAW"
        printf '%s\t%s\t%s\n' "$sid" "pmon"        "$pmon_state"  >> "$RAW"

        # If pmon is running and sqlplus is reachable, probe v$instance/v$database.
        if [[ "$pmon_state" == "running" && -x "$home/bin/sqlplus" ]]; then
            probe=$(
                ORACLE_HOME="$home" ORACLE_SID="$sid" \
                PATH="$home/bin:$PATH" \
                LD_LIBRARY_PATH="$home/lib:${LD_LIBRARY_PATH:-}" \
                "$home/bin/sqlplus" -S -L "/ as sysdba" 2>/dev/null <<'SQL'
SET PAGESIZE 0 FEEDBACK OFF VERIFY OFF ECHO OFF HEADING OFF LINESIZE 32767 TRIMSPOOL ON
WHENEVER SQLERROR EXIT 0
SELECT 'db_name|'        || NVL(name,'')           FROM v$database;
SELECT 'db_unique_name|' || NVL(db_unique_name,'') FROM v$database;
SELECT 'open_mode|'      || NVL(open_mode,'')      FROM v$database;
SELECT 'log_mode|'       || NVL(log_mode,'')       FROM v$database;
SELECT 'database_role|'  || NVL(database_role,'')  FROM v$database;
SELECT 'cdb|'            || NVL(cdb,'')            FROM v$database;
SELECT 'platform_name|'  || NVL(platform_name,'')  FROM v$database;
SELECT 'instance_name|'  || NVL(instance_name,'')  FROM v$instance;
SELECT 'version|'        || NVL(version,'')        FROM v$instance;
SELECT 'host_name|'      || NVL(host_name,'')      FROM v$instance;
SELECT 'startup_time|'   || TO_CHAR(startup_time,'YYYY-MM-DD HH24:MI:SS') FROM v$instance;
SELECT 'total_size_mb|'  || TO_CHAR(ROUND(NVL(SUM(bytes)/1024/1024,0))) FROM v$datafile;
EXIT;
SQL
            )
            # Push probe rows into the raw file under the same SID.
            while IFS='|' read -r field value; do
                [[ -z "$field" ]] && continue
                printf '%s\t%s\t%s\n' "$sid" "$field" "$value" >> "$RAW"
            done <<<"$probe"
        fi
    done < "$oratab_path"
fi

# Build the final JSON in one python pass so we don't have to hand-escape
# anything from the shell (oracle outputs may contain quotes / spaces).
python3 - "$RAW" "$HOSTNAME_SHORT" "$HOSTNAME_FQDN" "$COLLECTED_AT" "$LISTENER_STATE" "$oratab_path" <<'PY'
import json, sys
from collections import OrderedDict

raw_file, hostname, fqdn, collected_at, listener, oratab = sys.argv[1:7]

dbs = OrderedDict()                     # sid -> dict
with open(raw_file, "r", encoding="utf-8", errors="replace") as fh:
    for line in fh:
        parts = line.rstrip("\n").split("\t", 2)
        if len(parts) != 3:
            continue
        sid, field, value = parts
        dbs.setdefault(sid, OrderedDict())[field] = value

out = OrderedDict([
    ("hostname",     hostname),
    ("fqdn",         fqdn),
    ("collected_at", collected_at),
    ("listener",     listener),
    ("oratab_path",  oratab or None),
    ("databases",    list(dbs.values())),
])
# Ansible facts must be valid JSON; compact form keeps the gathered fact set small.
json.dump(out, sys.stdout, separators=(",", ":"))
sys.stdout.write("\n")
PY
