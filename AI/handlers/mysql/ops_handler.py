"""
Operational actions for MySQL / MariaDB hosts. Each handler runs an Ansible
playbook that ships a single shell script (under MySQL/files/*.sh) to the target
host and captures its JSON output:

  - check_blocking_locks  -> DetectBlockingLocks.sh
  - add_datafile_space    -> ALTER TABLESPACE ... ADD DATAFILE (general tablespace)
  - health_check          -> CheckMySQLStatus.sh + db_inventory.sh
  - backup_status         -> VerifyBackups.sh
  - integrity_status      -> GetCheckDBStatus.sh (cached, fast)
  - disk_status           -> MonitorTablespaces.sh
  - agent_jobs            -> MonitorJobs.sh
  - tempdb_status         -> MonitorTablespaces.sh (temp/undo subset)
  - security_audit        -> SecurityAudit.sh
  - patch_level           -> PatchLevelCheck.sh
  - alwayson_status       -> MonitorReplication.sh (replica role + lag)
"""

import json

from handlers import ansible_runner


def _parse_json_tail(stdout):
    """Each MySQL script emits a final compact JSON line on stdout."""
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
        "mysql/check_blocking_locks.yml", server,
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
    """Add a datafile to a general tablespace / grow InnoDB by add_mb.

    MySQL InnoDB file-per-table datafiles autoextend, so for a general
    tablespace we ADD DATAFILE; the playbook reports autoextend posture when a
    manual extend isn't applicable.
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
        "mysql/add_datafile_space.yml", server,
        extra_vars={
            "target_host":    server,
            "mysql_database": database,
            "tablespace":     tablespace,
            "add_mb":         add_mb,
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
        "mysql/health_check.yml", server,
        extra_vars={"target_host": server},
    )
    status    = ansible_runner.extract_task_result(out, "Run CheckMySQLStatus.sh") or {}
    inventory = ansible_runner.extract_task_result(out, "Run db_inventory.sh")     or {}

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
        "_ansible_status":    _ansible_meta(out, "Run CheckMySQLStatus.sh", status),
        "_ansible_inventory": _ansible_meta(out, "Run db_inventory.sh", inventory),
    }


# ---------------------------------------------------------------------------
# Thin wrappers — one shell script per intent
# ---------------------------------------------------------------------------

def backup_status(server):
    return _run_script(server, "mysql/verify_backups.yml",     "Run VerifyBackups.sh")

def integrity_status(server):
    return _run_script(server, "mysql/dbcc_checkdb.yml",       "Run GetCheckDBStatus.sh")

def disk_status(server):
    return _run_script(server, "mysql/monitor_disk_space.yml", "Run MonitorTablespaces.sh")

def agent_jobs(server, lookback_hours=None):
    extra = {}
    if lookback_hours is not None:
        try: extra["lookback_hours"] = int(lookback_hours)
        except (TypeError, ValueError): pass
    return _run_script(server, "mysql/monitor_agent_jobs.yml", "Run MonitorJobs.sh", extra)

def tempdb_status(server):
    # MonitorTablespaces.sh also covers temp / undo tablespaces — filtered client-side.
    return _run_script(server, "mysql/monitor_tempdb.yml", "Run MonitorTablespaces.sh")

def security_audit(server):
    return _run_script(server, "mysql/security_audit.yml",     "Run SecurityAudit.sh")

def patch_level(server):
    return _run_script(server, "mysql/patch_level.yml",        "Run PatchLevelCheck.sh")

def alwayson_status(server):
    """MySQL replication — same intent name as the SQL Server side for chat parity."""
    return _run_script(server, "mysql/monitor_alwayson.yml",   "Run MonitorReplication.sh")

def performance_review(server):
    return _run_script(server, "mysql/performance_review.yml", "Run PerformanceReview.sh")
