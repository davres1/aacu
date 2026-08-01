#!/usr/bin/env bash
# Stops and starts the Oracle TNS listener.
# Runs as: oracle (via sudo -u oracle run_fix.sh)
# Env: ORACLE_HOME
set -euo pipefail
source "$(dirname "$0")/_common.sh"

export ORACLE_HOME="${ORACLE_HOME:?ORACLE_HOME is required}"
export PATH="$ORACLE_HOME/bin:$PATH"

# --- Check: lsnrctl is available before touching the listener ---
require_cmd lsnrctl

echo "[$(date +%T)] Restarting Oracle listener..."
lsnrctl stop  LISTENER 2>/dev/null || true
sleep 3
lsnrctl start LISTENER
lsnrctl status LISTENER | grep -E "^STATUS|Services Summary" || true

# --- Verify + save: confirm the listener came back up ---
if lsnrctl status LISTENER >/dev/null 2>&1; then
    save_action "DONE" "Oracle listener restarted and responding"
else
    save_action "FAIL" "Oracle listener restart attempted but status check failed"
fi
echo "[$(date +%T)] Listener restart complete."
