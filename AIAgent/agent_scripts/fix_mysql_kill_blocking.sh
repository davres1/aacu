#!/usr/bin/env bash
# Kills MySQL queries running for more than 30 minutes.
# Runs as: root (via sudo -u root run_fix.sh)
set -euo pipefail
source "$(dirname "$0")/_common.sh"

# --- Check: mysql client available before attempting to kill queries ---
require_cmd mysql

echo "[$(date +%T)] Checking for MySQL queries > 30 min..."

# --- Check: is there anything to kill? (same predicate as the KILL below) ---
CANDIDATES=$(mysql -s -N -e "
  SELECT COUNT(*)
  FROM information_schema.PROCESSLIST
  WHERE COMMAND != 'Sleep'
    AND TIME > 1800
    AND USER NOT IN ('system user','event_scheduler')
    AND INFO NOT LIKE '%PROCESSLIST%';
" 2>/dev/null || echo 0)
CANDIDATES="${CANDIDATES//[!0-9]/}"; CANDIDATES="${CANDIDATES:-0}"

if [[ "$CANDIDATES" -eq 0 ]]; then
    save_action "SKIP" "no MySQL queries running >30 min"
    echo "[$(date +%T)] Nothing to kill."
    exit 0
fi

echo "Killing $CANDIDATES MySQL query(ies) > 30 min..."
# Generate and execute KILL statements
mysql -s -N -e "
  SELECT CONCAT('KILL ', id, ';')
  FROM information_schema.PROCESSLIST
  WHERE COMMAND != 'Sleep'
    AND TIME > 1800
    AND USER NOT IN ('system user','event_scheduler')
    AND INFO NOT LIKE '%PROCESSLIST%';
" 2>/dev/null | mysql 2>&1 || true

# Report remaining long queries
REMAINING=$(mysql -s -N -e "
  SELECT CONCAT('spid=', id, ' user=', USER, ' time=', ROUND(TIME/60,1), 'min cmd=', COMMAND)
  FROM information_schema.PROCESSLIST
  WHERE TIME > 60 AND COMMAND != 'Sleep'
  ORDER BY TIME DESC LIMIT 10;
" 2>/dev/null || echo "none")

echo "Remaining long queries: ${REMAINING:-none}"
save_action "DONE" "issued KILL for $CANDIDATES MySQL query(ies) running >30 min"
echo "[$(date +%T)] MySQL kill blocking complete."
