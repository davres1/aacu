# mysql_common.sh — shared helpers for every MySQL / MariaDB DBA script.
# Source this at the top of each script:  source "$(dirname "$0")/lib/mysql_common.sh"
#
# Reads connection info from databases.ini (one section per schema, e.g.):
#   [appdb]
#   connuser = dba
#   connpass = ********
#   dbhost   = mysqlhost01
#   dbport   = 3306
#   ansible_servername = mysqlhost01
#
# Defaults assume the script runs on the DB host (or a host that can reach it)
# with the mysql client on PATH. Connection details fall back to a local socket
# as root when a section omits host/port.

# ---------------------------------------------------------------------------
# Config (override via env)
# ---------------------------------------------------------------------------
DATABASES_INI="${DATABASES_INI:-/etc/mysql/databases.ini}"
LOG_DIR="${LOG_DIR:-/var/log/dba}"
CONFIG_DIR="${CONFIG_DIR:-/opt/dba}"
THRESHOLDS_JSON="${THRESHOLDS_JSON:-$CONFIG_DIR/thresholds.json}"
STATUS_DIR="${STATUS_DIR:-$LOG_DIR/status}"
mkdir -p "$LOG_DIR" "$STATUS_DIR" 2>/dev/null || true

MYSQL_SCRIPT_NAME="$(basename "${0:-mysql-dba}" .sh)"
LOG_FILE="${LOG_FILE:-$LOG_DIR/${MYSQL_SCRIPT_NAME}_$(date +%Y%m%d).log}"

# mysql client binary — override to point at mariadb if needed.
MYSQL_BIN="${MYSQL_BIN:-mysql}"
MYSQL_DEFAULT_USER="${MYSQL_DEFAULT_USER:-root}"
MYSQL_DEFAULT_HOST="${MYSQL_DEFAULT_HOST:-localhost}"
MYSQL_DEFAULT_PORT="${MYSQL_DEFAULT_PORT:-3306}"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
ts() { date '+%Y-%m-%d %H:%M:%S'; }
log()  { printf '[%s] [INFO]  %s\n'  "$(ts)" "$*" | tee -a "$LOG_FILE"; }
warn() { printf '[%s] [WARN]  %s\n'  "$(ts)" "$*" | tee -a "$LOG_FILE" >&2; }
err()  { printf '[%s] [ERROR] %s\n'  "$(ts)" "$*" | tee -a "$LOG_FILE" >&2; }

# ---------------------------------------------------------------------------
# databases.ini reader
# ---------------------------------------------------------------------------
list_databases() {
    local filter="${1:-}"
    python3 - "$DATABASES_INI" "$filter" <<'PY'
import configparser, sys
ini, flt = sys.argv[1], sys.argv[2].lower() if len(sys.argv) > 2 else ''
p = configparser.ConfigParser()
try: p.read(ini)
except Exception: sys.exit(0)
RESERVED = {'mysql_servers', 'DEFAULT'}
for s in p.sections():
    if s in RESERVED:
        continue
    if not flt or flt in s.lower():
        print(s)
PY
}

# db_credentials <DB> -> "connuser connpass dbhost dbport"
# connuser defaults to root, dbhost to localhost, dbport to 3306. connpass may
# be empty (socket auth / auth_socket plugin).
db_credentials() {
    local db="$1"
    python3 - "$DATABASES_INI" "$db" "$MYSQL_DEFAULT_USER" "$MYSQL_DEFAULT_HOST" "$MYSQL_DEFAULT_PORT" <<'PY'
import configparser, sys
ini, db, du, dh, dp = sys.argv[1:6]
p = configparser.ConfigParser()
p.read(ini)
if db not in p:
    sys.exit(2)
sec = p[db]
user = (sec.get('connuser', '') or du).strip()
pw   = (sec.get('connpass', '') or '').strip()
host = (sec.get('dbhost', '') or sec.get('ansible_servername', '') or dh).strip()
port = (sec.get('dbport', '') or dp).strip()
print(f"{user}\t{pw}\t{host}\t{port}")
PY
}

db_section_value() {
    local db="$1" key="$2"
    python3 - "$DATABASES_INI" "$db" "$key" <<'PY'
import configparser, sys
ini, db, key = sys.argv[1], sys.argv[2], sys.argv[3]
p = configparser.ConfigParser()
p.read(ini)
print(p.get(db, key, fallback=''))
PY
}

# ---------------------------------------------------------------------------
# mysql client runners. SQL statements are read from stdin.
#   sql  <DB>           formatted output (column headers, table borders)
#   sqlx <DB>           -N -B output (no headers, tab-separated) — for parsing
#   scalar <DB> "<q>"   single trimmed value
#
# The connection defaults file is written to a private temp file so the
# password never appears in the process list.
# ---------------------------------------------------------------------------
_mysql_defaults_file() {
    local db="$1" creds user pw host port f
    creds="$(db_credentials "$db")" || { err "no credentials for $db"; return 2; }
    IFS=$'\t' read -r user pw host port <<<"$creds"
    f="$(mktemp /tmp/.my_XXXXXX.cnf)"
    chmod 600 "$f"
    {
        printf '[client]\n'
        printf 'user=%s\n' "$user"
        [[ -n "$pw"   ]] && printf 'password=%s\n' "$pw"
        [[ -n "$host" ]] && printf 'host=%s\n' "$host"
        [[ -n "$port" ]] && printf 'port=%s\n' "$port"
    } > "$f"
    printf '%s' "$f"
}

_run_mysql() {
    # _run_mysql <db> <extra-flags...>  (query on stdin)
    local db="$1"; shift
    local qf cnf rc
    cnf="$(_mysql_defaults_file "$db")" || return 2
    qf="$(mktemp)"; cat > "$qf"
    "$MYSQL_BIN" --defaults-extra-file="$cnf" "$@" "$db" < "$qf"; rc=$?
    rm -f "$qf" "$cnf"
    return $rc
}

sql()  { _run_mysql "$1" --table; }
sqlx() { _run_mysql "$1" -N -B; }
scalar() { printf '%s' "$2" | sqlx "$1" | tr -d '[:space:]'; }

# ---------------------------------------------------------------------------
# CheckMK local-check helpers
# ---------------------------------------------------------------------------
emit_checkmk() {
    local status="$1" item="$2" perf="$3" text="$4"
    [[ -z "$perf" ]] && perf="-"
    printf '%s %s %s %s\n' "$status" "$item" "$perf" "$text"
}

get_threshold() {
    local path="$1" def="$2"
    [[ -f "$THRESHOLDS_JSON" ]] || { echo "$def"; return; }
    python3 - "$THRESHOLDS_JSON" "$path" "$def" <<'PY'
import json, sys
try: d = json.load(open(sys.argv[1]))
except Exception:
    print(sys.argv[3]); sys.exit(0)
for k in sys.argv[2].split('.'):
    if not isinstance(d, dict) or k not in d:
        print(sys.argv[3]); sys.exit(0)
    d = d[k]
print(d if d is not None else sys.argv[3])
PY
}

# ---------------------------------------------------------------------------
# Misc
# ---------------------------------------------------------------------------
write_status_file() { printf '%s' "$2" > "$STATUS_DIR/${1}.json"; }

require_cmd() {
    for c in "$@"; do
        command -v "$c" >/dev/null 2>&1 || { err "required command not found: $c"; return 1; }
    done
}
