# DB AI Agent

An AI-powered database monitoring and auto-remediation agent that watches Oracle, MySQL, MSSQL, and DB2 servers, diagnoses issues using Claude AI, fixes what it can without restarting anything, and emails the DBA team with findings and actions taken.

---

## How It Works

```
┌─────────────────────────────────────────────────────────────────┐
│  Monitoring Server (runs agent.py)                              │
│                                                                 │
│  Every 5 min:                                                   │
│  ┌──────────────┐    ┌────────────────┐    ┌────────────────┐  │
│  │  Ansible SSH │───▶│  Claude AI API │───▶│  Auto-Fix +    │  │
│  │  (log fetch) │    │  (analysis)    │    │  Email Alert   │  │
│  └──────────────┘    └────────────────┘    └────────────────┘  │
│         │                                                       │
└─────────┼───────────────────────────────────────────────────────┘
          │ SSH (dbagent key)
    ┌─────┴──────┬──────────────┬──────────────┐
    ▼            ▼              ▼              ▼
 Oracle       MySQL          MSSQL           DB2
 Servers      Servers        Servers         Servers
```

1. Ansible SSHes into each DB server and tails only **new log bytes** since the last check (byte-position tracking — no re-reading of old content)
2. Log entries containing errors/warnings are sent to **Claude AI** for root-cause analysis
3. Claude returns a structured JSON verdict: severity, description, best fix, whether a restart is needed
4. If the fix is in the **allowed_fixes** allowlist and requires no restart, it is applied automatically via Ansible (Linux) or PowerShell (Windows MSSQL)
5. An **HTML email** is sent with a severity banner, issue table, recommendations, and auto-fix markers
6. Duplicate alerts are suppressed for 1 hour (configurable)

---

## Offline Mode (No AI API Key)

The agent does **not require an AI provider to keep working**. When no API key is
configured (the `agentsetting.yaml` value is still the `sk-...REPLACE...`
placeholder), or when an AI call fails, the agent falls back to a built-in
**rule-based analyzer** (`RuleBasedAnalyzer` in `agent.py`).

- It scans each cycle's log entries for known error signatures (e.g. `ORA-00257`,
  MySQL `disk is full`, PostgreSQL `deadlock detected`, MSSQL error `9002`) and
  maps them to the **same `fix_name` keys** the remediator already understands.
- It produces the identical result structure the AI path returns, so **auto-fix
  dispatch and email alerts work unchanged**.
- Unlike the AI path (which is gated by `error_count_before_alert` to avoid API
  cost), the rule engine runs **every cycle**, so the agent keeps checking the
  `agent_scripts/` and taking allowlisted actions with no external dependency.

Toggle it with `ai.rule_based_fallback` (default `true`). Set it to `false` to
require a working AI provider and disable offline analysis/fixes.

`agent.py --test` prints which analyzer is active:

```
API key   : NOT SET — using built-in RULE-BASED analyzer (offline)
Fallback  : rule-based enabled
```

## Action Audit Trail

Every `fix_*`/`start_*` script records **what it did (or skipped)** to a durable
audit log, independent of the agent's own log:

- Linux scripts source `agent_scripts/_common.sh` and call `save_action`.
- Windows scripts dot-source `windows/scripts/_common.ps1` and call `Save-Action`.

Each script first runs a **precondition check** — it verifies the required tool is
present (`require_cmd`) and that there is actually something to do (e.g. blocking
sessions exist, a log is over its size threshold) — and only then acts. A line is
appended for each outcome:

```
2026-08-01 11:47:22 | host=db-01 | user=root | script=fix_mysql_flush_logs.sh | db=MYSQL_PROD | DONE | MySQL logs flushed; logrotate configs processed: 0
```

STATUS is `DONE` (action taken), `SKIP` (nothing to do / precondition not met),
`FAIL` (attempted but errored), or `INFO`. The log lives at
`$HOME/.db_agent/action_log/actions.log` (Linux) or
`%ProgramData%\db_agent\action_log\actions.log` (Windows); override the directory
with the `ACTION_LOG_DIR` environment variable.

---

## Prerequisites

### Monitoring Server (Linux — runs the agent)
| Requirement | Minimum Version |
|---|---|
| Python | 3.9+ |
| Ansible | 2.12+ |
| rsync | any |
| OpenSSH client | any |

### DB Servers (monitored)
- SSH accessible from the monitoring server on port 22
- `dbagent` OS user (created by `setup_db_access.yml`)
- ACL support on log directories (`setfacl`)

### External Services
| Service | Purpose |
|---|---|
| Anthropic API key | AI analysis — get one at console.anthropic.com |
| SMTP server | Email alerts |

---

## Quick Start (Linux Deployment)

```bash
# 1. Clone / copy AIAgent to your Ansible controller
cd /path/to/AIAgent

# 2. Fill in your settings
cp agentsetting.yaml agentsetting.yaml.bak
vi agentsetting.yaml     # set api_key, email, database hosts and log paths

# 3. Fill in your inventory
vi inventory/hosts.yml   # set monitoring_servers and db_servers IPs

# 4. Deploy the agent daemon
ansible-playbook -i inventory/hosts.yml playbooks/deploy_agent.yml

# 5. Configure DB servers (SSH user, log read permissions)
ansible-playbook -i inventory/hosts.yml playbooks/setup_db_access.yml

# 6. Verify everything is working
ansible-playbook -i inventory/hosts.yml playbooks/verify_deployment.yml
```

---

## Quick Start (Windows — MSSQL only)

```powershell
# From an elevated PowerShell terminal on the monitoring machine:

# 1. Edit agentsetting.yaml — set windows: true on MSSQL instances
notepad AIAgent\agentsetting.yaml

# 2. Test configuration
.\AIAgent\windows\run_agent.ps1 -TestOnly

# 3. Run as background job
.\AIAgent\windows\run_agent.ps1

# 4. OR install as a Windows Scheduled Task (runs at boot)
# Must be run as Administrator
.\AIAgent\windows\install_service.ps1

# 5. Stop the agent
.\AIAgent\windows\stop_agent.ps1

# 6. Check scheduled task status
.\AIAgent\windows\install_service.ps1 -Action status
```

---

## File Structure

```
AIAgent/
├── agentsetting.yaml              ← Master configuration (edit this)
├── agent.py                       ← Agent daemon (Ansible + AI + email)
├── requirements.txt               ← Python deps: anthropic, PyYAML
├── run_agent.sh                   ← Linux: start in background
├── stop_agent.sh                  ← Linux: graceful stop
├── agent.service                  ← systemd unit template (reference)
│
├── inventory/
│   └── hosts.yml                  ← Ansible inventory (monitoring + DB servers)
│
├── playbooks/
│   ├── deploy_agent.yml           ← Install agent on monitoring_servers
│   ├── setup_db_access.yml        ← Create dbagent user + permissions on DB servers
│   ├── verify_deployment.yml      ← End-to-end health check
│   ├── gather_logs.yml            ← Called by agent.py each cycle (do not run manually)
│   ├── templates/
│   │   └── agent.service.j2       ← systemd service (used by deploy_agent.yml)
│   └── files/
│       └── collect_logs.py        ← Deployed to DB servers; reads log byte offsets
│
├── playbooks/fixes/               ← Ansible auto-fix playbooks (Linux/Ansible)
│   ├── oracle_clear_archive.yml   ← RMAN delete archivelogs > 2 days
│   ├── oracle_restart_listener.yml
│   ├── oracle_clear_temp.yml      ← Shrink temp tablespace
│   ├── oracle_kill_blocking.yml   ← Kill sessions blocking > 30 min
│   ├── mysql_flush_logs.yml       ← FLUSH LOGS + logrotate
│   ├── mysql_kill_blocking.yml    ← Kill queries running > 30 min
│   ├── mssql_clear_errorlog.yml   ← sp_cycle_errorlog
│   ├── db2_flush_logs.yml         ← Archive + truncate diag log
│   └── generic_rotate_logs.yml    ← Force logrotate for any oversized log
│
├── windows/                       ← Windows MSSQL support
│   ├── run_agent.ps1              ← Start agent (creates venv, validates, runs)
│   ├── stop_agent.ps1             ← Stop agent
│   ├── install_service.ps1        ← Install/uninstall Windows Scheduled Task
│   └── scripts/
│       ├── collect_mssql_logs.ps1 ← Reads ERRORLOG + DMV checks (blocking/log full)
│       ├── fix_cycle_errorlog.ps1 ← sp_cycle_errorlog + sp_cycle_agent_errorlog
│       ├── fix_kill_blocking.ps1  ← Kill spids blocking > 30 min
│       ├── fix_clear_tempdb.ps1   ← Flush proc cache + shrink TempDB files
│       └── fix_shrink_log.ps1     ← Backup log to NUL then shrink
│
└── logs/                          ← Runtime files (git-ignored)
    ├── agent.log                  ← Rotating agent log (10MB × 3)
    ├── agent.pid                  ← PID of running agent
    ├── state.json                 ← Log byte positions + dedup tracking
    └── collected/                 ← JSON output from each Ansible gather run
```

---

## Configuration Reference — `agentsetting.yaml`

### Agent Settings
```yaml
agent:
  poll_interval: 300          # seconds between monitoring cycles
  log_level: INFO             # DEBUG | INFO | WARNING | ERROR
  log_lines_per_check: 100    # max new lines per log file per cycle
```

### AI Settings
```yaml
ai:
  provider: anthropic
  anthropic_api_key: sk-ant-...   # get from console.anthropic.com
  anthropic_model: claude-opus-4-5  # or claude-sonnet-4-5 (faster/cheaper)
  max_tokens: 2000
  rule_based_fallback: true       # keep working offline if no key / AI call fails
```

> If `anthropic_api_key` is left as the placeholder, the agent runs in
> [Offline Mode](#offline-mode-no-ai-api-key) using the built-in rule engine.
> The `anthropic`/`openai` Python packages are optional in that case.

### Email Settings
```yaml
email:
  smtp_host: smtp.company.com
  smtp_port: 587
  smtp_user: dbagent@company.com
  smtp_password: "..."
  use_tls: true
  from: "DB AI Agent <dbagent@company.com>"
  to: [dba-team@company.com, ops@company.com]
  cc: [manager@company.com]
  subject_prefix: "[DB-ALERT]"
  min_severity_to_email: medium   # critical | high | medium | low
```

### Database — Oracle
```yaml
databases:
  oracle:
    enabled: true
    homes:
      - name: ORACLE_PROD1          # unique identifier (used in emails)
        host: ora-server-01         # must match inventory/hosts.yml
        oracle_home: /u01/app/oracle/product/19c/dbhome_1
        sid: PROD1
        logs:
          alert_log:    /u01/.../trace/alert_PROD1.log
          listener_log: /u01/.../listener/alert/log.xml
          cluster_log:  /u01/app/grid/diag/crs/.../alert.log
          asm_log:      /u01/app/grid/diag/asm/...
```

### Database — MySQL
```yaml
  mysql:
    enabled: true
    instances:
      - name: MYSQL_PROD
        host: mysql-server-01
        logs:
          error_log:      /var/log/mysql/error.log
          slow_query_log: /var/log/mysql/slow.log
```

### Database — MSSQL (Linux via Ansible)
```yaml
  mssql:
    instances:
      - name: MSSQL_LINUX
        host: mssql-linux-01
        windows: false
        logs:
          error_log: /var/opt/mssql/log/errorlog
          agent_log: /var/opt/mssql/log/sqlagent.out
```

### Database — MSSQL (Windows via PowerShell)
```yaml
      - name: MSSQL_WIN_PROD
        host: win-sql-01            # hostname/IP; use "." for local
        windows: true               # routes to PowerShell collector
        server_instance: win-sql-01 # sqlcmd -S value
        auth: windows               # windows (integrated) | sql
        sql_user: ""                # only for auth: sql
        sql_password: ""
        logs:
          # Adjust MSSQL version: MSSQL16=2022, MSSQL15=2019, MSSQL14=2017
          error_log: 'C:\Program Files\Microsoft SQL Server\MSSQL16.MSSQLSERVER\MSSQL\Log\ERRORLOG'
          agent_log: 'C:\Program Files\Microsoft SQL Server\MSSQL16.MSSQLSERVER\MSSQL\Log\SQLAGENT.OUT'
```

### Database — DB2
```yaml
  db2:
    instances:
      - name: DB2_PROD
        host: db2-server-01
        instance: db2inst1
        logs:
          diag_log: /home/db2inst1/sqllib/db2dump/DIAG0000/db2diag.log
```

### Auto-Fix Settings
```yaml
auto_fix:
  enabled: true
  dry_run: false              # true = log actions without applying
  allowed_fixes:
    - oracle_clear_archive
    - oracle_restart_listener
    - oracle_clear_temp
    - oracle_kill_blocking
    - mysql_flush_logs
    - mysql_kill_blocking
    - mssql_clear_errorlog    # Linux MSSQL
    - mssql_kill_blocking     # Linux MSSQL
    - mssql_clear_tempdb      # Windows MSSQL
    - mssql_shrink_log        # Windows MSSQL
    - db2_flush_logs
    - generic_rotate_logs
```

---

## Supported Auto-Fixes

All fixes run **without restarting any database service**.

| Fix Key | Database | What It Does |
|---|---|---|
| `oracle_clear_archive` | Oracle | RMAN `DELETE ARCHIVELOG ... BEFORE 'SYSDATE-2'` |
| `oracle_restart_listener` | Oracle | `lsnrctl stop` then `lsnrctl start` |
| `oracle_clear_temp` | Oracle | `ALTER TABLESPACE temp SHRINK SPACE` |
| `oracle_kill_blocking` | Oracle | `ALTER SYSTEM KILL SESSION` for sessions blocking > 30 min |
| `mysql_flush_logs` | MySQL | `FLUSH LOGS` + force `logrotate` |
| `mysql_kill_blocking` | MySQL | `KILL` queries running > 30 min |
| `mssql_clear_errorlog` | MSSQL (Linux) | `EXEC sp_cycle_errorlog` |
| `mssql_kill_blocking` | MSSQL (Linux) | `KILL` sessions blocking > 30 min |
| `mssql_clear_tempdb` | MSSQL (Windows) | `DBCC FREEPROCCACHE` + shrink TempDB files |
| `mssql_shrink_log` | MSSQL (Windows) | Log backup to NUL then `DBCC SHRINKFILE` |
| `db2_flush_logs` | DB2 | Archive + truncate `db2diag.log` to last 100K lines |
| `generic_rotate_logs` | All | Force `logrotate` on any oversized log file |

---

## Deployment Playbooks

### `deploy_agent.yml` — Install agent daemon

```bash
# Full deployment
ansible-playbook -i inventory/hosts.yml playbooks/deploy_agent.yml

# Only update Python packages (no service restart)
ansible-playbook -i inventory/hosts.yml playbooks/deploy_agent.yml --tags venv

# Only restart the service
ansible-playbook -i inventory/hosts.yml playbooks/deploy_agent.yml --tags service

# Dry run (show what would change)
ansible-playbook -i inventory/hosts.yml playbooks/deploy_agent.yml --check
```

**What it does:**
- Installs Python 3, Ansible, rsync on the monitoring server
- Creates `dbagent` OS user and `/opt/AIAgent` directory tree
- Syncs all agent files (excludes `venv/`, `logs/`)
- Creates Python venv and installs `anthropic`, `PyYAML`
- Generates a 4096-bit RSA SSH key at `/opt/AIAgent/.ssh/db_agent_key`
- Installs and starts the `db-ai-agent` systemd service (10% CPU cap, 256MB RAM cap)

### `setup_db_access.yml` — Configure DB servers

```bash
# All DB servers
ansible-playbook -i inventory/hosts.yml playbooks/setup_db_access.yml

# Only Oracle servers
ansible-playbook -i inventory/hosts.yml playbooks/setup_db_access.yml \
  --limit oracle_servers

# Only grant SSH access (skip DB-specific tasks)
ansible-playbook -i inventory/hosts.yml playbooks/setup_db_access.yml --tags common
```

**What it does:**
- Reads the public key generated by `deploy_agent.yml` from the monitoring server
- Creates `dbagent` OS user on each DB server
- Installs the agent's public key in `~dbagent/.ssh/authorized_keys`
- Sets ACL read permissions on log directories
- Creates a MySQL monitoring user with `PROCESS` and `SELECT` grants
- Adds `dbagent` to Oracle `oinstall`, MSSQL `mssql`, and DB2 instance groups
- Installs a targeted `sudoers` rule for the specific commands the agent needs

### `verify_deployment.yml` — Health check

```bash
ansible-playbook -i inventory/hosts.yml playbooks/verify_deployment.yml
```

**Checks:**
- `db-ai-agent` service is active
- Recent entries in `agent.log`
- `anthropic` and `yaml` packages importable
- Agent config test (`agent.py --test`)
- SSH connectivity from monitoring server to each DB server
- SMTP host reachability
- Disk space in log directory
- Ansible ping to all DB servers

---

## Inventory — `inventory/hosts.yml`

The inventory has two roles:

```
monitoring_servers   ← agent daemon runs here
db_servers
  ├── oracle_servers
  ├── mysql_servers
  ├── mssql_servers
  └── db2_servers
```

**Key per-host variables:**

| Variable | Where | Purpose |
|---|---|---|
| `ansible_host` | all hosts | IP address |
| `ansible_user` | monitoring_servers | admin user for deployment |
| `ansible_ssh_private_key_file` | monitoring_servers | admin key for deployment |
| `agent_install_dir` | monitoring_servers | install path (default `/opt/AIAgent`) |
| `oracle_sid` | oracle_servers | SID for per-host Oracle operations |
| `oracle_home` | oracle_servers | Oracle Home path |
| `db_os_group` | oracle_servers | OS group for log access (default `oinstall`) |
| `db2_instance` | db2_servers | DB2 instance name (default `db2inst1`) |

---

## Troubleshooting

### Agent not starting
```bash
# Check service status
systemctl status db-ai-agent

# Check logs
journalctl -u db-ai-agent -n 50 --no-pager
tail -50 /opt/AIAgent/logs/agent.log
```

### No emails received
1. Verify SMTP settings in `agentsetting.yaml`
2. Check `min_severity_to_email` is not set too high
3. Check dedup: the same alert is suppressed for 1 hour — look in `logs/state.json`
4. Check `logs/agent.log` for "Email failed" errors

### Ansible playbook errors
```bash
# Test SSH connectivity manually
ssh -i /opt/AIAgent/.ssh/db_agent_key dbagent@<db-server-host> echo ok

# Run with verbose output
ansible-playbook -i inventory/hosts.yml playbooks/gather_logs.yml -vvv
```

### AI analysis not triggering
- `log_lines_per_check` defaults to 100 — if no new lines found, AI is skipped
- `error_count_before_alert` (default 5) must be reached before calling AI
- Check `logs/state.json` to see the saved log byte positions
- With no API key, the AI path is replaced by the rule engine (runs every cycle);
  see [Offline Mode](#offline-mode-no-ai-api-key). If nothing acts offline, the
  logs simply contain no signatures in `RuleBasedAnalyzer.RULES`.

### Actions not being recorded
- Each fix/start script writes to `$HOME/.db_agent/action_log/actions.log`
  (Linux) or `%ProgramData%\db_agent\action_log\actions.log` (Windows)
- A `SKIP` line means a precondition check failed (tool missing, or nothing to do)
- Set `ACTION_LOG_DIR` to relocate the audit log

### Windows PowerShell execution policy
```powershell
# If scripts are blocked:
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned

# Or run with bypass:
powershell -ExecutionPolicy Bypass -File .\windows\run_agent.ps1
```

### Windows MSSQL — can't read locked ERRORLOG
The collector uses `[System.IO.FileShare]::ReadWrite` which allows reading MSSQL's
exclusively-held log file. If it still fails, check that the monitoring user has
file-system read permission on the MSSQL log directory.

---

## Resource Usage

The agent is designed to be lightweight:

| Resource | Typical Usage |
|---|---|
| CPU | < 1% (sleeps between cycles in 1-second ticks) |
| Memory | 30–60 MB Python process |
| Network | SSH + ~5KB Anthropic API call per cycle (only when errors found) |
| Disk | `agent.log` rotates at 10MB × 3 copies; `collected/` JSON files are overwritten each cycle |

systemd limits: `CPUQuota=10%`, `MemoryMax=256M`

---

## Security Notes

- The `dbagent` SSH key has **read-only** access to log directories (ACL `r-x`)
- The `sudoers` rule allows only specific DBA commands, not a shell
- SMTP passwords and the Anthropic API key are in `agentsetting.yaml` — restrict file permissions: `chmod 600 agentsetting.yaml`
- For Windows: store SQL passwords in Windows Credential Manager or use Windows Integrated Auth
- The Anthropic API key is never logged
