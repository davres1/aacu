#!/usr/bin/env python3
"""
DB AI Agent
Monitors Oracle, MySQL, MSSQL, DB2, and PostgreSQL databases.
Uses direct SSH + shell scripts for runtime log collection and fixes —
no Ansible required on the monitoring server after deployment.
Deployment uses Ansible once (from a control machine); after that the agent
runs autonomously using Python, SSH, and PowerShell.
"""

import hashlib
import json
import logging
import os
import platform
import signal
import smtplib
import subprocess
import sys
import time
from datetime import datetime
from email.mime.multipart import MIMEMultipart
from email.mime.text import MIMEText
from logging.handlers import RotatingFileHandler
from pathlib import Path

try:
    import anthropic
    import yaml
except ImportError as e:
    sys.exit(f"Missing dependency: {e}\nRun: pip install -r requirements.txt")

try:
    import openai as _openai_mod
except ImportError:
    _openai_mod = None   # optional; only required when ai.provider = openai

BASE_DIR   = Path(__file__).parent
ON_WINDOWS = platform.system() == "Windows"


# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

class Config:
    def __init__(self, path: Path):
        with open(path) as f:
            self._c = yaml.safe_load(f)

    def get(self, *keys, default=None):
        v = self._c
        for k in keys:
            if not isinstance(v, dict):
                return default
            v = v.get(k, default)
            if v is default:
                return default
        return v

    @property
    def poll_interval(self) -> int:
        return self.get("agent", "poll_interval", default=300)

    @property
    def log_lines(self) -> int:
        return self.get("agent", "log_lines_per_check", default=100)

    @property
    def ai_provider(self) -> str:
        return self.get("ai", "provider", default="anthropic").lower()

    @property
    def api_key(self) -> str:
        if self.ai_provider == "openai":
            return self.get("ai", "openai_api_key", default="")
        # Support legacy field name "api_key" alongside new "anthropic_api_key"
        return self.get("ai", "anthropic_api_key",
                        default=self.get("ai", "api_key", default=""))

    @property
    def ai_model(self) -> str:
        if self.ai_provider == "openai":
            return self.get("ai", "openai_model", default="gpt-4o")
        return self.get("ai", "anthropic_model",
                        default=self.get("ai", "model", default="claude-opus-4-5"))

    @property
    def email_cfg(self) -> dict:
        return self._c.get("email", {})

    @property
    def auto_fix_enabled(self) -> bool:
        return self.get("auto_fix", "enabled", default=False)

    @property
    def dry_run(self) -> bool:
        return self.get("auto_fix", "dry_run", default=False)

    @property
    def allowed_fixes(self) -> list:
        return self.get("auto_fix", "allowed_fixes", default=[])

    @property
    def thresholds(self) -> dict:
        return self._c.get("thresholds", {})

    # SSH runtime settings — used by SSHLogCollector and SSHRemediator
    @property
    def ssh_key(self) -> str:
        key = self.get("ssh", "key_file", default=".ssh/db_agent_key")
        return str(BASE_DIR / key) if not os.path.isabs(key) else key

    @property
    def ssh_user(self) -> str:
        return self.get("ssh", "user", default="dbagent")

    @property
    def ssh_timeout(self) -> int:
        return self.get("ssh", "connect_timeout", default=10)

    @property
    def remote_scripts_dir(self) -> str:
        return self.get("ssh", "remote_scripts_dir", default="/home/dbagent/.db_agent")

    @property
    def cmd_timeout(self) -> int:
        return self.get("ssh", "command_timeout", default=120)

    def all_db_configs(self) -> list[dict]:
        result = []
        for db_type, db_cfg in self._c.get("databases", {}).items():
            if not db_cfg.get("enabled", False):
                continue
            items = db_cfg.get("instances") or db_cfg.get("homes") or []
            for inst in items:
                result.append({"db_type": db_type, **inst})
        return result


# ---------------------------------------------------------------------------
# State — byte positions and alert deduplication
# ---------------------------------------------------------------------------

class StateManager:
    def __init__(self, path: Path):
        self._path = path
        self._s    = self._load()

    def _load(self) -> dict:
        if self._path.exists():
            with open(self._path) as f:
                return json.load(f)
        return {"positions": {}, "sent": [], "last_run": None}

    def save(self):
        self._path.parent.mkdir(parents=True, exist_ok=True)
        with open(self._path, "w") as f:
            json.dump(self._s, f, indent=2, default=str)

    def get_pos(self, key: str) -> int:
        return self._s["positions"].get(key, 0)

    def set_pos(self, key: str, pos: int):
        self._s["positions"][key] = pos

    def seen(self, h: str, window: int = 3600) -> bool:
        cutoff = time.time() - window
        self._s["sent"] = [(x, t) for x, t in self._s.get("sent", []) if t > cutoff]
        return any(x == h for x, _ in self._s["sent"])

    def mark_seen(self, h: str):
        self._s.setdefault("sent", []).append((h, time.time()))

    def touch(self):
        self._s["last_run"] = datetime.now().isoformat()


# ---------------------------------------------------------------------------
# SSH Log Collector — pure SSH subprocess, no Ansible at runtime
# ---------------------------------------------------------------------------

class SSHLogCollector:
    """
    Collects DB logs via SSH by running collect_logs.py on each DB server.
    For Windows MSSQL instances (windows: true) delegates to WindowsMSSQLCollector.
    For localhost targets, runs the script directly without SSH.
    """

    COLLECT_SCRIPT = "collect_logs.py"

    def __init__(self, config: Config, state: StateManager, log: logging.Logger):
        self.cfg     = config
        self.state   = state
        self.log     = log
        self.out_dir = BASE_DIR / "logs" / "collected"
        self.out_dir.mkdir(parents=True, exist_ok=True)
        self._win: "WindowsMSSQLCollector | None" = None

    def set_windows_collector(self, wc: "WindowsMSSQLCollector"):
        self._win = wc

    def collect_all(self) -> list[dict]:
        entries = []
        for db in self.cfg.all_db_configs():
            try:
                if db.get("db_type") == "mssql" and db.get("windows", False):
                    if self._win:
                        entries.extend(self._win.collect(db))
                else:
                    entries.extend(self._collect(db))
            except Exception as e:
                self.log.error("Collect error %s: %s", db.get("name"), e)
        return entries

    def _collect(self, db: dict) -> list[dict]:
        out_file = self.out_dir / f"{db['name']}_logs.json"

        positions = {
            k: self.state.get_pos(f"{db['name']}:{k}")
            for k in db.get("logs", {}).keys()
        }

        params_json = json.dumps({
            "db_name":   db["name"],
            "db_type":   db["db_type"],
            "log_files": db.get("logs", {}),
            "positions": positions,
            "max_lines": self.cfg.log_lines,
        })

        remote_script = f"{self.cfg.remote_scripts_dir}/{self.COLLECT_SCRIPT}"
        cmd_str = f"python3 {remote_script}"

        try:
            r = self._run(db["host"], cmd_str, stdin_data=params_json, timeout=60)
            if r.returncode != 0:
                self.log.warning("Collect failed %s: %s", db["name"], r.stderr[:200])
                return []

            data = json.loads(r.stdout)

            for key, pos in data.get("positions", {}).items():
                self.state.set_pos(f"{db['name']}:{key}", pos)

            return data.get("log_entries", [])

        except subprocess.TimeoutExpired:
            self.log.error("Collect timed out: %s", db["name"])
        except json.JSONDecodeError as e:
            self.log.error("Collect bad JSON %s: %s", db["name"], e)
        except Exception as e:
            self.log.error("Collect error %s: %s", db["name"], e)

        return []

    def _run(self, host: str, cmd: str, stdin_data: str = None, timeout: int = 60
             ) -> subprocess.CompletedProcess:
        if self._is_local(host):
            full_cmd = ["bash", "-c", cmd]
        else:
            full_cmd = self._ssh_base(host) + [cmd]
        return subprocess.run(
            full_cmd, input=stdin_data, capture_output=True,
            text=True, timeout=timeout
        )

    def _is_local(self, host: str) -> bool:
        return host.lower() in ("localhost", ".", "127.0.0.1", platform.node().lower())

    def _ssh_base(self, host: str) -> list[str]:
        return [
            "ssh",
            "-i", self.cfg.ssh_key,
            "-o", "StrictHostKeyChecking=no",
            "-o", f"ConnectTimeout={self.cfg.ssh_timeout}",
            "-o", "BatchMode=yes",
            "-o", "ServerAliveInterval=15",
            f"{self.cfg.ssh_user}@{host}",
        ]


# ---------------------------------------------------------------------------
# Windows MSSQL Collector — PowerShell scripts for Windows targets
# ---------------------------------------------------------------------------

class WindowsMSSQLCollector:
    """Collects MSSQL logs via PowerShell on Windows hosts (local or WinRM)."""

    PS_SCRIPTS = BASE_DIR / "windows" / "scripts"

    def __init__(self, config: Config, state: StateManager, log: logging.Logger):
        self.cfg     = config
        self.state   = state
        self.log     = log
        self.out_dir = BASE_DIR / "logs" / "collected"
        self.out_dir.mkdir(parents=True, exist_ok=True)

    def collect(self, db: dict) -> list[dict]:
        out_file = self.out_dir / f"{db['name']}_logs.json"

        positions = {
            k: self.state.get_pos(f"{db['name']}:{k}")
            for k in db.get("logs", {}).keys()
        }

        params = {
            "db_name":         db["name"],
            "db_type":         "mssql",
            "log_files":       db.get("logs", {}),
            "positions":       positions,
            "max_lines":       self.cfg.log_lines,
            "server_instance": db.get("server_instance", db.get("host", ".")),
            "auth":            db.get("auth", "windows"),
            "sql_user":        db.get("sql_user", ""),
            "sql_password":    db.get("sql_password", ""),
            "output_file":     str(out_file),
        }

        script = self.PS_SCRIPTS / "collect_mssql_logs.ps1"
        if not script.exists():
            self.log.error("Windows script not found: %s", script)
            return []

        params_json = json.dumps(params)
        host        = db.get("host", "localhost")
        is_local    = host.lower() in ("localhost", ".", "127.0.0.1", platform.node().lower())

        if is_local:
            cmd = ["powershell", "-ExecutionPolicy", "Bypass",
                   "-File", str(script), "-ParamsJson", params_json]
        else:
            safe = params_json.replace("'", "''")
            cmd = ["powershell", "-ExecutionPolicy", "Bypass", "-Command",
                   f"Invoke-Command -ComputerName '{host}' "
                   f"-FilePath '{script}' -ArgumentList '{safe}'"]

        try:
            r = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
            if r.returncode != 0:
                self.log.warning("PS collect failed %s: %s", db["name"], r.stderr[:200])
                return []
        except (subprocess.TimeoutExpired, FileNotFoundError) as e:
            self.log.error("PS collect error %s: %s", db["name"], e)
            return []

        if not out_file.exists():
            return []

        with open(out_file, encoding="utf-8") as f:
            data = json.load(f)

        for key, pos in data.get("positions", {}).items():
            self.state.set_pos(f"{db['name']}:{key}", pos)

        return data.get("log_entries", [])


# ---------------------------------------------------------------------------
# SSH Remediator — runs fix shell scripts via SSH, no Ansible
# ---------------------------------------------------------------------------

class SSHRemediator:
    """
    Applies fixes by SSHing to the DB server and running a shell script via
    the run_fix.sh dispatcher (validates script name before executing).
    """

    # fix_name → (shell_script_filename, os_user_to_sudo_to)
    FIX_MAP: dict[str, tuple[str, str]] = {
        "oracle_clear_archive":    ("fix_oracle_clear_archive.sh",    "oracle"),
        "oracle_restart_listener": ("fix_oracle_restart_listener.sh", "oracle"),
        "oracle_clear_temp":       ("fix_oracle_clear_temp.sh",       "oracle"),
        "oracle_kill_blocking":    ("fix_oracle_kill_blocking.sh",    "oracle"),
        "mysql_flush_logs":        ("fix_mysql_flush_logs.sh",        "root"),
        "mysql_kill_blocking":     ("fix_mysql_kill_blocking.sh",     "root"),
        "mssql_clear_errorlog":    ("fix_mssql_clear_errorlog.sh",    "root"),
        "db2_flush_logs":          ("fix_db2_flush_logs.sh",          "db2inst1"),
        "pg_flush_logs":           ("fix_pg_flush_logs.sh",           "postgres"),
        "pg_kill_blocking":        ("fix_pg_kill_blocking.sh",        "postgres"),
        "pg_vacuum_analyze":       ("fix_pg_vacuum_analyze.sh",       "postgres"),
        "generic_rotate_logs":     ("fix_generic_rotate_logs.sh",     "root"),
    }

    def __init__(self, config: Config, log: logging.Logger):
        self.cfg = config
        self.log = log

    def apply(self, issue: dict, db: dict) -> bool:
        fix = issue.get("fix_name")
        if not fix:
            return False
        if not self.cfg.auto_fix_enabled:
            self.log.info("Auto-fix disabled, skipping: %s", fix)
            return False
        if fix not in self.cfg.allowed_fixes:
            self.log.info("Fix not in allowlist: %s", fix)
            return False
        if issue.get("requires_restart", True):
            self.log.info("Fix requires restart, skipping: %s", fix)
            return False

        entry = self.FIX_MAP.get(fix)
        if not entry:
            self.log.warning("No script mapped for fix: %s", fix)
            return False

        script_name, run_as = entry
        remote_dir  = self.cfg.remote_scripts_dir
        dispatcher  = f"{remote_dir}/run_fix.sh"

        # Build env var args passed to the dispatcher
        env_args = self._env_args(db)

        # sudo -u <db_user> run_fix.sh <script_name> KEY=VALUE ...
        cmd_str = f"sudo -u {run_as} {dispatcher} {script_name} {' '.join(env_args)}"

        if self.cfg.dry_run:
            self.log.info("[DRY-RUN] Would run: %s@%s: %s", self.cfg.ssh_user, db.get("host"), cmd_str)
            return True

        self.log.info("Applying fix %s on %s as %s", fix, db.get("host"), run_as)
        try:
            r = self._run(db["host"], cmd_str, timeout=self.cfg.cmd_timeout)
            if r.returncode == 0:
                self.log.info("Fix %s OK:\n%s", fix, r.stdout[:400])
                return True
            self.log.error("Fix %s failed rc=%d:\n%s", fix, r.returncode, r.stderr[:300])
        except subprocess.TimeoutExpired:
            self.log.error("Fix %s timed out on %s", fix, db.get("host"))
        except Exception as e:
            self.log.error("Fix %s error: %s", fix, e)
        return False

    def _env_args(self, db: dict) -> list[str]:
        args = [f"DB_NAME={db.get('name','')}"]
        if db.get("oracle_home"):
            args += [f"ORACLE_HOME={db['oracle_home']}", f"ORACLE_SID={db.get('sid','')}"]
        if db.get("instance"):
            args.append(f"DB2_INSTANCE={db['instance']}")
        if db.get("pgdata"):
            args.append(f"PGDATA={db['pgdata']}")
        if db.get("port") and db.get("db_type") == "postgresql":
            args.append(f"PGPORT={db['port']}")
        return args

    def _run(self, host: str, cmd: str, timeout: int = 120) -> subprocess.CompletedProcess:
        if self._is_local(host):
            full_cmd = ["bash", "-c", cmd]
        else:
            full_cmd = self._ssh_base(host) + [cmd]
        return subprocess.run(full_cmd, capture_output=True, text=True, timeout=timeout)

    def _is_local(self, host: str) -> bool:
        return host.lower() in ("localhost", ".", "127.0.0.1", platform.node().lower())

    def _ssh_base(self, host: str) -> list[str]:
        return [
            "ssh",
            "-i", self.cfg.ssh_key,
            "-o", "StrictHostKeyChecking=no",
            "-o", f"ConnectTimeout={self.cfg.ssh_timeout}",
            "-o", "BatchMode=yes",
            "-o", "ServerAliveInterval=15",
            f"{self.cfg.ssh_user}@{host}",
        ]


# ---------------------------------------------------------------------------
# Windows MSSQL Remediator — PowerShell fix scripts
# ---------------------------------------------------------------------------

class WindowsRemediator:
    """Applies MSSQL fixes via PowerShell scripts on Windows hosts."""

    PS_SCRIPTS = BASE_DIR / "windows" / "scripts"

    FIX_MAP: dict[str, str] = {
        "mssql_clear_errorlog": "fix_cycle_errorlog.ps1",
        "mssql_kill_blocking":  "fix_kill_blocking.ps1",
        "mssql_clear_tempdb":   "fix_clear_tempdb.ps1",
        "mssql_shrink_log":     "fix_shrink_log.ps1",
    }

    def __init__(self, config: Config, log: logging.Logger):
        self.cfg = config
        self.log = log

    def apply(self, issue: dict, db: dict) -> bool:
        fix = issue.get("fix_name")
        if not fix or fix not in self.cfg.allowed_fixes:
            return False
        if issue.get("requires_restart", True):
            return False

        script_name = self.FIX_MAP.get(fix)
        if not script_name:
            return False

        script = self.PS_SCRIPTS / script_name
        if not script.exists():
            self.log.warning("PS fix script not found: %s", script)
            return False

        server = db.get("server_instance", db.get("host", "."))
        auth   = db.get("auth", "windows")
        args   = ["powershell", "-ExecutionPolicy", "Bypass",
                  "-File", str(script),
                  "-ServerInstance", server, "-Auth", auth,
                  "-DbName", db.get("name", "")]
        if auth == "sql" and db.get("sql_user"):
            args += ["-SqlUser", db["sql_user"], "-SqlPassword", db.get("sql_password", "")]

        if self.cfg.dry_run:
            self.log.info("[DRY-RUN] Would run: %s", " ".join(args))
            return True

        self.log.info("Applying Windows fix %s on %s", fix, server)
        try:
            r = subprocess.run(args, capture_output=True, text=True,
                               timeout=self.cfg.cmd_timeout)
            if r.returncode == 0:
                self.log.info("Fix %s OK:\n%s", fix, r.stdout[:400])
                return True
            self.log.error("Fix %s failed rc=%d:\n%s", fix, r.returncode, r.stderr[:300])
        except Exception as e:
            self.log.error("Fix %s error: %s", fix, e)
        return False


# ---------------------------------------------------------------------------
# Database Health Checker — detects down DBs and attempts 2 start cycles
# ---------------------------------------------------------------------------

_MANUAL_STEPS: dict[str, list[str]] = {
    "oracle": [
        "SSH to the server as oracle",
        "export ORACLE_HOME=... ORACLE_SID=...",
        "sqlplus / as sysdba",
        "STARTUP;  (or STARTUP MOUNT; ALTER DATABASE OPEN;)",
        "Tail alert log: tail -100 $ORACLE_BASE/diag/rdbms/*/*/trace/alert_*.log",
    ],
    "mysql": [
        "SSH to the server",
        "sudo systemctl start mysql",
        "sudo journalctl -u mysql -n 50 --no-pager",
        "sudo tail -50 /var/log/mysql/error.log",
    ],
    "mssql": [
        "Linux: sudo systemctl start mssql-server",
        "Windows: Start-Service MSSQLSERVER",
        "Linux logs: /var/opt/mssql/log/errorlog",
        "Windows: Event Viewer → Application → MSSQL source",
    ],
    "db2": [
        "SSH to the server as db2inst1",
        "source ~/sqllib/db2profile",
        "db2start",
        "db2 list active databases",
        "Diag log: ~/sqllib/db2dump/DIAG0000/db2diag.log",
    ],
    "postgresql": [
        "SSH to the server",
        "Debian/Ubuntu: sudo pg_ctlcluster <version> main start",
        "RHEL/CentOS:   sudo systemctl start postgresql",
        "Check logs: sudo tail -50 /var/log/postgresql/postgresql-*.log",
        "Connect: sudo -u postgres psql -c 'SELECT version();'",
        "Review pg_hba.conf if authentication errors are present",
    ],
}

_DOWN_HTML = """\
<!DOCTYPE html><html><head><meta charset="utf-8">
<style>
body{{font-family:Arial,sans-serif;font-size:14px;color:#333;margin:0;padding:0}}
.banner{{padding:16px 20px;color:#fff;background:{banner}}}
.banner h2{{margin:0;font-size:18px}}.banner p{{margin:4px 0 0;font-size:12px;opacity:.85}}
.box{{padding:12px 16px;margin:12px 0;border-left:4px solid {border};background:{bg};font-size:13px}}
.footer{{color:#999;font-size:11px;border-top:1px solid #e0e0e0;margin-top:24px;padding-top:10px}}
table{{border-collapse:collapse;width:100%;margin:12px 0}}
th{{background:#2c3e50;color:#fff;padding:8px 12px;text-align:left}}
td{{padding:8px 12px;border-bottom:1px solid #ddd}}
ul{{margin:6px 0;padding-left:20px}}li{{margin:3px 0}}
</style></head><body>
<div class="banner"><h2>DB AI Agent — Database {status_label}</h2><p>{ts}</p></div>
<div style="padding:16px 20px">
<div class="box">
<strong>Database:</strong> {db_name} ({db_type})<br>
<strong>Host:</strong> {host}<br>
<strong>Start attempts:</strong> 2<br>
<strong>Outcome:</strong> {outcome}
</div>
<h3>Manual Recovery Steps</h3>
<ul>{steps}</ul>
</div>
<div class="footer" style="padding:0 20px 16px">DB AI Agent &bull; {ts}</div>
</body></html>"""


class DBHealthChecker:
    """
    Before each log-collection cycle:
      1. Runs a process-level liveness check on each DB.
      2. If a DB is down, attempts to start it via the run_fix.sh dispatcher
         (using start_<type>.sh scripts deployed to the DB server).
      3. Makes 2 start attempts, waits 30 s between them.
      4. Sends an HTML email describing the outcome (recovered or still down).
      5. Uses StateManager dedup so a dead DB only triggers one attempt per 10 min.
    """

    START_MAP: dict[str, tuple[str, str]] = {
        "oracle":      ("start_oracle.sh",      "oracle"),
        "mysql":       ("start_mysql.sh",       "root"),
        "mssql":       ("start_mssql.sh",       "root"),
        "db2":         ("start_db2.sh",         "db2inst1"),
        "postgresql":  ("start_postgresql.sh",  "postgres"),
    }
    START_WAIT    = 30   # seconds between start attempts
    START_TIMEOUT = 120  # seconds per start command
    RECHECK_WAIT  = 600  # dedup window: don't re-attempt within 10 minutes

    def __init__(self, config: Config, state: StateManager,
                 log: logging.Logger, mailer: "EmailSender"):
        self.cfg   = config
        self.state = state
        self.log   = log
        self.mail  = mailer

    def check_all(self):
        for db in self.cfg.all_db_configs():
            try:
                self._check_one(db)
            except Exception as e:
                self.log.error("Health check error for %s: %s", db.get("name"), e)

    def _check_one(self, db: dict):
        name    = db["name"]
        db_type = db["db_type"]

        if self._is_alive(db):
            self.log.debug("%s is UP", name)
            return

        self.log.warning("DB %s appears DOWN", name)

        attempt_key = f"start_attempt:{name}"
        if self.state.seen(attempt_key, window=self.RECHECK_WAIT):
            self.log.info("Restart already attempted recently for %s — skipping", name)
            return
        self.state.mark_seen(attempt_key)

        started = False

        if db_type == "mssql" and db.get("windows", False):
            started = self._start_windows_mssql(db)
        else:
            entry = self.START_MAP.get(db_type)
            if not entry:
                self.log.warning("No start script configured for db_type=%s", db_type)
            else:
                script_name, run_as = entry
                for attempt in range(1, 3):
                    self.log.info("Start attempt %d/2 for %s", attempt, name)
                    if self._run_start(db, script_name, run_as):
                        time.sleep(self.START_WAIT)
                        if self._is_alive(db):
                            self.log.info("DB %s RECOVERED after attempt %d", name, attempt)
                            started = True
                            break
                        self.log.warning("DB %s still down after attempt %d", name, attempt)
                    else:
                        self.log.warning("Start command failed for %s (attempt %d)", name, attempt)
                    if attempt < 2:
                        time.sleep(10)

        self.mail.send_db_down(db, started=started)

    def _is_alive(self, db: dict) -> bool:
        db_type = db.get("db_type")
        host    = db.get("host", "localhost")

        if db_type == "oracle":
            sid = db.get("sid", "")
            cmd = f"pgrep -f 'ora_pmon_{sid}' >/dev/null 2>&1"
        elif db_type == "mysql":
            cmd = "pgrep -x mysqld >/dev/null 2>&1 || pgrep -f mysqld_safe >/dev/null 2>&1"
        elif db_type == "mssql" and not db.get("windows", False):
            cmd = "systemctl is-active --quiet mssql-server 2>/dev/null"
        elif db_type == "mssql" and db.get("windows", False):
            return self._check_windows_service(db)
        elif db_type == "db2":
            cmd = "pgrep -x db2sysc >/dev/null 2>&1"
        elif db_type == "postgresql":
            cmd = "pgrep -x postgres >/dev/null 2>&1 || pg_isready -q 2>/dev/null"
        else:
            return True  # unknown type — assume up

        try:
            r = self._run(host, cmd, timeout=15)
            return r.returncode == 0
        except Exception:
            return False

    def _check_windows_service(self, db: dict) -> bool:
        server = db.get("server_instance", db.get("host", "."))
        svc = "MSSQLSERVER"
        if "\\" in server:
            svc = f"MSSQL${server.split(chr(92))[-1].upper()}"
        try:
            r = subprocess.run(
                ["powershell", "-Command",
                 f"(Get-Service -Name '{svc}' -ErrorAction SilentlyContinue).Status -eq 'Running'"],
                capture_output=True, text=True, timeout=15,
            )
            return "True" in r.stdout
        except Exception:
            return False

    def _start_windows_mssql(self, db: dict) -> bool:
        script = BASE_DIR / "windows" / "scripts" / "start_mssql_service.ps1"
        if not script.exists():
            self.log.error("Windows start script not found: %s", script)
            return False
        server = db.get("server_instance", db.get("host", "."))
        for attempt in range(1, 3):
            self.log.info("Windows MSSQL start attempt %d/2 for %s", attempt, db["name"])
            try:
                r = subprocess.run(
                    ["powershell", "-ExecutionPolicy", "Bypass",
                     "-File", str(script), "-ServerInstance", server],
                    capture_output=True, text=True, timeout=self.START_TIMEOUT,
                )
                if r.returncode == 0:
                    time.sleep(self.START_WAIT)
                    if self._check_windows_service(db):
                        return True
            except Exception as e:
                self.log.warning("Windows start attempt %d failed: %s", attempt, e)
            if attempt < 2:
                time.sleep(10)
        return False

    def _run_start(self, db: dict, script_name: str, run_as: str) -> bool:
        remote_dir = self.cfg.remote_scripts_dir
        dispatcher = f"{remote_dir}/run_fix.sh"
        env_args   = [f"DB_NAME={db.get('name','')}"]
        if db.get("oracle_home"):
            env_args += [f"ORACLE_HOME={db['oracle_home']}", f"ORACLE_SID={db.get('sid','')}"]
        if db.get("instance"):
            env_args.append(f"DB2_INSTANCE={db['instance']}")

        cmd_str = f"sudo -u {run_as} {dispatcher} {script_name} {' '.join(env_args)}"
        try:
            r = self._run(db["host"], cmd_str, timeout=self.START_TIMEOUT)
            if r.returncode != 0:
                self.log.warning("Start script stderr:\n%s", r.stderr[:300])
            return r.returncode == 0
        except subprocess.TimeoutExpired:
            self.log.error("Start timed out for %s", db.get("name"))
        except Exception as e:
            self.log.error("Start error for %s: %s", db.get("name"), e)
        return False

    def _run(self, host: str, cmd: str, timeout: int = 30) -> subprocess.CompletedProcess:
        if host.lower() in ("localhost", ".", "127.0.0.1", platform.node().lower()):
            full_cmd: list = ["bash", "-c", cmd]
        else:
            full_cmd = [
                "ssh", "-i", self.cfg.ssh_key,
                "-o", "StrictHostKeyChecking=no",
                "-o", f"ConnectTimeout={self.cfg.ssh_timeout}",
                "-o", "BatchMode=yes",
                f"{self.cfg.ssh_user}@{host}", cmd,
            ]
        return subprocess.run(full_cmd, capture_output=True, text=True, timeout=timeout)


# ---------------------------------------------------------------------------
# AI Analyzer
# ---------------------------------------------------------------------------

SYSTEM_PROMPT = """You are a senior DBA specializing in Oracle, MySQL, MSSQL, DB2, and PostgreSQL.
Analyze the provided database log entries and identify real problems only (ignore routine messages).

Return ONLY valid JSON — no markdown, no explanation — in this exact schema:
{
  "has_issues": true,
  "overall_severity": "critical|high|medium|low",
  "issues": [
    {
      "severity": "critical|high|medium|low",
      "description": "Concise issue description",
      "database": "<db_name from log>",
      "db_type": "oracle|mysql|mssql|db2|postgresql",
      "error_code": "ORA-xxxxx or similar, or null",
      "fix_available": true,
      "fix_name": "<key from allowed list below, or null>",
      "fix_description": "What the fix does in plain language",
      "requires_restart": false,
      "email_subject": "Short subject (<60 chars)",
      "recommendation": "Detailed DBA recommendation (2-3 sentences)"
    }
  ],
  "summary": "One paragraph overview of findings"
}

Allowed fix_name values (use exact keys, only when requires_restart is false):
  oracle_clear_archive    — delete old archive logs via RMAN
  oracle_restart_listener — stop/start Oracle listener (no DB restart)
  oracle_clear_temp       — clear/shrink temp tablespace
  oracle_kill_blocking    — kill sessions blocking > 30 min
  mysql_flush_logs        — FLUSH LOGS and rotate log files
  mysql_kill_blocking     — kill queries running > 30 min
  mssql_clear_errorlog    — cycle MSSQL error log [Linux]
  mssql_kill_blocking     — kill MSSQL blocking sessions [Linux]
  mssql_clear_tempdb      — clear/shrink TempDB [Windows]
  mssql_shrink_log        — shrink transaction log [Windows]
  db2_flush_logs          — archive and truncate DB2 diagnostic log
  pg_flush_logs           — rotate PostgreSQL log file via pg_rotate_logfile()
  pg_kill_blocking        — terminate sessions blocking > 30 min via pg_terminate_backend()
  pg_vacuum_analyze       — run VACUUM ANALYZE to reclaim bloat and update statistics
  generic_rotate_logs     — force logrotate on oversized log files

Rules:
- Only set fix_available=true when fix_name is in the list AND requires_restart=false.
- If no real issues, return has_issues: false with empty issues array.
- Never invent details not present in the logs."""


class AIAnalyzer:
    def __init__(self, config: Config, log: logging.Logger):
        self.cfg  = config
        self.log  = log
        self._ant: anthropic.Anthropic | None = None   # lazy Anthropic client
        self._oai: object | None = None                # lazy OpenAI client

    def analyze(self, entries: list[dict]) -> dict | None:
        if not entries:
            return None

        log_text = "\n".join(
            f"[{e.get('db_name')}][{e.get('db_type')}][{e.get('log_type')}] {e.get('content','').strip()}"
            for e in entries[:60]
        )

        try:
            if self.cfg.ai_provider == "openai":
                return self._call_openai(log_text)
            return self._call_anthropic(log_text)
        except json.JSONDecodeError as e:
            self.log.error("AI returned invalid JSON: %s", e)
        except ValueError as e:
            self.log.error("%s", e)
        except Exception as e:
            self.log.error("AI call error (%s): %s", self.cfg.ai_provider, e)
        return None

    def _call_anthropic(self, log_text: str) -> dict:
        if self._ant is None:
            key = self.cfg.api_key
            if not key or key.startswith("sk-ant-REPLACE"):
                raise ValueError("Anthropic API key not configured in agentsetting.yaml")
            self._ant = anthropic.Anthropic(api_key=key)

        resp = self._ant.messages.create(
            model=self.cfg.ai_model,
            max_tokens=self.cfg.get("ai", "max_tokens", default=2000),
            system=SYSTEM_PROMPT,
            messages=[{"role": "user", "content": f"Analyze these database logs:\n\n{log_text}"}],
        )
        return self._parse_json(resp.content[0].text)

    def _call_openai(self, log_text: str) -> dict:
        if _openai_mod is None:
            raise ValueError("openai package not installed. Run: pip install openai>=1.0.0")
        if self._oai is None:
            key = self.cfg.api_key
            if not key or key.startswith("sk-REPLACE"):
                raise ValueError("OpenAI API key not configured in agentsetting.yaml")
            self._oai = _openai_mod.OpenAI(api_key=key)

        resp = self._oai.chat.completions.create(
            model=self.cfg.ai_model,
            max_tokens=self.cfg.get("ai", "max_tokens", default=2000),
            messages=[
                {"role": "system", "content": SYSTEM_PROMPT},
                {"role": "user",   "content": f"Analyze these database logs:\n\n{log_text}"},
            ],
        )
        return self._parse_json(resp.choices[0].message.content)

    @staticmethod
    def _parse_json(raw: str) -> dict:
        raw = raw.strip()
        if raw.startswith("```"):
            raw = raw.split("```")[1]
            if raw.startswith("json"):
                raw = raw[4:]
            raw = raw.rsplit("```", 1)[0].strip()
        return json.loads(raw)


# ---------------------------------------------------------------------------
# Email Sender
# ---------------------------------------------------------------------------

_ALERT_HTML = """\
<!DOCTYPE html><html><head><meta charset="utf-8">
<style>
body{{font-family:Arial,sans-serif;font-size:14px;color:#333;margin:0;padding:0}}
.banner{{padding:16px 20px;color:#fff;background:{banner}}}
.banner h2{{margin:0;font-size:18px}}.banner p{{margin:4px 0 0;font-size:12px;opacity:.85}}
table{{border-collapse:collapse;width:100%;margin:16px 0}}
th{{background:#2c3e50;color:#fff;padding:9px 12px;text-align:left;font-size:13px}}
td{{padding:9px 12px;border-bottom:1px solid #e0e0e0;font-size:13px}}
tr:nth-child(even){{background:#f7f7f7}}
.sev-critical{{color:#c0392b;font-weight:bold}}.sev-high{{color:#e67e22;font-weight:bold}}
.sev-medium{{color:#d4ac0d;font-weight:bold}}.sev-low{{color:#27ae60}}
.box-fix{{background:#eafaf1;border-left:4px solid #27ae60;padding:10px 14px;margin:10px 0;font-size:13px}}
.box-rec{{background:#eaf4fb;border-left:4px solid #2980b9;padding:10px 14px;margin:10px 0;font-size:13px}}
.footer{{color:#999;font-size:11px;border-top:1px solid #e0e0e0;margin-top:24px;padding-top:10px}}
</style></head><body>
<div class="banner"><h2>DB AI Agent — {sev} Alert</h2><p>{ts}</p></div>
<div style="padding:16px 20px">
<p>{summary}</p>
<table><tr><th>Severity</th><th>Database</th><th>Type</th><th>Issue</th><th>Auto-Fixed</th></tr>
{rows}
</table>{details}
</div>
<div class="footer" style="padding:0 20px 16px">
Generated by DB AI Agent &bull; {ts}<br>This is an automated message — do not reply.
</div></body></html>"""

_SEV_BANNER = {"critical": "#c0392b", "high": "#e67e22", "medium": "#d4ac0d", "low": "#27ae60"}


class EmailSender:
    def __init__(self, config: Config, log: logging.Logger):
        self.cfg = config
        self.ec  = config.email_cfg
        self.log = log

    def send(self, analysis: dict, fixed: list[dict]):
        if not analysis.get("has_issues"):
            return
        issues = analysis.get("issues", [])
        if not issues:
            return

        sev    = analysis.get("overall_severity", "low")
        ts     = datetime.now().strftime("%Y-%m-%d %H:%M:%S UTC")
        banner = _SEV_BANNER.get(sev, "#2c3e50")
        fixed_names = {i.get("fix_name") for i in fixed}

        rows = details = ""
        for issue in issues:
            s      = issue.get("severity", "low")
            was_fx = bool(issue.get("fix_name") and issue.get("fix_name") in fixed_names)
            fx_cel = '<span style="color:#27ae60;font-weight:bold">&#10003; Applied</span>' \
                     if was_fx else '<span style="color:#999">Manual</span>'
            rows += (f'<tr><td class="sev-{s}">{s.upper()}</td>'
                     f'<td>{issue.get("database","")}</td><td>{issue.get("db_type","")}</td>'
                     f'<td>{issue.get("description","")}</td><td>{fx_cel}</td></tr>')
            details += f'<h4 style="margin:16px 0 4px">{issue.get("description","")}</h4>'
            details += f'<div class="box-rec"><strong>Recommendation:</strong> {issue.get("recommendation","")}</div>'
            if was_fx:
                details += f'<div class="box-fix"><strong>Auto-fix applied:</strong> {issue.get("fix_description","")}</div>'

        html = _ALERT_HTML.format(
            banner=banner, sev=sev.upper(), ts=ts,
            summary=analysis.get("summary", ""),
            rows=rows, details=details,
        )
        top = sorted(issues, key=lambda x: ["critical","high","medium","low"].index(
            x.get("severity","low")))[0]
        subject = f"{self.ec.get('subject_prefix','[DB-ALERT]')} {top.get('email_subject','Database issue detected')}"
        self._send_html(subject, html)

    def send_db_down(self, db: dict, started: bool):
        name    = db.get("name", "unknown")
        db_type = db.get("db_type", "unknown")
        host    = db.get("host", "unknown")
        ts      = datetime.now().strftime("%Y-%m-%d %H:%M:%S UTC")

        if started:
            status_label = "RECOVERED"
            banner       = "#27ae60"
            border       = "#27ae60"
            bg           = "#eafaf1"
            outcome      = "Database was successfully restarted after 1–2 attempts."
        else:
            status_label = "DOWN — Manual Action Required"
            banner       = "#c0392b"
            border       = "#c0392b"
            bg           = "#fdedec"
            outcome      = "Both restart attempts failed. Manual intervention is needed."

        steps_html = "".join(
            f"<li>{s}</li>"
            for s in _MANUAL_STEPS.get(db_type, ["Check the server and database logs manually."])
        )

        html = _DOWN_HTML.format(
            banner=banner, border=border, bg=bg,
            status_label=status_label, ts=ts,
            db_name=name, db_type=db_type, host=host,
            outcome=outcome, steps=steps_html,
        )

        pfx     = self.ec.get("subject_prefix", "[DB-ALERT]")
        subject = f"{pfx} DB {status_label}: {name} ({db_type}) on {host}"
        self._send_html(subject, html)

    def _send_html(self, subject: str, html: str):
        to = self.ec.get("to", [])
        cc = self.ec.get("cc", [])
        if not to:
            self.log.warning("No email recipients configured")
            return

        msg = MIMEMultipart("alternative")
        msg["Subject"] = subject
        msg["From"]    = self.ec.get("from", "db-agent@localhost")
        msg["To"]      = ", ".join(to)
        if cc:
            msg["Cc"] = ", ".join(cc)
        msg.attach(MIMEText(html, "html"))

        try:
            srv = smtplib.SMTP(self.ec.get("smtp_host", "localhost"), self.ec.get("smtp_port", 25))
            if self.ec.get("use_tls"):
                srv.starttls()
            if self.ec.get("smtp_user"):
                srv.login(self.ec["smtp_user"], self.ec.get("smtp_password", ""))
            srv.sendmail(msg["From"], to + cc, msg.as_string())
            srv.quit()
            self.log.info("Alert email sent to %s", to)
        except Exception as e:
            self.log.error("Email failed: %s", e)


# ---------------------------------------------------------------------------
# Main Agent
# ---------------------------------------------------------------------------

class DBAgent:
    ERROR_KEYWORDS = frozenset([
        "error", "err-", "ora-", "fatal", "critical", "warning",
        "failed", "failure", "corrupt", "deadlock", "timeout",
        "out of memory", "disk full", "tablespace", "denied",
        "refused", "exception", "crash", "aborted", "oom",
        "alert", "severe", "emergency", "panic", "blocking",
        "db_state", "log_full",
        # PostgreSQL-specific
        "autovacuum", "could not", "pg_", "replication slot",
    ])

    def __init__(self, config_path: Path):
        self.cfg      = Config(config_path)
        log_file      = BASE_DIR / self.cfg.get("agent", "agent_log",  default="logs/agent.log")
        log_level     = self.cfg.get("agent", "log_level", default="INFO")
        self.log      = self._setup_logging(log_level, log_file)
        state_file    = BASE_DIR / self.cfg.get("agent", "state_file", default="logs/state.json")
        self.state    = StateManager(state_file)
        self.win_coll = WindowsMSSQLCollector(self.cfg, self.state, self.log)
        self.win_rem  = WindowsRemediator(self.cfg, self.log)
        self.coll     = SSHLogCollector(self.cfg, self.state, self.log)
        self.coll.set_windows_collector(self.win_coll)
        self.ai       = AIAnalyzer(self.cfg, self.log)
        self.rem      = SSHRemediator(self.cfg, self.log)
        self.mail     = EmailSender(self.cfg, self.log)
        self.health   = DBHealthChecker(self.cfg, self.state, self.log, self.mail)
        self._run     = True

    def _setup_logging(self, level: str, path: Path) -> logging.Logger:
        path.parent.mkdir(parents=True, exist_ok=True)
        lg  = logging.getLogger("db_ai_agent")
        lg.setLevel(getattr(logging, level.upper(), logging.INFO))
        fmt = logging.Formatter("%(asctime)s [%(levelname)s] %(message)s", "%Y-%m-%d %H:%M:%S")
        fh  = RotatingFileHandler(path, maxBytes=10*1024*1024, backupCount=3)
        fh.setFormatter(fmt)
        lg.addHandler(fh)
        ch  = logging.StreamHandler()
        ch.setLevel(logging.WARNING)
        ch.setFormatter(fmt)
        lg.addHandler(ch)
        return lg

    def _sig(self, *_):
        self.log.info("Shutdown signal received")
        self._run = False

    def run(self):
        signal.signal(signal.SIGTERM, self._sig)
        signal.signal(signal.SIGINT,  self._sig)

        pid_path = BASE_DIR / self.cfg.get("agent", "pid_file", default="logs/agent.pid")
        pid_path.parent.mkdir(parents=True, exist_ok=True)
        pid_path.write_text(str(os.getpid()))

        self.log.info("DB AI Agent started (pid=%d, interval=%ds, ssh_user=%s)",
                      os.getpid(), self.cfg.poll_interval, self.cfg.ssh_user)

        try:
            while self._run:
                self._cycle()
                self._sleep(self.cfg.poll_interval)
        finally:
            pid_path.unlink(missing_ok=True)
            self.log.info("DB AI Agent stopped")

    def _sleep(self, secs: int):
        for _ in range(secs):
            if not self._run:
                break
            time.sleep(1)

    def _cycle(self):
        self.log.info("--- Monitoring cycle ---")
        t0 = time.time()

        # Health check first: detect down DBs and attempt recovery (up to 2 starts each)
        self.health.check_all()

        entries  = self.coll.collect_all()
        relevant = [e for e in entries if self._is_relevant(e)]
        self.log.info("Entries: %d total, %d relevant", len(entries), len(relevant))

        threshold = self.cfg.thresholds.get("error_count_before_alert", 5)
        if len(relevant) < threshold:
            self.log.info("Below threshold (%d), skipping AI", threshold)
            self.state.touch(); self.state.save()
            return

        analysis = self.ai.analyze(relevant)
        if not analysis or not analysis.get("has_issues"):
            self.log.info("AI: no actionable issues")
            self.state.touch(); self.state.save()
            return

        issues  = analysis.get("issues", [])
        dedup_w = self.cfg.thresholds.get("dedup_window_seconds", 3600)
        fixed   = []

        for issue in issues:
            db  = self._find_db(issue.get("database"))
            if not db:
                continue
            fh  = hashlib.md5(
                f"{issue.get('database')}:{issue.get('fix_name')}".encode()
            ).hexdigest()
            if issue.get("fix_available") and not self.state.seen(fh, dedup_w):
                rem = self.win_rem \
                      if db.get("db_type") == "mssql" and db.get("windows", False) \
                      else self.rem
                if rem.apply(issue, db):
                    fixed.append(issue)
                self.state.mark_seen(fh)

        min_sev  = self.cfg.email_cfg.get("min_severity_to_email", "medium")
        sev_rank = {"critical": 0, "high": 1, "medium": 2, "low": 3}
        if any(sev_rank.get(i.get("severity","low"),3) <= sev_rank.get(min_sev,2) for i in issues):
            email_h = hashlib.md5(json.dumps(
                sorted([(i.get("database"), i.get("description")) for i in issues])
            ).encode()).hexdigest()
            if not self.state.seen(f"email:{email_h}", dedup_w):
                self.mail.send(analysis, fixed)
                self.state.mark_seen(f"email:{email_h}")

        self.log.info("Cycle %.1fs | issues=%d fixed=%d", time.time()-t0, len(issues), len(fixed))
        self.state.touch(); self.state.save()

    def _is_relevant(self, entry: dict) -> bool:
        return any(kw in entry.get("content", "").lower() for kw in self.ERROR_KEYWORDS)

    def _find_db(self, name: str) -> dict | None:
        return next((d for d in self.cfg.all_db_configs() if d.get("name") == name), None)


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def _test_mode(cfg: Config):
    print("=== DB AI Agent — Configuration Test ===\n")
    dbs = cfg.all_db_configs()
    print(f"Databases configured: {len(dbs)}")
    for d in dbs:
        print(f"  [{d['db_type'].upper()}] {d['name']} @ {d['host']}")
    print(f"\nAI model  : {cfg.ai_model}")
    api_ok = cfg.api_key and not cfg.api_key.startswith("sk-ant-REPLACE")
    print(f"API key   : {'configured' if api_ok else 'NOT SET'}")
    print(f"SSH key   : {cfg.ssh_key}")
    print(f"SSH user  : {cfg.ssh_user}")
    print(f"Remote dir: {cfg.remote_scripts_dir}")
    print(f"Auto-fix  : {'enabled' if cfg.auto_fix_enabled else 'disabled'}")
    print(f"Dry-run   : {cfg.dry_run}")
    to = cfg.email_cfg.get("to", [])
    print(f"Email to  : {', '.join(to) if to else 'NOT SET'}")
    print("\nNo Ansible required at runtime — agent uses SSH + shell scripts.")
    print("Run without --test to start the agent daemon.")


if __name__ == "__main__":
    cfg_path = BASE_DIR / "agentsetting.yaml"
    if not cfg_path.exists():
        sys.exit(f"Config not found: {cfg_path}")

    if "--test" in sys.argv:
        _test_mode(Config(cfg_path))
    else:
        DBAgent(cfg_path).run()
