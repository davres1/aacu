"""
Shells out to ansible-playbook and parses its JSON callback output.

We use the `json` stdout callback so we can pull structured data
(facts, registered task results) back out reliably.
"""

import json
import os
import shlex
import subprocess
import tempfile

import settings


class AnsibleError(RuntimeError):
    pass


def _env_for_json_callback():
    env = os.environ.copy()
    env.setdefault("ANSIBLE_STDOUT_CALLBACK", "json")
    env.setdefault("ANSIBLE_LOAD_CALLBACK_PLUGINS", "1")
    # Speed up host-key handling for ad-hoc demos. Override in production.
    env.setdefault("ANSIBLE_HOST_KEY_CHECKING", "False")
    return env


def run_playbook(playbook_name, host, extra_vars=None, limit=None):
    """
    Run a playbook from AI/playbooks against `host` and return the parsed
    JSON output. Raises AnsibleError on non-zero exit.
    """
    playbook_path = os.path.join(settings.PLAYBOOK_DIR, playbook_name)
    if not os.path.exists(playbook_path):
        raise AnsibleError(f"Playbook not found: {playbook_path}")
    if not os.path.exists(settings.INVENTORY_PATH):
        raise AnsibleError(
            f"Inventory not found at {settings.INVENTORY_PATH}. "
            "Copy AI/inventory/hosts.ini.example to hosts.ini and edit it."
        )

    cmd = [
        settings.ANSIBLE_BIN,
        "-i", settings.INVENTORY_PATH,
        playbook_path,
        "--limit", limit or host,
    ]

    extra_vars = dict(extra_vars or {})
    extra_vars.setdefault("target_host", host)
    extra_vars.setdefault("scripts_dir", settings.SCRIPTS_DIR)

    # Pass extra vars through a temp JSON file so we don't have to worry
    # about quoting nested structures on the command line.
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as fh:
        json.dump(extra_vars, fh)
        vars_path = fh.name

    cmd += ["-e", f"@{vars_path}"]

    try:
        proc = subprocess.run(
            cmd,
            env=_env_for_json_callback(),
            capture_output=True,
            text=True,
            timeout=settings.ANSIBLE_TIMEOUT,
        )
    except subprocess.TimeoutExpired as exc:
        raise AnsibleError(f"ansible-playbook timed out after {settings.ANSIBLE_TIMEOUT}s") from exc
    finally:
        try:
            os.unlink(vars_path)
        except OSError:
            pass

    stdout = proc.stdout or ""
    stderr = proc.stderr or ""

    # The json callback prints one big JSON object on stdout.
    parsed = None
    try:
        # Be tolerant of leading deprecation warnings before the JSON blob.
        start = stdout.find("{")
        if start >= 0:
            parsed = json.loads(stdout[start:])
    except json.JSONDecodeError:
        parsed = None

    if proc.returncode != 0:
        msg = parsed if parsed else (stderr or stdout)
        raise AnsibleError(
            f"ansible-playbook exited {proc.returncode} running {playbook_name}: "
            f"{json.dumps(msg)[:1500] if not isinstance(msg, str) else msg[:1500]}"
        )

    return {"cmd": " ".join(shlex.quote(c) for c in cmd), "result": parsed, "stderr": stderr}


def extract_task_result(playbook_output, task_name):
    """Pull the registered result of a named task from the json-callback output."""
    if not playbook_output or "result" not in playbook_output:
        return None
    result = playbook_output["result"] or {}
    for play in result.get("plays", []):
        for task in play.get("tasks", []):
            if task.get("task", {}).get("name") != task_name:
                continue
            hosts = task.get("hosts", {})
            for _host, data in hosts.items():
                return data
    return None
