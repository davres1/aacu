#!/usr/bin/env bash
# Kills MySQL queries running for more than 30 minutes.
# Runs as: root (via sudo -u root run_fix.sh)
set -euo pipefail

echo "[$(date +%T)] Killing MySQL queries > 30 min..."

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
echo "[$(date +%T)] MySQL kill blocking complete."
