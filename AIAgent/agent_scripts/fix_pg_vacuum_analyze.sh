#!/usr/bin/env bash
# Runs VACUUM ANALYZE on all user tables in all non-template databases.
# Reclaims dead tuple bloat and updates planner statistics.
# Runs as: postgres (via sudo -u postgres run_fix.sh)
set -euo pipefail
source "$(dirname "$0")/_common.sh"

# --- Check: psql available before attempting VACUUM ANALYZE ---
require_cmd psql

echo "[$(date +%T)] Running VACUUM ANALYZE on PostgreSQL databases..."

# --- Check: get all non-template databases; skip if none are connectable ---
DBS=$(psql -U postgres -At -c "SELECT datname FROM pg_database WHERE datistemplate = false AND datallowconn = true;" postgres 2>/dev/null || \
      psql -At -c "SELECT datname FROM pg_database WHERE datistemplate = false AND datallowconn = true;" postgres 2>/dev/null || echo "")

if [[ -z "${DBS//[[:space:]]/}" ]]; then
    save_action "SKIP" "no connectable PostgreSQL databases found for VACUUM ANALYZE"
    echo "[$(date +%T)] No databases to process."
    exit 0
fi

COUNT=0
for DB in $DBS; do
    echo "  VACUUM ANALYZE on: $DB"
    if psql -U postgres -c "VACUUM ANALYZE;" "$DB" 2>/dev/null || \
       psql -c "VACUUM ANALYZE;" "$DB" 2>/dev/null; then
        COUNT=$((COUNT+1))
    else
        echo "  Warning: VACUUM ANALYZE failed on $DB"
    fi
done

save_action "DONE" "VACUUM ANALYZE completed on $COUNT PostgreSQL database(s)"
echo "[$(date +%T)] VACUUM ANALYZE complete."
