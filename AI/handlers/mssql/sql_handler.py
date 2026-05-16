"""
Run a read-only SQL query against a remote MSSQL instance via Ansible.

The playbook uses dbatools' Invoke-DbaQuery on the target Windows host,
returning JSON which we parse and bound to settings.SQL_MAX_ROWS rows.
"""

import json

import settings
from handlers import ansible_runner
from handlers.sql_guard import sanitize, UnsafeSqlError


def run_query(server, database, raw_query):
    safe_query = sanitize(raw_query)  # raises UnsafeSqlError on bad input

    extra_vars = {
        "target_host": server,
        "sql_instance": server,
        "sql_database": database or "master",
        "sql_query": safe_query,
        "max_rows": settings.SQL_MAX_ROWS,
    }

    out = ansible_runner.run_playbook("mssql/run_sql_query.yml", server, extra_vars=extra_vars)
    task = ansible_runner.extract_task_result(out, "Run read-only SQL query") or {}
    if not task:
        return {
            "query": safe_query, "rows": [], "warning": "No task result returned.",
            "_ansible": {"cmd": (out or {}).get("cmd"), "task": "Run read-only SQL query",
                         "rc": None, "stdout": "", "stderr": ""},
        }

    stdout = task.get("stdout") or ""
    stderr = task.get("stderr") or ""

    rows = []
    try:
        parsed = json.loads(stdout) if stdout.strip().startswith(("[", "{")) else None
        if isinstance(parsed, list):
            rows = parsed
        elif isinstance(parsed, dict):
            rows = [parsed]
    except json.JSONDecodeError:
        rows = []

    return {
        "query": safe_query,
        "server": server,
        "database": database or "master",
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
    """Helper exposed for unit tests / quick CLI checks."""
    try:
        return {"ok": True, "query": sanitize(raw_query)}
    except UnsafeSqlError as exc:
        return {"ok": False, "error": str(exc)}
