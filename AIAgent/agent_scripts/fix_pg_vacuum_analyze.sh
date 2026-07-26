#!/usr/bin/env bash
# Runs VACUUM ANALYZE on all user tables in all non-template databases.
# Reclaims dead tuple bloat and updates planner statistics.
# Runs as: postgres (via sudo -u postgres run_fix.sh)
set -euo pipefail

echo "[$(date +%T)] Running VACUUM ANALYZE on PostgreSQL databases..."

# Get all non-template databases
DBS=$(psql -U postgres -At -c "SELECT datname FROM pg_database WHERE datistemplate = false AND datallowconn = true;" postgres 2>/dev/null || \
      psql -At -c "SELECT datname FROM pg_database WHERE datistemplate = false AND datallowconn = true;" postgres)

for DB in $DBS; do
    echo "  VACUUM ANALYZE on: $DB"
    psql -U postgres -c "VACUUM ANALYZE;" "$DB" 2>/dev/null || \
    psql -c "VACUUM ANALYZE;" "$DB" || \
    echo "  Warning: VACUUM ANALYZE failed on $DB"
done

echo "[$(date +%T)] VACUUM ANALYZE complete."
