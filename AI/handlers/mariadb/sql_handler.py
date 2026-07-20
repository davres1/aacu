"""
Run a read-only MariaDB / MariaDB SQL query against a target host via Ansible.

The playbook executes the `mysql` client on the remote Linux host, connecting
with credentials from databases.ini. The query is sanitized (SELECT-only, no
DML/DDL/utility verbs) before it ever leaves this process. The client output is
pipe-delimited so we can split it client-side, mirroring the Oracle/Db2 handlers.
"""

import settings
from handlers import ansible_runner
from handlers.sql_guard import sanitize, UnsafeSqlError


# The playbook runs `mysql -N -B` (tab-separated) and converts the column
# separators to '|', emitting the header row first, mirroring the Db2 handler's
# parsing contract.
_OUTPUT_DELIMITER = "|"


def _parse_pipe_rows(stdout):
    """Parse client output that uses '|' between columns, first row as headers.

    Blank lines and client diagnostic lines are filtered out. Returns dicts."""
    if not stdout:
        return []
    lines = [ln.rstrip() for ln in stdout.splitlines() if ln.strip()]
    # Drop client banners / warnings (mysql: [Warning], ERROR nnnn, etc.).
    lines = [
        ln for ln in lines
        if not ln.lstrip().lower().startswith(("mysql:", "warning", "error", "note"))
    ]
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
            "error": "MariaDB requires a schema/database name — none supplied.",
        }

    extra_vars = {
        "target_host":    server,
        "mysql_database": database,
        "sql_query":      safe_query,
        "max_rows":       settings.SQL_MAX_ROWS,
        "delimiter":      _OUTPUT_DELIMITER,
        "databases_ini":  settings.MARIADB_DATABASES_INI,
        "mysql_user":     settings.MARIADB_OS_USER,
    }

    out = ansible_runner.run_playbook("mariadb/run_sql_query.yml", server, extra_vars=extra_vars)
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
