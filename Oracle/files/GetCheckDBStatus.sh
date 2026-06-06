#!/usr/bin/env bash
# GetCheckDBStatus.sh — read-only reader of the cached CheckDB result.
# Used by the chatbot to surface the most recent integrity scan without
# re-running the heavy RMAN VALIDATE.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/oracle_common.sh"

STATUS_FILE="$STATUS_DIR/checkdb_status.json"

if [[ ! -f "$STATUS_FILE" ]]; then
    cat <<JSON
{"available": false, "error": "$STATUS_FILE not yet produced — run CheckDB.sh or wait for the next scheduled run."}
JSON
    exit 2
fi

python3 - "$STATUS_FILE" <<'PY'
import json, sys
from datetime import datetime
try:
    blob = json.load(open(sys.argv[1]))
except Exception as e:
    print(json.dumps({"available": False, "error": f"parse: {e}"})); sys.exit(3)
try:
    age_h = round((datetime.now() - datetime.strptime(blob["timestamp"][:19], "%Y-%m-%d %H:%M:%S")).total_seconds() / 3600, 1)
    blob["age_hours"] = age_h
except Exception:
    pass
blob["available"] = True
print(json.dumps(blob))
PY
