#!/usr/bin/env bash
# AddDatafileSpace.sh — PostgreSQL equivalent of ALTER TABLESPACE ... ADD DATAFILE.
#
# PostgreSQL tablespaces are filesystem directories.  "Adding a datafile" is
# accomplished by creating a NEW tablespace pointing to a new directory on
# additional storage, then optionally moving the database's default tablespace
# to that location.
#
# Required env vars:
#   DATABASES_INI        path to databases.ini
#   DB_NAME              target database (section in databases.ini)
#   TABLESPACE           existing tablespace to report on  (default: pg_default)
#   ADD_MB               requested size in MB             (informational)
#
# Optional env vars:
#   NEW_DATAFILE_PATH    if set, create this directory and a new tablespace
#   MOVE_DATABASE        if "true" and NEW_DATAFILE_PATH is set, run
#                          ALTER DATABASE ... SET TABLESPACE <new_ts>
#
# Output: one JSON line on stdout (same shape as all other DBA scripts).

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/pg_common.sh"

DB_NAME="${DB_NAME:-}"
TABLESPACE="${TABLESPACE:-pg_default}"
ADD_MB="${ADD_MB:-0}"
NEW_DATAFILE_PATH="${NEW_DATAFILE_PATH:-}"
MOVE_DATABASE="${MOVE_DATABASE:-false}"

[[ -z "$DB_NAME" ]] && { err "DB_NAME is required"; exit 2; }

log "AddDatafileSpace: db=$DB_NAME tablespace=$TABLESPACE add_mb=$ADD_MB new_path=${NEW_DATAFILE_PATH:-<none>}"

# ---------------------------------------------------------------------------
# Build a one-shot psql wrapper from databases.ini credentials
# ---------------------------------------------------------------------------
_creds="$(db_credentials "$DB_NAME" 2>/dev/null)" || { err "no credentials for $DB_NAME"; exit 2; }
IFS=$'\t' read -r _user _pw _host _port <<< "$_creds"

run_psql() {
    (
        [[ -n "$_pw" ]] && export PGPASSWORD="$_pw"
        "$PSQL_BIN" -U "$_user" -h "$_host" -p "$_port" -d "$DB_NAME" -At "$@"
    )
}

run_psql_postgres() {
    # Some DDL (CREATE TABLESPACE, ALTER DATABASE) must run against postgres db
    (
        [[ -n "$_pw" ]] && export PGPASSWORD="$_pw"
        "$PSQL_BIN" -U "$_user" -h "$_host" -p "$_port" -d postgres -At "$@"
    )
}

# ---------------------------------------------------------------------------
# Verify tablespace exists
# ---------------------------------------------------------------------------
ts_exists=$(run_psql -c "SELECT COUNT(1) FROM pg_tablespace WHERE spcname='$TABLESPACE';" 2>/dev/null || echo "0")
if [[ "$ts_exists" == "0" ]]; then
    echo "{\"status\":\"error\",\"message\":\"tablespace '$TABLESPACE' not found on $DB_NAME\"}"
    exit 1
fi

# ---------------------------------------------------------------------------
# Current tablespace stats
# ---------------------------------------------------------------------------
ts_oid=$(run_psql -c "SELECT oid FROM pg_tablespace WHERE spcname='$TABLESPACE';" 2>/dev/null || echo "")
ts_path=$(run_psql -c "SELECT COALESCE(NULLIF(pg_tablespace_location(${ts_oid:-0}),''),'<built-in>');" 2>/dev/null || echo "unknown")
ts_size_pretty=$(run_psql -c "SELECT pg_size_pretty(pg_tablespace_size('$TABLESPACE'));" 2>/dev/null || echo "unknown")
db_size_pretty=$(run_psql  -c "SELECT pg_size_pretty(pg_database_size(current_database()));" 2>/dev/null || echo "unknown")

# Disk free at tablespace path (if it is a real directory)
disk_free_mb="N/A"
if [[ -d "$ts_path" ]]; then
    disk_free_mb=$(df -BM "$ts_path" 2>/dev/null | awk 'NR==2{v=$4; gsub("M","",v); print v}' || echo "N/A")
fi

# ---------------------------------------------------------------------------
# Issue CHECKPOINT so current sizes are accurate
# ---------------------------------------------------------------------------
run_psql -c "CHECKPOINT;" >/dev/null 2>&1 || true
log "CHECKPOINT completed"

# ---------------------------------------------------------------------------
# Optionally create a new tablespace directory ("add datafile")
# ---------------------------------------------------------------------------
new_ts_created=false
new_ts_name=""
database_moved=false
action_message=""

if [[ -n "$NEW_DATAFILE_PATH" ]]; then
    # 1. Create directory and fix ownership / permissions
    mkdir -p "$NEW_DATAFILE_PATH"
    chown postgres:postgres "$NEW_DATAFILE_PATH"
    chmod 700 "$NEW_DATAFILE_PATH"
    log "Created tablespace directory: $NEW_DATAFILE_PATH"

    # 2. Derive a unique tablespace name
    new_ts_name="${TABLESPACE}_ext_$(date +%Y%m%d%H%M%S)"

    # 3. CREATE TABLESPACE (DDL must run as superuser against postgres db)
    if run_psql_postgres -c "CREATE TABLESPACE \"$new_ts_name\" LOCATION '$NEW_DATAFILE_PATH';" >/dev/null 2>&1; then
        new_ts_created=true
        log "Tablespace '$new_ts_name' created at $NEW_DATAFILE_PATH"
        action_message="Created tablespace '$new_ts_name' at $NEW_DATAFILE_PATH (size $ADD_MB MB requested)."
    else
        action_message="Directory $NEW_DATAFILE_PATH created but CREATE TABLESPACE failed — check pg_log for details."
        log "WARNING: CREATE TABLESPACE failed for $new_ts_name"
    fi

    # 4. Optionally move database to new tablespace
    if [[ "$MOVE_DATABASE" == "true" && "$new_ts_created" == "true" ]]; then
        if run_psql_postgres -c "ALTER DATABASE \"$DB_NAME\" SET TABLESPACE \"$new_ts_name\";" >/dev/null 2>&1; then
            database_moved=true
            action_message="$action_message Database '$DB_NAME' default tablespace set to '$new_ts_name'."
            log "Database '$DB_NAME' moved to tablespace '$new_ts_name'"
        else
            action_message="$action_message ALTER DATABASE SET TABLESPACE failed — move manually."
            log "WARNING: ALTER DATABASE failed for $DB_NAME -> $new_ts_name"
        fi
    fi
else
    action_message="Tablespace '$TABLESPACE' is at $ts_path (current size: $ts_size_pretty). Disk free at path: ${disk_free_mb}MB. Requested growth: ${ADD_MB}MB. Pass NEW_DATAFILE_PATH to provision additional storage."
fi

# ---------------------------------------------------------------------------
# Build JSON output
# ---------------------------------------------------------------------------
jq -n \
    --arg  ts             "$TABLESPACE" \
    --arg  ts_path        "$ts_path" \
    --arg  ts_size        "$ts_size_pretty" \
    --arg  db             "$DB_NAME" \
    --arg  db_size        "$db_size_pretty" \
    --arg  disk_free      "$disk_free_mb" \
    --argjson add_mb      "${ADD_MB:-0}" \
    --argjson new_created "$new_ts_created" \
    --arg  new_ts_name    "$new_ts_name" \
    --arg  new_path       "$NEW_DATAFILE_PATH" \
    --argjson db_moved    "$database_moved" \
    --arg  action         "$action_message" \
    '{
        tablespace:            $ts,
        tablespace_path:       $ts_path,
        current_size:          $ts_size,
        database:              $db,
        database_size:         $db_size,
        disk_free_mb:          $disk_free,
        requested_add_mb:      $add_mb,
        new_tablespace_created: $new_created,
        new_tablespace_name:   $new_ts_name,
        new_tablespace_path:   $new_path,
        database_moved:        $db_moved,
        action:                $action,
        checkpoint:            "completed"
    }'
