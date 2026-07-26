#!/usr/bin/env bash
# BackupDatabases.sh [Full|Incr|Log] — cron-scheduled active backup driver.
# NOT exposed as a chatbot intent (the bot stays read-only + bounded ops).
#   Full : logical dump of each database via pg_dump (custom format, compressed).
#   Incr : physical base backup via pg_basebackup (instance-wide, not per-db).
#          Each run creates a new base from which point-in-time recovery works.
#   Log  : switch the current WAL segment and archive WAL files to BACKUP_ROOT/wal/
#          (mirrors MySQL's binlog archive; WAL is instance-wide).
# Online consistency for Full relies on pg_dump's snapshot isolation.
# Point-in-time recovery relies on WAL archiving being configured (archive_mode).
source "$(dirname "$0")/lib/pg_common.sh"
set -o pipefail

TYPE="${1:-Full}"
BACKUP_ROOT="${BACKUP_ROOT:-/backup/postgresql}"
mkdir -p "$BACKUP_ROOT" 2>/dev/null || true
rc=0

case "$TYPE" in
    Full)
        for db in $(list_databases); do
            mkdir -p "$BACKUP_ROOT/$db"
            creds="$(db_credentials "$db")" || { err "no credentials for $db"; rc=1; continue; }
            IFS=$'\t' read -r user pw host port <<<"$creds"

            log "FULL logical backup of $db -> $BACKUP_ROOT/$db"
            out="$BACKUP_ROOT/$db/full_$(date +%Y%m%d_%H%M%S).dump"
            if (
                [ -n "$pw" ] && export PGPASSWORD="$pw"
                pg_dump -U "$user" -h "$host" -p "$port" -d "$db" \
                    -F c -Z 9 -f "$out" 2>>"$LOG_FILE"
            ); then
                log "wrote $out"
            else
                err "pg_dump failed for $db"; rc=1; rm -f "$out"
            fi
        done
        ;;

    Incr)
        # pg_basebackup is instance-wide (not per-database). Use the first
        # configured database's credentials to authenticate.
        first="$(list_databases | head -1)"
        if [ -z "$first" ]; then
            err "no databases listed; cannot determine connection details for pg_basebackup"
            exit 1
        fi
        creds="$(db_credentials "$first")" || { err "no credentials for $first"; exit 1; }
        IFS=$'\t' read -r user pw host port <<<"$creds"

        tgt="$BACKUP_ROOT/base_$(date +%Y%m%d_%H%M%S)"
        mkdir -p "$tgt"
        log "PHYSICAL base backup -> $tgt"
        if (
            [ -n "$pw" ] && export PGPASSWORD="$pw"
            pg_basebackup -U "$user" -h "$host" -p "$port" \
                -D "$tgt" -F tar -z -P -X stream 2>>"$LOG_FILE"
        ); then
            log "pg_basebackup completed: $tgt"
        else
            err "pg_basebackup failed"; rc=1; rm -rf "$tgt"
        fi
        ;;

    Log)
        # Switch the current WAL segment to close it, then copy WAL files aside.
        # WAL archiving is instance-wide, so this runs once (not per-database).
        log "WAL switch + archive -> $BACKUP_ROOT/wal"
        first="$(list_databases | head -1)"
        dest="$BACKUP_ROOT/wal"
        mkdir -p "$dest"
        if [ -z "$first" ]; then
            err "no databases listed; cannot connect for pg_switch_wal"; rc=1
        else
            creds="$(db_credentials "$first")" || { err "no credentials for $first"; rc=1; }
            if [ $rc -eq 0 ]; then
                IFS=$'\t' read -r user pw host port <<<"$creds"
                # Force a WAL switch so the current segment is closed and archivable.
                if (
                    [ -n "$pw" ] && export PGPASSWORD="$pw"
                    echo "SELECT pg_switch_wal();" | \
                        psql -U "$user" -h "$host" -p "$port" -d "$first" \
                             -t -A 2>>"$LOG_FILE"
                ); then
                    log "pg_switch_wal() executed"
                else
                    warn "pg_switch_wal() failed (may be standby or no WAL activity)"; rc=1
                fi

                # Copy archived WAL files from the archive directory (if configured).
                archive_dir="$(
                    [ -n "$pw" ] && export PGPASSWORD="$pw"
                    echo "SHOW archive_status;" 2>/dev/null | \
                        psql -U "$user" -h "$host" -p "$port" -d "$first" -t -A 2>/dev/null | head -1
                )"
                data_dir="$(
                    [ -n "$pw" ] && export PGPASSWORD="$pw"
                    echo "SHOW data_directory;" | \
                        psql -U "$user" -h "$host" -p "$port" -d "$first" -t -A 2>/dev/null | tr -d ' '
                )"
                pg_wal="${data_dir%/}/pg_wal"
                if [ -d "$pg_wal" ]; then
                    shopt -s nullglob
                    for f in "$pg_wal"/[0-9A-F]*; do
                        [ -f "$f" ] && cp -pn "$f" "$dest/" 2>>"$LOG_FILE" || true
                    done
                    shopt -u nullglob
                    log "archived WAL segments from $pg_wal to $dest"
                else
                    warn "pg_wal directory not found at $pg_wal — cannot archive WAL"; rc=1
                fi
            fi
        fi
        ;;
    *)
        err "unknown backup type: $TYPE (expected Full|Incr|Log)"; exit 2 ;;
esac
exit $rc
