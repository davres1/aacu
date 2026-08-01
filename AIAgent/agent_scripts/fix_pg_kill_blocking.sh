#!/usr/bin/env bash
# Terminates PostgreSQL sessions that are blocking others for > 30 minutes.
# Runs as: postgres (via sudo -u postgres run_fix.sh)
set -euo pipefail
source "$(dirname "$0")/_common.sh"

# --- Check: psql available before attempting to terminate sessions ---
require_cmd psql

echo "[$(date +%T)] Checking for PostgreSQL blocking sessions > 30 min..."

# --- Check: is there anything to terminate? (same predicate as the kill below) ---
CANDIDATES=$(psql -U postgres -At -c "
  SELECT count(*) FROM pg_stat_activity
  WHERE state != 'idle'
    AND wait_event_type = 'Lock'
    AND query_start < now() - interval '30 minutes'
    AND pid <> pg_backend_pid();
" postgres 2>/dev/null || psql -At -c "
  SELECT count(*) FROM pg_stat_activity
  WHERE state != 'idle'
    AND wait_event_type = 'Lock'
    AND query_start < now() - interval '30 minutes'
    AND pid <> pg_backend_pid();
" postgres 2>/dev/null || echo 0)
CANDIDATES="${CANDIDATES//[!0-9]/}"; CANDIDATES="${CANDIDATES:-0}"

if [[ "$CANDIDATES" -eq 0 ]]; then
    save_action "SKIP" "no PostgreSQL sessions blocking >30 min"
    echo "[$(date +%T)] Nothing to terminate."
    exit 0
fi

echo "Terminating $CANDIDATES blocking session(s)..."
psql -U postgres -At postgres 2>/dev/null <<'SQL' || \
psql -At postgres <<'SQL'
SELECT
    'Terminating pid=' || pid || ' user=' || usename ||
    ' waiting=' || wait_event_type || '/' || coalesce(wait_event,'?') ||
    ' query_age=' || now() - query_start
FROM pg_stat_activity
WHERE state != 'idle'
  AND wait_event_type = 'Lock'
  AND query_start < now() - interval '30 minutes'
  AND pid <> pg_backend_pid();

SELECT pg_terminate_backend(pid)
FROM pg_stat_activity
WHERE state != 'idle'
  AND wait_event_type = 'Lock'
  AND query_start < now() - interval '30 minutes'
  AND pid <> pg_backend_pid();
SQL

save_action "DONE" "terminated $CANDIDATES PostgreSQL session(s) blocking >30 min"
echo "[$(date +%T)] Done. Blocking sessions terminated."
