#!/usr/bin/env bash
# =============================================================================
# run_fix.sh — Security dispatcher for all DB fix scripts.
# Called by agent.py via: ssh dbagent@host sudo -u <db_user> run_fix.sh <script.sh> [KEY=VALUE ...]
#
# Validates the script name (no path traversal, only fix_*.sh allowed),
# exports KEY=VALUE env vars, then executes the script in the same directory.
# =============================================================================
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SCRIPT_NAME="${1:?Usage: run_fix.sh <fix_script.sh> [KEY=VALUE ...]}"
shift

# Validate: allow fix_/start_/check_ scripts with alphanumeric+underscore names only.
# This prevents path traversal — no slashes, no dots, only known prefixes.
if [[ ! "$SCRIPT_NAME" =~ ^(fix|start|check)_[a-z0-9_]+\.sh$ ]]; then
    echo "SECURITY: Rejected invalid script name: '$SCRIPT_NAME'" >&2
    exit 2
fi

SCRIPT="${SCRIPTS_DIR}/${SCRIPT_NAME}"
if [[ ! -f "$SCRIPT" ]]; then
    echo "Error: Fix script not found: $SCRIPT" >&2
    exit 3
fi

# Export KEY=VALUE pairs from remaining args (only UPPERCASE_WITH_UNDERSCORES keys)
for kv in "$@"; do
    if [[ "$kv" =~ ^[A-Z_][A-Z0-9_]*=.* ]]; then
        export "$kv"
    else
        echo "Warning: Skipping malformed env arg: $kv" >&2
    fi
done

exec bash "$SCRIPT"
