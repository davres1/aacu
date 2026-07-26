#!/usr/bin/env bash
# Starts PostgreSQL via systemctl or pg_ctlcluster.
# Runs as: postgres (via sudo -u postgres run_fix.sh)
set -euo pipefail

echo "[$(date +%T)] Starting PostgreSQL..."

STARTED=false

# Try Debian/Ubuntu pg_ctlcluster first (handles versioned clusters)
if command -v pg_ctlcluster >/dev/null 2>&1; then
    while IFS= read -r line; do
        VER=$(echo "$line" | awk '{print $1}')
        CLUSTER=$(echo "$line" | awk '{print $2}')
        STATUS=$(echo "$line" | awk '{print $4}')
        if [[ "$STATUS" != "online" ]]; then
            echo "Starting cluster ${VER} ${CLUSTER}..."
            pg_ctlcluster "$VER" "$CLUSTER" start && STARTED=true
        fi
    done < <(pg_lsclusters -h 2>/dev/null || true)
fi

# Try systemctl service names (RHEL/CentOS/generic)
if [[ "$STARTED" == "false" ]]; then
    for SVC in postgresql postgresql-16 postgresql-15 postgresql-14 postgresql-13; do
        if systemctl list-unit-files "${SVC}.service" &>/dev/null 2>&1; then
            echo "Starting service: $SVC"
            systemctl start "$SVC" && STARTED=true && break
        fi
    done
fi

if [[ "$STARTED" == "false" ]]; then
    echo "ERROR: Could not find a PostgreSQL service to start." >&2
    systemctl list-unit-files | grep -i postgresql || true
    exit 1
fi

# Wait up to 60s for pg_isready
TIMEOUT=60
while [[ $TIMEOUT -gt 0 ]]; do
    pg_isready -q 2>/dev/null && break
    sleep 3
    TIMEOUT=$((TIMEOUT-3))
done

if pg_isready -q 2>/dev/null; then
    echo "[$(date +%T)] PostgreSQL is UP and accepting connections."
else
    echo "[$(date +%T)] WARNING: PostgreSQL started but not yet ready."
fi
