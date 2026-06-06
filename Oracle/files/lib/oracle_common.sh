# oracle_common.sh — shared helpers for every Oracle DBA script.
# Source this at the top of each script:  source "$(dirname "$0")/lib/oracle_common.sh"
#
# Reads database credentials from databases.ini (one section per DB, e.g.):
#   [PHHSDG8]
#   username = {'system':'pw','sys':'pw','sfmfg':'sfmfg'}
#   syspass  = pw
#
# Defaults assume the script runs as the 'oracle' OS user with ORACLE_HOME set.

# ---------------------------------------------------------------------------
# Config (override via env)
# ---------------------------------------------------------------------------
DATABASES_INI="${DATABASES_INI:-/etc/oracle/databases.ini}"
LOG_DIR="${LOG_DIR:-/var/log/dba}"
CONFIG_DIR="${CONFIG_DIR:-/opt/dba}"
THRESHOLDS_JSON="${THRESHOLDS_JSON:-$CONFIG_DIR/thresholds.json}"
STATUS_DIR="${STATUS_DIR:-$LOG_DIR/status}"
mkdir -p "$LOG_DIR" "$STATUS_DIR" 2>/dev/null || true

ORA_SCRIPT_NAME="$(basename "${0:-oracle-dba}" .sh)"
LOG_FILE="${LOG_FILE:-$LOG_DIR/${ORA_SCRIPT_NAME}_$(date +%Y%m%d).log}"

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
for s in p.sections():
    if not flt or flt in s.lower():
        print(s)
PY
}

db_credentials() {
    local db="$1" want="${2:-system}"
    python3 - "$DATABASES_INI" "$db" "$want" <<'PY'
import configparser, ast, sys
ini, db, want = sys.argv[1], sys.argv[2], sys.argv[3]
p = configparser.ConfigParser()
p.read(ini)
if db not in p:
    sys.exit(2)
sec = p[db]
syspass = sec.get('syspass', '').strip()
try:
    users = ast.literal_eval(sec.get('username', '{}'))
    if not isinstance(users, dict): users = {}
except Exception:
    users = {}
pw = users.get(want) or (syspass if want in ('system', 'sys') else '')
if not pw:
    sys.exit(3)
print(f"{want} {pw}")
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
# sqlplus runner
# ---------------------------------------------------------------------------
sql() {
    local db="$1" user="${2:-system}"
    local creds u p
    creds="$(db_credentials "$db" "$user")" || { err "no credentials for $db (user=$user)"; return 2; }
    u="${creds%% *}"; p="${creds#* }"
    sqlplus -S -L "$u/$p@$db" <<EOF
SET PAGESIZE 0 FEEDBACK OFF VERIFY OFF HEADING OFF ECHO OFF
SET LINESIZE 32767 TRIMSPOOL ON SERVEROUTPUT ON SIZE UNLIMITED
WHENEVER SQLERROR EXIT 1
$(cat)
EXIT;
EOF
}

# scalar <DB> "<select-one-value>" — convenience: trims whitespace.
scalar() { sql "$1" <<<"$2" | tr -d '[:space:]'; }

sql_as_sysdba() {
    # For ops that need SYSDBA on the local DB (RMAN preview, ALTER SYSTEM).
    # Caller must have set ORACLE_SID + ORACLE_HOME first.
    sqlplus -S -L "/ as sysdba" <<EOF
SET PAGESIZE 0 FEEDBACK OFF VERIFY OFF HEADING OFF ECHO OFF
SET LINESIZE 32767 TRIMSPOOL ON SERVEROUTPUT ON SIZE UNLIMITED
WHENEVER SQLERROR EXIT 1
$(cat)
EXIT;
EOF
}

# Load Oracle env for a SID (oraenv-style without prompting).
ora_env() {
    local sid="$1"
    export ORACLE_SID="$sid"
    if [[ -z "${ORACLE_HOME:-}" ]]; then
        # Resolve from /etc/oratab
        ORACLE_HOME="$(awk -F: -v s="$sid" '$1 == s && $0 !~ /^#/ {print $2; exit}' /etc/oratab 2>/dev/null)"
    fi
    [[ -n "$ORACLE_HOME" ]] || { err "ORACLE_HOME not found for SID=$sid"; return 1; }
    export ORACLE_HOME
    export PATH="$ORACLE_HOME/bin:$PATH"
    export LD_LIBRARY_PATH="$ORACLE_HOME/lib:${LD_LIBRARY_PATH:-}"
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
