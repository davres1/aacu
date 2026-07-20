#!/usr/bin/env bash
# BackupDatabases.sh [Full|Incr|Log] — cron-scheduled active backup driver.
# NOT exposed as a chatbot intent (the bot stays read-only + bounded ops).
#   Full : logical dump of each schema via mysqldump (--single-transaction).
#   Incr : physical incremental via mariabackup (no native mysqldump analogue).
#   Log  : flush binary logs and archive them aside (point-in-time recovery
#          source; binlogs are instance-wide, so there is no per-schema loop).
# Online consistency for Full relies on --single-transaction (InnoDB);
# point-in-time recovery relies on binary logging being enabled (log_bin).
source "$(dirname "$0")/lib/mysql_common.sh"
set -o pipefail

TYPE="${1:-Full}"
BACKUP_ROOT="${BACKUP_ROOT:-/backup/mysql}"
mkdir -p "$BACKUP_ROOT" 2>/dev/null || true
rc=0

# Build a private [client] defaults file so the password never hits the
# process list. Echoes the path; caller must rm it.
make_cnf() {
    local db="$1" creds user pw host port f
    creds="$(db_credentials "$db")" || return 2
    IFS=$'\t' read -r user pw host port <<<"$creds"
    f="$(mktemp)"; chmod 600 "$f"
    {
        printf '[client]\n'
        printf 'user=%s\n' "$user"
        [ -n "$pw"   ] && printf 'password=%s\n' "$pw"
        [ -n "$host" ] && printf 'host=%s\n' "$host"
        [ -n "$port" ] && printf 'port=%s\n' "$port"
    } > "$f"
    printf '%s' "$f"
}

case "$TYPE" in
    Full|Incr)
        for db in $(list_databases); do
            mkdir -p "$BACKUP_ROOT/$db"
            cnf="$(make_cnf "$db")" || { err "no credentials for $db"; rc=1; continue; }
            case "$TYPE" in
                Full)
                    log "FULL logical backup of $db -> $BACKUP_ROOT/$db"
                    out="$BACKUP_ROOT/$db/full_$(date +%Y%m%d_%H%M%S).sql.gz"
                    if mysqldump --defaults-extra-file="$cnf" --single-transaction \
                            --routines --triggers --events --databases "$db" \
                            2>>"$LOG_FILE" | gzip > "$out"; then
                        log "wrote $out"
                    else
                        err "mysqldump failed for $db"; rc=1; rm -f "$out"
                    fi
                    ;;
                Incr)
                    log "INCREMENTAL physical backup of $db -> $BACKUP_ROOT/$db"
                    if command -v mariabackup >/dev/null 2>&1; then
                        # Chain onto the most recent physical backup dir; if none
                        # exists yet, seed a physical base for future increments.
                        base="$(ls -1dt "$BACKUP_ROOT/$db"/base_* "$BACKUP_ROOT/$db"/incr_* 2>/dev/null | head -1)"
                        if [ -n "$base" ]; then
                            tgt="$BACKUP_ROOT/$db/incr_$(date +%Y%m%d_%H%M%S)"
                            mariabackup --defaults-extra-file="$cnf" --backup \
                                --target-dir="$tgt" --incremental-basedir="$base" \
                                >>"$LOG_FILE" 2>&1 || rc=1
                        else
                            warn "no base backup for $db; seeding physical base_ dir"
                            tgt="$BACKUP_ROOT/$db/base_$(date +%Y%m%d_%H%M%S)"
                            mariabackup --defaults-extra-file="$cnf" --backup \
                                --target-dir="$tgt" >>"$LOG_FILE" 2>&1 || rc=1
                        fi
                    else
                        # NOTE: true incremental backups require mariabackup
                        # (package mariadb-backup / percona-xtrabackup).
                        warn "mariabackup not installed — incremental unavailable; skipping $db"
                        rc=1
                    fi
                    ;;
            esac
            rm -f "$cnf"
        done
        ;;
    Log)
        # Point-in-time recovery source = the binary logs. Flush to close the
        # active binlog, then copy the closed binlogs aside. Binary logs are
        # instance-wide, so (unlike Db2's per-DB archive log) this runs once.
        log "flush + archive binary logs -> $BACKUP_ROOT/binlogs"
        first="$(list_databases | head -1)"
        dest="$BACKUP_ROOT/binlogs"
        mkdir -p "$dest"
        if [ -z "$first" ]; then
            err "no databases listed; nothing to connect through for FLUSH"; rc=1
        else
            printf 'FLUSH BINARY LOGS;\n' | sqlx "$first" >>"$LOG_FILE" 2>&1 || rc=1
            basename_path="$(scalar "$first" "SELECT @@global.log_bin_basename")"
            if [ -n "$basename_path" ]; then
                shopt -s nullglob
                for f in "${basename_path}".[0-9]*; do
                    # -n: never clobber an already-archived binlog.
                    cp -pn "$f" "$dest/" 2>>"$LOG_FILE" || rc=1
                done
                shopt -u nullglob
                log "archived binary logs from ${basename_path}.* to $dest"
            else
                warn "binary logging disabled (log_bin_basename empty) — cannot archive logs"; rc=1
            fi
        fi
        ;;
    *)
        err "unknown backup type: $TYPE (expected Full|Incr|Log)"; exit 2 ;;
esac
exit $rc
