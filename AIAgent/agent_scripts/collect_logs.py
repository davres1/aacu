#!/usr/bin/env python3
"""
collect_logs.py — deployed once to DB servers by setup_db_access.yml.
Reads new log bytes since the last saved position and returns JSON.
Accepts params via stdin (JSON). Also collects lightweight system facts.
No third-party dependencies — stdlib only.
"""
import json
import os
import subprocess
import sys


def read_new(path: str, saved_pos: int, max_lines: int) -> tuple:
    if not os.path.exists(path):
        return [], saved_pos

    size = os.path.getsize(path)
    if size == 0:
        return [], 0

    if size < saved_pos:   # log was rotated
        saved_pos = 0

    if size <= saved_pos:
        return [], saved_pos

    with open(path, "rb") as f:
        f.seek(saved_pos)
        data = f.read(size - saved_pos)

    lines = data.decode("utf-8", errors="replace").splitlines()
    lines = [l.strip() for l in lines if l.strip()]
    return lines[-max_lines:], size


def system_facts() -> dict:
    facts = {}

    # Disk usage on /
    try:
        r = subprocess.run(
            ["df", "/", "--output=pcent"], capture_output=True, text=True, timeout=5
        )
        pct = r.stdout.strip().splitlines()
        facts["disk_usage_pct"] = pct[-1].strip().rstrip("%") if len(pct) > 1 else "?"
    except Exception:
        facts["disk_usage_pct"] = "?"

    # Free memory (MB)
    try:
        with open("/proc/meminfo") as f:
            for line in f:
                if line.startswith("MemAvailable:"):
                    facts["memory_free_mb"] = str(int(line.split()[1]) // 1024)
                    break
    except Exception:
        facts["memory_free_mb"] = "?"

    # 1-minute load average
    try:
        with open("/proc/loadavg") as f:
            facts["load_avg_1m"] = f.read().split()[0]
    except Exception:
        facts["load_avg_1m"] = "?"

    # Hostname
    try:
        import socket
        facts["hostname"] = socket.gethostname()
    except Exception:
        facts["hostname"] = "?"

    return facts


def main():
    # Accept JSON from stdin (preferred) or as first positional arg
    if len(sys.argv) >= 2:
        raw = sys.argv[1]
    else:
        raw = sys.stdin.read()

    try:
        params = json.loads(raw)
    except json.JSONDecodeError as e:
        print(json.dumps({"error": f"Bad JSON input: {e}"}))
        sys.exit(1)

    db_name   = params.get("db_name", "unknown")
    db_type   = params.get("db_type", "unknown")
    log_files = params.get("log_files", {})
    positions = params.get("positions", {})
    max_lines = int(params.get("max_lines", 100))

    entries       = []
    new_positions = {}

    for log_key, log_path in log_files.items():
        saved    = int(positions.get(log_key, 0))
        lines, new_pos = read_new(log_path, saved, max_lines)
        new_positions[log_key] = new_pos
        for line in lines:
            entries.append({
                "db_name":  db_name,
                "db_type":  db_type,
                "log_type": log_key,
                "content":  line,
            })

    print(json.dumps({
        "db_name":      db_name,
        "db_type":      db_type,
        "log_entries":  entries,
        "positions":    new_positions,
        "system_facts": system_facts(),
    }))


if __name__ == "__main__":
    main()
