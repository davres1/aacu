"""
Operational actions that go through Ansible to a target server:
  - check_blocking_locks  -> runs files/DetectBlockingLocks.ps1
  - add_datafile_space    -> runs an idempotent ALTER DATABASE ... MODIFY FILE
  - health_check          -> runs CheckmssqlStatus.ps1 + db_inventory.ps1
  - backup_status         -> runs VerifyBackups.ps1
  - integrity_status      -> runs DBCCCheckDB.ps1
  - disk_status           -> runs MonitorDiskSpace.ps1
  - agent_jobs            -> runs MonitorAgentJobs.ps1
  - tempdb_status         -> runs MonitorTempDB.ps1
  - security_audit        -> runs SecurityAudit.ps1
  - patch_level           -> runs PatchLevelCheck.ps1
  - alwayson_status       -> runs MonitorAlwaysOn.ps1
"""

import json

from handlers import ansible_runner


def _parse_json_tail(stdout):
    """The new PS1 scripts emit a final compact JSON line on stdout."""
    if not stdout:
        return None
    text = stdout.strip()
    # Walk back over trailing lines until we find a JSON object.
    for line in reversed(text.splitlines()):
        line = line.strip()
        if line.startswith("{") and line.endswith("}"):
            try:
                return json.loads(line)
            except json.JSONDecodeError:
                continue
    return None


def _ansible_meta(out, task_name, task=None):
    """Build the _ansible disclosure block consumed by the chat UI.

    Caps stdout/stderr so we don't ship 1MB of YAML over /api/chat — the user
    sees the head of stdout (which is where errors live) and the tail (which
    has the final JSON line). 50KB / 10KB are plenty for any reasonable run.
    """
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


def check_blocking_locks(server):
    out = ansible_runner.run_playbook(
        "check_blocking_locks.yml", server,
        extra_vars={"target_host": server},
    )
    task = ansible_runner.extract_task_result(out, "Run DetectBlockingLocks.ps1") or {}
    return {
        "server": server,
        "stdout": task.get("stdout", "")[:8000],
        "stderr": task.get("stderr", "")[:2000],
        "rc": task.get("rc"),
        "_ansible": _ansible_meta(out, "Run DetectBlockingLocks.ps1", task),
    }


def add_datafile_space(server, database, logical_file, add_mb):
    if not database or not logical_file:
        return {"error": "database and logical_file are required."}
    try:
        add_mb = int(add_mb)
    except (TypeError, ValueError):
        return {"error": f"add_mb must be an integer, got {add_mb!r}"}
    if add_mb <= 0 or add_mb > 102400:  # cap at 100 GiB growth per op
        return {"error": "add_mb must be between 1 and 102400."}

    out = ansible_runner.run_playbook(
        "add_datafile_space.yml", server,
        extra_vars={
            "target_host": server,
            "sql_instance": server,
            "sql_database": database,
            "logical_file": logical_file,
            "add_mb": add_mb,
        },
    )
    task = ansible_runner.extract_task_result(out, "Grow datafile") or {}
    return {
        "server": server,
        "database": database,
        "logical_file": logical_file,
        "add_mb": add_mb,
        "stdout": task.get("stdout", "")[:4000],
        "rc": task.get("rc"),
        "_ansible": _ansible_meta(out, "Grow datafile", task),
    }


def health_check(server):
    out = ansible_runner.run_playbook(
        "health_check.yml", server,
        extra_vars={"target_host": server},
    )
    status = ansible_runner.extract_task_result(out, "Run CheckmssqlStatus.ps1") or {}
    inventory = ansible_runner.extract_task_result(out, "Run db_inventory.ps1") or {}

    parsed_inv = None
    inv_stdout = inventory.get("stdout") or ""
    try:
        start = inv_stdout.find("{")
        if start >= 0:
            parsed_inv = json.loads(inv_stdout[start:])
    except json.JSONDecodeError:
        parsed_inv = None

    return {
        "server": server,
        "service_status": {
            "rc": status.get("rc"),
            "stdout_tail": (status.get("stdout") or "")[-2000:],
        },
        "inventory": parsed_inv if parsed_inv else {"raw": inv_stdout[:4000]},
        "_ansible_status":    _ansible_meta(out, "Run CheckmssqlStatus.ps1", status),
        "_ansible_inventory": _ansible_meta(out, "Run db_inventory.ps1", inventory),
    }


# ---------------------------------------------------------------------------
# Thin wrappers: one Ansible playbook per intent, each runs a single PS1 and
# returns the JSON summary line emitted by the script.
# ---------------------------------------------------------------------------

def backup_status(server):
    return _run_script(server, "verify_backups.yml", "Run VerifyBackups.ps1")


def integrity_status(server):
    return _run_script(server, "dbcc_checkdb.yml", "Run DBCCCheckDB.ps1")


def disk_status(server):
    return _run_script(server, "monitor_disk_space.yml", "Run MonitorDiskSpace.ps1")


def agent_jobs(server, lookback_hours=None):
    extra = {}
    if lookback_hours is not None:
        try:
            extra["lookback_hours"] = int(lookback_hours)
        except (TypeError, ValueError):
            pass
    return _run_script(server, "monitor_agent_jobs.yml", "Run MonitorAgentJobs.ps1", extra)


def tempdb_status(server):
    return _run_script(server, "monitor_tempdb.yml", "Run MonitorTempDB.ps1")


def security_audit(server):
    return _run_script(server, "security_audit.yml", "Run SecurityAudit.ps1")


def patch_level(server):
    return _run_script(server, "patch_level.yml", "Run PatchLevelCheck.ps1")


def alwayson_status(server):
    return _run_script(server, "monitor_alwayson.yml", "Run MonitorAlwaysOn.ps1")
