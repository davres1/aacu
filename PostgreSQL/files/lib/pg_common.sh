# pg_common.sh — shared helpers for every PostgreSQL DBA script.
# Source this at the top of each script:  source "$(dirname "$0")/lib/pg_common.sh"
#
# Reads connection info from databases.ini (one section per database, e.g.):
#   [appdb]
#   connuser = dba
#   connpass = ********
#   dbhost   = pghost01
#   dbport   = 5432
#   ansible_servername = pghost01
#
# Defaults assume the script runs on the DB host (or a host that can reach it)
# with the psql client on PATH. Connection details fall back to local socket
# as postgres when a section omits host/port.

# ---------------------------------------------------------------------------
# Config (override via env)
# ---------------------------------------------------------------------------
DATABASES_INI="${DATABASES_INI:-/etc/postgresql/databases.ini}"
LOG_DIR="${LOG_DIR:-/var/log/dba}"
CONFIG_DIR="${CONFIG_DIR:-/opt/dba}"
THRESHOLDS_JSON="${THRESHOLDS_JSON:-$CONFIG_DIR/thresholds.json}"
STATUS_DIR="${STATUS_DIR:-$LOG_DIR/status}"
mkdir -p "$LOG_DIR" "$STATUS_DIR" 2>/dev/null || true

PG_SCRIPT_NAME="$(basename "${0:-pg-dba}" .sh)"
LOG_FILE="${LOG_FILE:-$LOG_DIR/${PG_SCRIPT_NAME}_$(date +%Y%m%d).log}"

# psql client binary — override if needed.
PSQL_BIN="${PSQL_BIN:-psql}"
PG_DEFAULT_USER="${PG_DEFAULT_USER:-postgres}"
PG_DEFAULT_HOST="${PG_DEFAULT_HOST:-localhost}"
PG_DEFAULT_PORT="${PG_DEFAULT_PORT:-5432}"

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
RESERVED = {'postgresql_servers', 'DEFAULT'}
for s in p.sections():
    if s in RESERVED:
        continue
    if not flt or flt in s.lower():
        print(s)
PY
}

# db_credentials <DB> -> "connuser connpass dbhost dbport"
# connuser defaults to postgres, dbhost to localhost, dbport to 5432.
# connpass may be empty (peer/ident auth or .pgpass file).
db_credentials() {
    local db="$1"
    python3 - "$DATABASES_INI" "$db" "$PG_DEFAULT_USER" "$PG_DEFAULT_HOST" "$PG_DEFAULT_PORT" <<'PY'
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
# psql client runners. SQL statements are read from stdin or passed as arg.
#   sql  <DB>           formatted output (with headers and column alignment)
#   sqlx <DB>           unaligned pipe-separated tuples-only (-t -A -F'|') for parsing
#   scalar <DB> "<q>"   single trimmed value
#
# PGPASSWORD is exported for the duration of the call only (subshell).
# The password never appears in the process list.
# ---------------------------------------------------------------------------
_run_psql() {
    # _run_psql <db> <extra-flags...>  (query on stdin)
    local db="$1"; shift
    local creds user pw host port qf rc
    creds="$(db_credentials "$db")" || { err "no credentials for $db"; return 2; }
    IFS=$'\t' read -r user pw host port <<<"$creds"
    qf="$(mktemp)"; cat > "$qf"
    (
        [ -n "$pw" ] && export PGPASSWORD="$pw"
        "$PSQL_BIN" -U "$user" -h "$host" -p "$port" -d "$db" "$@" -f "$qf"
    ); rc=$?
    rm -f "$qf"
    return $rc
}

# sql: formatted output (headers + alignment) — for human-readable logs.
sql()  { _run_psql "$1"; }

# sqlx: unaligned, pipe-separated, tuples-only — for machine parsing.
sqlx() { _run_psql "$1" -t -A -F'|'; }

# scalar: single trimmed value from a one-cell query.
scalar() {
    local db="$1" query="$2" creds user pw host port val
    creds="$(db_credentials "$db")" || return 2
    IFS=$'\t' read -r user pw host port <<<"$creds"
    val="$(
        [ -n "$pw" ] && export PGPASSWORD="$pw"
        echo "$query" | "$PSQL_BIN" -U "$user" -h "$host" -p "$port" -d "$db" -t -A -F'|' 2>/dev/null | head -1
    )"
    printf '%s' "${val}" | tr -d '[:space:]'
}

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
