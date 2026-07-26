#!/usr/bin/env bash
# Terminates PostgreSQL sessions that are blocking others for > 30 minutes.
# Runs as: postgres (via sudo -u postgres run_fix.sh)
set -euo pipefail

echo "[$(date +%T)] Killing long-running PostgreSQL blocking sessions..."

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

echo "[$(date +%T)] Done. Blocking sessions terminated."
