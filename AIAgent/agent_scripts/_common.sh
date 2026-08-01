# =============================================================================
# _common.sh — shared helpers for the DB AI Agent fix_*/start_* scripts.
#
# Sourced by every fix/start script; NEVER executed directly. run_fix.sh only
# dispatches names matching ^(fix|start|check)_[a-z0-9_]+\.sh$, so a file whose
# name begins with "_" can never be run as an action — it is a library only.
#
# Provides two things every action script needs:
#   save_action <STATUS> <message...>  — append a persistent audit record of what
#                                        the script did (or skipped), so there is
#                                        a durable trail independent of the agent.
#   require_cmd <command> [label]      — precondition CHECK: if a required tool is
#                                        missing, record a SKIP and exit cleanly
#                                        instead of failing noisily every cycle.
#   have_cmd <command>                 — quiet boolean test for a command.
#
# STATUS convention: DONE (action taken) | SKIP (nothing to do / precondition
# not met) | FAIL (attempted but errored) | INFO (context only).
# =============================================================================

# Where the audit trail is written. Overridable via ACTION_LOG_DIR.
ACTION_LOG_DIR="${ACTION_LOG_DIR:-${HOME:-/tmp}/.db_agent/action_log}"
if ! mkdir -p "$ACTION_LOG_DIR" 2>/dev/null; then
    ACTION_LOG_DIR="/tmp"
fi
ACTION_LOG="${ACTION_LOG_DIR}/actions.log"

# save_action <STATUS> <message...>
# Appends one structured line to the audit log AND echoes it to stdout so it is
# also captured in the agent's own log (the agent records each fix's output).
save_action() {
    local status="${1:-INFO}"; shift 2>/dev/null || true
    local message="$*"
    local ts host user script
    ts="$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo '?')"
    host="$(hostname 2>/dev/null || echo '?')"
    user="$(id -un 2>/dev/null || echo '?')"
    script="$(basename "${0:-unknown}" 2>/dev/null || echo 'unknown')"
    printf '%s | host=%s | user=%s | script=%s | db=%s | %-4s | %s\n' \
        "$ts" "$host" "$user" "$script" "${DB_NAME:-?}" "$status" "$message" \
        >> "$ACTION_LOG" 2>/dev/null || true
    echo "[action:${status}] ${message}"
}

# have_cmd <command> — true if the command is on PATH.
have_cmd() { command -v "$1" >/dev/null 2>&1; }

# require_cmd <command> [friendly-label]
# Precondition check. When the tool is absent the action genuinely cannot run,
# so we record a SKIP and exit 0 (a benign no-op, not an error to alarm on).
require_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        save_action "SKIP" "required command not available: ${2:-$1}"
        exit 0
    fi
}
