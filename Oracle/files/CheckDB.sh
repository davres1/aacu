#!/usr/bin/env bash
# CheckDB.sh — Oracle equivalent of DBCC CHECKDB.
# Runs RMAN BACKUP VALIDATE CHECK LOGICAL DATABASE (header + logical-block
# corruption check, no actual backup written). Writes status JSON to
# $STATUS_DIR/checkdb_status.json for the CheckMK plugin to read.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/oracle_common.sh"

PARALLEL="${PARALLEL:-1}"
report='[]'

databases=("$@")
[[ ${#databases[@]} -eq 0 ]] && mapfile -t databases < <(list_databases)

check_one() {
    local db="$1"
    local creds u p
    creds="$(db_credentials "$db" sys)" || { err "no sys creds for $db"; return 2; }
    u="${creds%% *}"; p="${creds#* }"
    local start_ts=$(date +%s)
    local rman_log="$LOG_DIR/checkdb_${db}_$(date +%Y%m%d_%H%M%S).log"

    if rman target "$u/$p@$db AS SYSDBA" log="$rman_log" >>"$LOG_FILE" 2>&1 <<'RMAN'
BACKUP VALIDATE CHECK LOGICAL DATABASE;
RMAN
    then
        local dur=$(( $(date +%s) - start_ts ))
        # Look for "VALIDATE failed" or "corrupt blocks" lines in the RMAN log.
        local corrupt=$(grep -ciE 'corrupt|failed' "$rman_log" || true)
        if [[ $corrupt -eq 0 ]]; then
            echo "{\"database\":\"$db\",\"status\":\"clean\",\"duration_sec\":$dur,\"log\":\"$rman_log\"}"
        else
            echo "{\"database\":\"$db\",\"status\":\"errors\",\"duration_sec\":$dur,\"log\":\"$rman_log\"}"
        fi
    else
        local dur=$(( $(date +%s) - start_ts ))
        echo "{\"database\":\"$db\",\"status\":\"failed\",\"duration_sec\":$dur,\"log\":\"$rman_log\"}"
    fi
}

log "=== CheckDB start (parallel=$PARALLEL, dbs=${#databases[@]}) ==="

tmp_results="$(mktemp)"
trap "rm -f $tmp_results" EXIT

if command -v parallel >/dev/null 2>&1; then
    export -f check_one log warn err ts db_credentials
    export LOG_DIR LOG_FILE DATABASES_INI
    printf '%s\n' "${databases[@]}" | parallel -j "$PARALLEL" --will-cite check_one >> "$tmp_results"
else
    for db in "${databases[@]}"; do
        check_one "$db" >> "$tmp_results"
    done
fi

# Merge results
items=$(paste -sd, "$tmp_results")
clean=$(grep -c '"clean"'  "$tmp_results" || true)
errors=$(grep -c '"errors"' "$tmp_results" || true)
failed=$(grep -c '"failed"' "$tmp_results" || true)
summary=$(python3 -c "
import json
print(json.dumps({
  'timestamp': '$(ts)',
  'total':  $clean + $errors + $failed,
  'clean':  $clean,
  'errors': $errors,
  'failed': $failed,
  'items':  [json.loads(x) for x in '''$items'''.split(',') if x.strip()],
}))")

write_status_file "checkdb_status" "$summary"
echo "$summary"
log "=== CheckDB finished clean=$clean errors=$errors failed=$failed ==="
exit $(( errors + failed > 0 ? 1 : 0 ))
