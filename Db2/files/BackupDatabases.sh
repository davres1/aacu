#!/usr/bin/env bash
# BackupDatabases.sh [Full|Incr|Log] — cron-scheduled active backup driver.
# NOT exposed as a chatbot intent (the bot stays read-only + bounded ops).
# Online backups require LOGARCHMETH1 to be set on each database.
source "$(dirname "$0")/lib/db2_common.sh"

TYPE="${1:-Full}"
BACKUP_ROOT="${BACKUP_ROOT:-/backup/db2}"
mkdir -p "$BACKUP_ROOT" 2>/dev/null || true
rc=0

for db in $(list_databases); do
    case "$TYPE" in
        Full)
            log "FULL online backup of $db -> $BACKUP_ROOT"
            db2 backup database "$db" online to "$BACKUP_ROOT" compress >>"$LOG_FILE" 2>&1 || rc=1
            ;;
        Incr)
            log "INCREMENTAL online backup of $db -> $BACKUP_ROOT"
            db2 backup database "$db" online incremental to "$BACKUP_ROOT" compress >>"$LOG_FILE" 2>&1 || rc=1
            ;;
        Log)
            log "archive logs for $db"
            db2 archive log for database "$db" >>"$LOG_FILE" 2>&1 || rc=1
            ;;
        *)
            err "unknown backup type: $TYPE (expected Full|Incr|Log)"; exit 2 ;;
    esac
done
exit $rc
