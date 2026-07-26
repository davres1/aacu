#!/usr/bin/env bash
# GetCheckDBStatus.sh — fast, read-only retriever of the cached amcheck /
# bt_index_check result written by CheckDB.sh. Adds an age_hours field. Safe to
# call from the chatbot (no heavy work).
#
# Final JSON: the cached object + {"available":bool,"age_hours":N}
source "$(dirname "$0")/lib/pg_common.sh"

STATUS_FILE="$STATUS_DIR/checkdb_status.json"
python3 - "$STATUS_FILE" <<'PY'
import json, sys, os, datetime
path = sys.argv[1]
if not os.path.exists(path):
    print(json.dumps({"available": False, "age_hours": None,
                      "hint": "amcheck / integrity scan has not run yet (see CheckDB.sh / scheduled cron)"}))
    raise SystemExit(0)
try:
    d = json.load(open(path))
except Exception as e:
    print(json.dumps({"available": False, "error": str(e)})); raise SystemExit(0)
age = None
ts = d.get("timestamp")
if ts:
    try:
        dt = datetime.datetime.strptime(ts, "%Y-%m-%dT%H:%M:%S")
        age = round((datetime.datetime.now() - dt).total_seconds() / 3600.0, 1)
    except ValueError:
        pass
d["available"] = True
d["age_hours"] = age
print(json.dumps(d))
PY
