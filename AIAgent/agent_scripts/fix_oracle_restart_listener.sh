#!/usr/bin/env bash
# Stops and starts the Oracle TNS listener.
# Runs as: oracle (via sudo -u oracle run_fix.sh)
# Env: ORACLE_HOME
set -euo pipefail

export ORACLE_HOME="${ORACLE_HOME:?ORACLE_HOME is required}"
export PATH="$ORACLE_HOME/bin:$PATH"

echo "[$(date +%T)] Restarting Oracle listener..."
lsnrctl stop  LISTENER 2>/dev/null || true
sleep 3
lsnrctl start LISTENER
lsnrctl status LISTENER | grep -E "^STATUS|Services Summary" || true
echo "[$(date +%T)] Listener restart complete."
