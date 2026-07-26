"""
Operational actions for PostgreSQL hosts. Each handler runs an Ansible playbook
that ships a shell script to the target host and captures its JSON output:

  - check_blocking_locks  -> DetectBlockingLocks.sh  (pg_stat_activity + pg_locks)
  - add_datafile_space    -> ExtendTablespace.sh      (pg_tablespace / data dir grow)
  - health_check          -> CheckPostgreSQLStatus.sh + db_inventory.sh
  - backup_status         -> VerifyBackups.sh         (pg_stat_archiver + pgbackrest)
  - integrity_status      -> GetCheckDBStatus.sh      (pg_catalog checks)
  - disk_status           -> MonitorTablespaces.sh    (pg_database_size, tablespace sizes)
  - agent_jobs            -> MonitorJobs.sh           (pg_cron if available)
  - tempdb_status         -> MonitorTempFiles.sh      (pg_stat_bgwriter, temp file usage)
  - security_audit        -> SecurityAudit.sh         (pg_hba.conf, roles, ssl)
  - patch_level           -> PatchLevelCheck.sh       (server_version_num)
  - alwayson_status       -> MonitorReplication.sh    (pg_stat_replication lag)
  - performance_review    -> PerformanceReview.sh     (pg_stat_statements)
"""

import json

from handlers import ansible_runner


def _parse_json_tail(stdout):
    """Each PostgreSQL script emits a final compact JSON line on stdout."""
    if not stdout:
        return None
    text = stdout.strip()
    for line in reversed(text.splitlines()):
        line = line.strip()
        if line.startswith("{") and line.endswith("}"):
            try:
                return json.loads(line)
            except json.JSONDecodeError:
                continue
    return None


def _ansible_meta(out, task_name, task=None):
    if task is None:
        task = ansible_runner.extract_task_result(out, task_name) or {}
    stdout = task.get("stdout") or ""
    stderr = task.get("stderr") or ""
    return {
        "cmd": (out or {}).get("cmd"),
        "task": task_name,
        "rc": task.get("rc"),
        "stdout": stdout[:50000],
        "stderr": stderr[:10000],
        "stdout_truncated": len(stdout) > 50000,
        "stderr_truncated": len(stderr) > 10000,
    }


def _run_script(server, playbook, task_name, extra_vars=None):
    out = ansible_runner.run_playbook(
        playbook, server,
        extra_vars={"target_host": server, **(extra_vars or {})},
    )
    task = ansible_runner.extract_task_result(out, task_name) or {}
    stdout = task.get("stdout") or ""
    parsed = _parse_json_tail(stdout)
    return {
        "server": server,
        "rc": task.get("rc"),
        "summary": parsed,
        "raw_stdout_tail": None if parsed else stdout[-2000:],
        "stderr": (task.get("stderr") or "")[:1500],
        "_ansible": _ansible_meta(out, task_name, task),
    }


# ---------------------------------------------------------------------------
# Discrete ops with custom playbook signatures
# ---------------------------------------------------------------------------

def check_blocking_locks(server, database=None):
    extra = {}
    if database:
        extra["only_database"] = database
    out = ansible_runner.run_playbook(
        "postgresql/check_blocking_locks.yml", server,
        extra_vars={"target_host": server, **extra},
    )
    task = ansible_runner.extract_task_result(out, "Run DetectBlockingLocks.sh") or {}
    parsed = _parse_json_tail(task.get("stdout") or "")
    return {
        "server": server,
        "database": database,
        "summary": parsed,
        "stdout": task.get("stdout", "")[:8000],
        "stderr": task.get("stderr", "")[:2000],
        "rc": task.get("rc"),
        "_ansible": _ansible_meta(out, "Run DetectBlockingLocks.sh", task),
    }


def add_datafile_space(server, database, tablespace, add_mb):
    """Grow a PostgreSQL tablespace directory or extend a database's allocation.

    PostgreSQL tablespaces are directories; growing means ensuring there is
    sufficient disk space. The playbook reports current tablespace sizes and
    optionally triggers a CHECKPOINT + logs the request for the DBA.
    """
    if not database or not tablespace:
        return {"error": "database and tablespace are required."}
    try:
        add_mb = int(add_mb)
    except (TypeError, ValueError):
        return {"error": f"add_mb must be an integer, got {add_mb!r}"}
    if add_mb <= 0 or add_mb > 102400:
        return {"error": "add_mb must be between 1 and 102400."}

    out = ansible_runner.run_playbook(
        "postgresql/add_datafile_space.yml", server,
        extra_vars={
            "target_host":  server,
            "pg_database":  database,
            "tablespace":   tablespace,
            "add_mb":       add_mb,
        },
    )
    task = ansible_runner.extract_task_result(out, "Extend tablespace") or {}
    return {
        "server": server,
        "database": database,
        "tablespace": tablespace,
        "add_mb": add_mb,
        "stdout": task.get("stdout", "")[:4000],
        "rc": task.get("rc"),
        "_ansible": _ansible_meta(out, "Extend tablespace", task),
    }


def health_check(server):
    out = ansible_runner.run_playbook(
        "postgresql/health_check.yml", server,
        extra_vars={"target_host": server},
    )
    status    = ansible_runner.extract_task_result(out, "Run CheckPostgreSQLStatus.sh") or {}
    inventory = ansible_runner.extract_task_result(out, "Run db_inventory.sh") or {}

    parsed_inv = None
    inv_stdout = inventory.get("stdout") or ""
    try:
        start = inv_stdout.find("{")
        if start >= 0:
            parsed_inv = json.loads(inv_stdout[start:])
    except json.JSONDecodeError:
        parsed_inv = None

    parsed_status = _parse_json_tail(status.get("stdout") or "")

    return {
        "server": server,
        "service_status": parsed_status or {
            "rc": status.get("rc"),
            "stdout_tail": (status.get("stdout") or "")[-2000:],
        },
        "inventory": parsed_inv if parsed_inv else {"raw": inv_stdout[:4000]},
        "_ansible_status":    _ansible_meta(out, "Run CheckPostgreSQLStatus.sh", status),
        "_ansible_inventory": _ansible_meta(out, "Run db_inventory.sh", inventory),
    }


# ---------------------------------------------------------------------------
# Thin wrappers — one shell script per intent
# ---------------------------------------------------------------------------

def backup_status(server):
    return _run_script(server, "postgresql/verify_backups.yml",     "Run VerifyBackups.sh")

def integrity_status(server):
    return _run_script(server, "postgresql/dbcc_checkdb.yml",       "Run GetCheckDBStatus.sh")

def disk_status(server):
    return _run_script(server, "postgresql/monitor_disk_space.yml", "Run MonitorTablespaces.sh")

def agent_jobs(server, lookback_hours=None):
    extra = {}
    if lookback_hours is not None:
        try: extra["lookback_hours"] = int(lookback_hours)
        except (TypeError, ValueError): pass
    return _run_script(server, "postgresql/monitor_agent_jobs.yml", "Run MonitorJobs.sh", extra)

def tempdb_status(server):
    return _run_script(server, "postgresql/monitor_tempdb.yml", "Run MonitorTempFiles.sh")

def security_audit(server):
    return _run_script(server, "postgresql/security_audit.yml",     "Run SecurityAudit.sh")

def patch_level(server):
    return _run_script(server, "postgresql/patch_level.yml",        "Run PatchLevelCheck.sh")

def alwayson_status(server):
    """PostgreSQL streaming replication — same intent name as the SQL Server side."""
    return _run_script(server, "postgresql/monitor_alwayson.yml",   "Run MonitorReplication.sh")

def performance_review(server):
    return _run_script(server, "postgresql/performance_review.yml", "Run PerformanceReview.sh")
