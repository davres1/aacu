# db2_common.sh — shared helpers for every Db2 (LUW) DBA script.
# Source this at the top of each script:  source "$(dirname "$0")/lib/db2_common.sh"
#
# Reads database connection info from databases.ini (one section per DB, e.g.):
#   [SAMPLE]
#   connuser = db2inst1
#   connpass = ********
#   ansible_servername = db2host01
#
# Defaults assume the script runs as the 'db2inst1' instance owner with the
# instance profile (~/sqllib/db2profile) sourced.

# ---------------------------------------------------------------------------
# Config (override via env)
# ---------------------------------------------------------------------------
DATABASES_INI="${DATABASES_INI:-/etc/db2/databases.ini}"
LOG_DIR="${LOG_DIR:-/var/log/dba}"
CONFIG_DIR="${CONFIG_DIR:-/opt/dba}"
THRESHOLDS_JSON="${THRESHOLDS_JSON:-$CONFIG_DIR/thresholds.json}"
STATUS_DIR="${STATUS_DIR:-$LOG_DIR/status}"
mkdir -p "$LOG_DIR" "$STATUS_DIR" 2>/dev/null || true

DB2_SCRIPT_NAME="$(basename "${0:-db2-dba}" .sh)"
LOG_FILE="${LOG_FILE:-$LOG_DIR/${DB2_SCRIPT_NAME}_$(date +%Y%m%d).log}"

# Make the db2 CLP usable under cron / ansible non-login shells.
db2_env() { source ~/sqllib/db2profile 2>/dev/null || true; }
db2_env

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
RESERVED = {'db2_servers', 'DEFAULT'}
for s in p.sections():
    if s in RESERVED:
        continue
    if not flt or flt in s.lower():
        print(s)
PY
}

# db_credentials <DB> -> "connuser connpass"  (connuser defaults to db2inst1)
db_credentials() {
    local db="$1"
    python3 - "$DATABASES_INI" "$db" <<'PY'
import configparser, sys
ini, db = sys.argv[1], sys.argv[2]
p = configparser.ConfigParser()
p.read(ini)
if db not in p:
    sys.exit(2)
sec = p[db]
user = (sec.get('connuser', '') or 'db2inst1').strip()
pw   = (sec.get('connpass', '') or '').strip()
if not pw:
    sys.exit(3)
print(f"{user} {pw}")
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
# db2 CLP runners. SQL statements are read from stdin and must be ';'-terminated.
#   sql  <DB>           formatted output (column headers)
#   sqlx <DB>           -x output (no headers/footers) — for parsing
#   scalar <DB> "<q>"   single trimmed value
# ---------------------------------------------------------------------------
_db2_connect() {
    local db="$1" creds u p
    creds="$(db_credentials "$db")" || { err "no credentials for $db"; return 2; }
    u="${creds%% *}"; p="${creds#* }"
    db2 connect to "$db" user "$u" using "$p" >/dev/null 2>&1 \
        || { err "connect failed: $db"; return 2; }
}

sql() {
    local db="$1" qf rc
    qf="$(mktemp)"; cat > "$qf"
    _db2_connect "$db" || { rm -f "$qf"; return 2; }
    db2 +o -tf "$qf"; rc=$?
    db2 connect reset >/dev/null 2>&1 || true
    rm -f "$qf"
    return $rc
}

sqlx() {
    local db="$1" qf rc
    qf="$(mktemp)"; cat > "$qf"
    _db2_connect "$db" || { rm -f "$qf"; return 2; }
    db2 +o -x -tf "$qf"; rc=$?
    db2 connect reset >/dev/null 2>&1 || true
    rm -f "$qf"
    return $rc
}

scalar() { printf '%s;\n' "$2" | sqlx "$1" | tr -d '[:space:]'; }

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
