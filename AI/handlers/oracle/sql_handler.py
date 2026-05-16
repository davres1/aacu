"""
Run a read-only Oracle SQL query against a target host via Ansible.

The playbook executes sqlplus on the remote Linux host using the credentials
from databases.ini. The query is sanitized (SELECT-only, no DML/DDL/PLSQL)
before it ever leaves this process.
"""

import json
import re

import settings
from handlers import ansible_runner
from handlers.sql_guard import sanitize, UnsafeSqlError


# sqlplus output without column headings is awkward to parse — the playbook
# wraps the user's SELECT to emit pipe-separated rows we split client-side.
_OUTPUT_DELIMITER = "|"


def _parse_pipe_rows(stdout):
    """Parse sqlplus output that uses '|' between columns and the first row as headers.

    Empty lines and ORA- errors get filtered out. Returns list of dicts."""
    if not stdout:
        return []
    lines = [ln.rstrip() for ln in stdout.splitlines() if ln.strip()]
    # Skip any lines that look like sqlplus banners or errors
    lines = [ln for ln in lines if not ln.startswith(("ORA-", "SP2-", "Connected to:", "Disconnected", "Elapsed"))]
    if not lines:
        return []
    header = [c.strip() for c in lines[0].split(_OUTPUT_DELIMITER)]
    rows = []
    for ln in lines[1:]:
        parts = [c.strip() for c in ln.split(_OUTPUT_DELIMITER)]
        if len(parts) != len(header):
            continue
        rows.append(dict(zip(header, parts)))
    return rows


def run_query(server, database, raw_query):
    safe_query = sanitize(raw_query)

    if not database:
        return {
            "query": safe_query, "rows": [],
            "error": "Oracle requires a database (TNS alias) — none supplied.",
        }

    extra_vars = {
        "target_host":   server,
        "tns_alias":     database,
        "sql_query":     safe_query,
        "max_rows":      settings.SQL_MAX_ROWS,
        "delimiter":     _OUTPUT_DELIMITER,
        "databases_ini": settings.ORACLE_DATABASES_INI,
        "oracle_user":   settings.ORACLE_OS_USER,
    }

    out = ansible_runner.run_playbook("oracle/run_sql_query.yml", server, extra_vars=extra_vars)
    task = ansible_runner.extract_task_result(out, "Run read-only SQL query") or {}
    if not task:
        return {
            "query": safe_query, "rows": [], "warning": "No task result returned.",
            "_ansible": {"cmd": (out or {}).get("cmd"), "task": "Run read-only SQL query",
                         "rc": None, "stdout": "", "stderr": ""},
        }

    stdout = task.get("stdout") or ""
    stderr = task.get("stderr") or ""

    rows = _parse_pipe_rows(stdout)

    return {
        "query": safe_query,
        "server": server,
        "database": database,
        "row_count": len(rows),
        "rows": rows[: settings.SQL_MAX_ROWS],
        "raw_stdout": stdout[:4000] if not rows else None,
        "_ansible": {
            "cmd": (out or {}).get("cmd"),
            "task": "Run read-only SQL query",
            "rc": task.get("rc"),
            "stdout": stdout[:50000],
            "stderr": stderr[:10000],
            "stdout_truncated": len(stdout) > 50000,
            "stderr_truncated": len(stderr) > 10000,
        },
    }


def safe_query(raw_query):
    """Helper exposed for quick CLI checks / unit tests."""
    try:
        return {"ok": True, "query": sanitize(raw_query)}
    except UnsafeSqlError as exc:
        return {"ok": False, "error": str(exc)}
