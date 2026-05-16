#!/usr/bin/env bash
# BackupDatabases.sh — RMAN full / incremental / archive-log backups.
#
#   BackupDatabases.sh Full [DB ...]
#   BackupDatabases.sh Incr [DB ...]
#   BackupDatabases.sh Log  [DB ...]
#
# If no DB args supplied, iterates every section in databases.ini. Parallelism
# is controlled by PARALLEL (default 2 concurrent DBs).

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/oracle_common.sh"

BACKUP_TYPE="${1:-Full}"; shift || true
BACKUP_ROOT="${BACKUP_ROOT:-/backup/oracle}"
RETENTION_DAYS="${RETENTION_DAYS:-14}"
PARALLEL="${PARALLEL:-2}"
mkdir -p "$BACKUP_ROOT"

databases=("$@")
[[ ${#databases[@]} -eq 0 ]] && mapfile -t databases < <(list_databases)

case "$BACKUP_TYPE" in
    Full|Incr|Log) ;;
    *) err "BACKUP_TYPE must be Full | Incr | Log (got '$BACKUP_TYPE')"; exit 1 ;;
esac

backup_one() {
    local db="$1"
    local out="$BACKUP_ROOT/$db/$BACKUP_TYPE"
    mkdir -p "$out"
    log "→ $db [$BACKUP_TYPE]"

    # Build the RMAN command set for the chosen mode.
    local rman_block
    case "$BACKUP_TYPE" in
        Full)
            rman_block="BACKUP AS COMPRESSED BACKUPSET DATABASE PLUS ARCHIVELOG FORMAT '$out/full_%U.bkp' TAG 'FULL_$(date +%Y%m%d)';"
            ;;
        Incr)
            rman_block="BACKUP AS COMPRESSED BACKUPSET INCREMENTAL LEVEL 1 DATABASE FORMAT '$out/incr_%U.bkp' TAG 'INCR_$(date +%Y%m%d)';"
            ;;
        Log)
            rman_block="BACKUP ARCHIVELOG ALL DELETE INPUT FORMAT '$out/arch_%U.bkp' TAG 'LOG_$(date +%Y%m%d_%H%M)';"
            ;;
    esac

    # Resolve credentials (sys with sysdba for the BACKUP).
    local creds u p
    creds="$(db_credentials "$db" sys)" || { err "no sys creds for $db"; return 1; }
    u="${creds%% *}"; p="${creds#* }"
    local start_ts; start_ts=$(date +%s)

    if rman target "$u/$p@$db AS SYSDBA" log="$LOG_DIR/rman_${db}_${BACKUP_TYPE}_$(date +%Y%m%d_%H%M%S).log" <<RMAN 2>>"$LOG_FILE"
CONFIGURE RETENTION POLICY TO RECOVERY WINDOW OF $RETENTION_DAYS DAYS;
CONFIGURE CONTROLFILE AUTOBACKUP ON;
$rman_block
DELETE NOPROMPT OBSOLETE;
CROSSCHECK BACKUP;
DELETE NOPROMPT EXPIRED BACKUP;
RMAN
    then
        local dur=$(( $(date +%s) - start_ts ))
        log "   OK $db [$BACKUP_TYPE] in ${dur}s"
        return 0
    else
        warn "   FAILED $db [$BACKUP_TYPE]"
        return 1
    fi
}

export -f backup_one log warn err ts db_credentials
export LOG_FILE LOG_DIR DATABASES_INI BACKUP_ROOT BACKUP_TYPE RETENTION_DAYS

log "=== BackupDatabases $BACKUP_TYPE start (parallel=$PARALLEL, dbs=${#databases[@]}) ==="

if command -v parallel >/dev/null 2>&1; then
    printf '%s\n' "${databases[@]}" | parallel -j "$PARALLEL" --will-cite backup_one
else
    # Bash background-job fallback
    running=0
    for db in "${databases[@]}"; do
        backup_one "$db" &
        ((running++))
        if (( running >= PARALLEL )); then
            wait -n 2>/dev/null || wait
            ((running--))
        fi
    done
    wait
fi

log "=== BackupDatabases $BACKUP_TYPE done ==="
