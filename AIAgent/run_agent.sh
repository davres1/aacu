#!/usr/bin/env bash
# Start the DB AI Agent as a background daemon

set -euo pipefail

AGENT_DIR="$(cd "$(dirname "$0")" && pwd)"
PID_FILE="$AGENT_DIR/logs/agent.pid"
VENV="$AGENT_DIR/venv"

# Check Python venv
if [[ ! -f "$VENV/bin/python3" ]]; then
  echo "Creating virtual environment..."
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install -q --upgrade pip
  "$VENV/bin/pip" install -q -r "$AGENT_DIR/requirements.txt"
fi

# Check already running
if [[ -f "$PID_FILE" ]]; then
  PID=$(cat "$PID_FILE")
  if kill -0 "$PID" 2>/dev/null; then
    echo "Agent already running (pid=$PID)"
    exit 0
  fi
  rm -f "$PID_FILE"
fi

# Run config test first
echo "Validating configuration..."
"$VENV/bin/python3" "$AGENT_DIR/agent.py" --test

echo ""
echo "Starting DB AI Agent in background..."
mkdir -p "$AGENT_DIR/logs"
nohup "$VENV/bin/python3" "$AGENT_DIR/agent.py" \
  >> "$AGENT_DIR/logs/stdout.log" 2>&1 &

sleep 1
if [[ -f "$PID_FILE" ]]; then
  echo "Agent started (pid=$(cat "$PID_FILE"))"
  echo "Log: $AGENT_DIR/logs/agent.log"
else
  echo "Agent may have failed to start — check logs/stdout.log"
  exit 1
fi
