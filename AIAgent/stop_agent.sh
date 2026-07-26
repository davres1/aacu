#!/usr/bin/env bash
# Gracefully stop the DB AI Agent

AGENT_DIR="$(cd "$(dirname "$0")" && pwd)"
PID_FILE="$AGENT_DIR/logs/agent.pid"

if [[ ! -f "$PID_FILE" ]]; then
  echo "No PID file found — agent may not be running"
  exit 0
fi

PID=$(cat "$PID_FILE")
if kill -0 "$PID" 2>/dev/null; then
  echo "Stopping agent (pid=$PID)..."
  kill -TERM "$PID"
  for i in {1..10}; do
    sleep 1
    kill -0 "$PID" 2>/dev/null || { echo "Agent stopped"; exit 0; }
  done
  echo "Agent did not stop in 10s, sending KILL..."
  kill -KILL "$PID" 2>/dev/null || true
else
  echo "Process $PID not found — removing stale PID file"
  rm -f "$PID_FILE"
fi
