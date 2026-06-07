"""
Operational actions for Oracle hosts. Each handler runs an Ansible playbook
that ships a single shell script (under Oracle/files/*.sh) to the target host
and captures its JSON output:

  - check_blocking_locks  -> DetectBlockingLocks.sh
  - add_datafile_space    -> ALTER DATABASE DATAFILE ... RESIZE
  - health_check          -> CheckOracleStatus.sh + db_inventory.sh
  - backup_status         -> VerifyBackups.sh
  - integrity_status      -> GetCheckDBStatus.sh (cached, fast)
  - disk_status           -> MonitorTablespaces.sh
  - agent_jobs            -> MonitorJobs.sh
  - tempdb_status         -> MonitorTablespaces.sh (TEMP subset)
  - security_audit        -> SecurityAudit.sh
  - patch_level           -> PatchLevelCheck.sh
  - alwayson_status       -> MonitorDataGuard.sh
"""

import json

from handlers import ansible_runner


def _parse_json_tail(stdout):
    """Each Oracle script emits a final compact JSON line on stdout."""
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
        "oracle/check_blocking_locks.yml", server,
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


def add_datafile_space(server, database, datafile, add_mb):
    """Grow an Oracle datafile by add_mb. Uses ALTER DATABASE ... RESIZE."""
    if not database or not datafile:
        return {"error": "database (TNS alias) and datafile path are required."}
    try:
        add_mb = int(add_mb)
    except (TypeError, ValueError):
        return {"error": f"add_mb must be an integer, got {add_mb!r}"}
    if add_mb <= 0 or add_mb > 102400:
        return {"error": "add_mb must be between 1 and 102400."}

    out = ansible_runner.run_playbook(
        "oracle/add_datafile_space.yml", server,
        extra_vars={
            "target_host":   server,
            "tns_alias":     database,
            "datafile_path": datafile,
            "add_mb":        add_mb,
        },
    )
    task = ansible_runner.extract_task_result(out, "Grow datafile") or {}
    return {
        "server": server,
        "database": database,
        "datafile": datafile,
        "add_mb": add_mb,
        "stdout": task.get("stdout", "")[:4000],
        "rc": task.get("rc"),
        "_ansible": _ansible_meta(out, "Grow datafile", task),
    }


def health_check(server):
    out = ansible_runner.run_playbook(
        "oracle/health_check.yml", server,
        extra_vars={"target_host": server},
    )
    status    = ansible_runner.extract_task_result(out, "Run CheckOracleStatus.sh") or {}
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
        "_ansible_status":    _ansible_meta(out, "Run CheckOracleStatus.sh", status),
        "_ansible_inventory": _ansible_meta(out, "Run db_inventory.sh", inventory),
    }


# ---------------------------------------------------------------------------
# Thin wrappers — one shell script per intent
# ---------------------------------------------------------------------------

def backup_status(server):
    return _run_script(server, "oracle/verify_backups.yml",     "Run VerifyBackups.sh")

def integrity_status(server):
    return _run_script(server, "oracle/dbcc_checkdb.yml",       "Run GetCheckDBStatus.sh")

def disk_status(server):
    return _run_script(server, "oracle/monitor_disk_space.yml", "Run MonitorTablespaces.sh")

def agent_jobs(server, lookback_hours=None):
    extra = {}
    if lookback_hours is not None:
        try: extra["lookback_hours"] = int(lookback_hours)
        except (TypeError, ValueError): pass
    return _run_script(server, "oracle/monitor_agent_jobs.yml", "Run MonitorJobs.sh", extra)

def tempdb_status(server):
    # MonitorTablespaces.sh also covers TEMP — we filter on the client side.
    return _run_script(server, "oracle/monitor_tempdb.yml", "Run MonitorTablespaces.sh")

def security_audit(server):
    return _run_script(server, "oracle/security_audit.yml",     "Run SecurityAudit.sh")

def patch_level(server):
    return _run_script(server, "oracle/patch_level.yml",        "Run PatchLevelCheck.sh")

def alwayson_status(server):
    """Oracle Data Guard — same intent name as the SQL Server side for chat parity."""
    return _run_script(server, "oracle/monitor_alwayson.yml",   "Run MonitorDataGuard.sh")

def performance_review(server):
    return _run_script(server, "oracle/performance_review.yml", "Run PerformanceReview.sh")


# ---------------------------------------------------------------------------
# Restore points + Fast Recovery Area
# ---------------------------------------------------------------------------

def create_restore_point(server, database, name, guarantee=False):
    """CREATE [GUARANTEE FLASHBACK DATABASE] RESTORE POINT <name>.

    Returns the SCN of the created restore point in the result's stdout.
    """
    if not database or not name:
        return {"error": "database (TNS alias) and name are required."}
    # Restore point names follow Oracle identifier rules (1-128, alphanumeric+_).
    safe = "".join(c for c in name if c.isalnum() or c == "_")
    if safe != name or not safe:
        return {"error": "name must be alphanumeric or underscore only (Oracle identifier rules)."}

    out = ansible_runner.run_playbook(
        "oracle/create_restore_point.yml", server,
        extra_vars={
            "target_host": server,
            "tns_alias":   database,
            "rp_name":     safe,
            "guarantee":   bool(guarantee),
        },
    )
    task = ansible_runner.extract_task_result(out, "Create restore point") or {}
    return {
        "server": server,
        "database": database,
        "name": safe,
        "guarantee": bool(guarantee),
        "stdout": task.get("stdout", "")[:4000],
        "rc": task.get("rc"),
        "_ansible": _ansible_meta(out, "Create restore point", task),
    }


def list_restore_points(server, database):
    """Return v$restore_point rows for the target DB as a table."""
    if not database:
        return {"error": "database (TNS alias) is required."}
    out = ansible_runner.run_playbook(
        "oracle/list_restore_points.yml", server,
        extra_vars={
            "target_host": server,
            "tns_alias":   database,
        },
    )
    task = ansible_runner.extract_task_result(out, "List restore points") or {}
    stdout = task.get("stdout") or ""

    # sqlplus output: header line + rows separated by '|'.
    rows = []
    lines = [ln.rstrip() for ln in stdout.splitlines() if ln.strip()]
    lines = [ln for ln in lines if not ln.startswith(("ORA-", "SP2-", "Connected", "Disconnected"))]
    if len(lines) >= 2:
        header = [c.strip() for c in lines[0].split("|")]
        for ln in lines[1:]:
            parts = [c.strip() for c in ln.split("|")]
            if len(parts) == len(header):
                rows.append(dict(zip(header, parts)))

    return {
        "server": server,
        "database": database,
        "row_count": len(rows),
        "rows": rows,
        "_ansible": _ansible_meta(out, "List restore points", task),
    }


def grow_recovery_dest(server, database, add_gb):
    """Grow db_recovery_file_dest_size by add_gb GB on the target DB."""
    if not database:
        return {"error": "database (TNS alias) is required."}
    try:
        add_gb = int(add_gb)
    except (TypeError, ValueError):
        return {"error": f"add_gb must be an integer, got {add_gb!r}"}
    if add_gb <= 0 or add_gb > 4096:           # cap at 4 TiB delta per call
        return {"error": "add_gb must be between 1 and 4096."}

    out = ansible_runner.run_playbook(
        "oracle/grow_recovery_dest.yml", server,
        extra_vars={
            "target_host": server,
            "tns_alias":   database,
            "add_gb":      add_gb,
        },
    )
    task = ansible_runner.extract_task_result(out, "Grow db_recovery_file_dest_size") or {}
    return {
        "server": server,
        "database": database,
        "add_gb": add_gb,
        "stdout": task.get("stdout", "")[:4000],
        "rc": task.get("rc"),
        "_ansible": _ansible_meta(out, "Grow db_recovery_file_dest_size", task),
    }
