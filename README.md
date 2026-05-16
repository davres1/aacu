# DBA Automation + Chatbot — SQL Server & Oracle

A unified, Ansible-driven DBA platform that monitors, maintains, and answers
questions about both SQL Server and Oracle estates from one management host.

```
            ┌──────────────────────────────────────────────────┐
            │  Management host (RHEL / Rocky / Alma)           │
            │  ┌─────────────────┐  ┌──────────────────────┐   │
            │  │ AI/app.py       │  │ CheckMK + InfluxDB   │   │
            │  │ Flask chatbot   │  │ + nagflux            │   │
            │  │ (mssql ⇄ oracle)│  │                      │   │
            │  └────────┬────────┘  └──────────────────────┘   │
            │           │ Ansible (forks=50, pipelining)       │
            └───────────┼──────────────────────────────────────┘
                        │
       ┌────────────────┴───────────────────┐
       ▼                                    ▼
┌────────────────────┐                ┌────────────────────┐
│ [sql_servers]      │                │ [oracle_servers]   │
│ Windows · dbatools │                │ Linux · sqlplus    │
│ • PowerShell DBA   │                │ • Shell DBA suite  │
│ • Scheduled tasks  │                │ • cron + RMAN      │
│ • CheckMK local    │                │ • CheckMK local    │
│   plugins          │                │   plugins          │
└────────────────────┘                └────────────────────┘
```

## Repo layout

```
.
├── AI/                          # Unified chatbot (serves both flavors)
│   ├── app.py                   # Flask dispatcher with /api/<flavor>/...
│   ├── settings.py              # Loads setup.yaml + env overrides
│   ├── handlers/
│   │   ├── ansible_runner.py    # shared
│   │   ├── influx_handler.py    # shared (CheckMK metrics)
│   │   ├── sql_guard.py         # shared SELECT-only gate
│   │   ├── mssql/               # T-SQL + dbatools handlers
│   │   └── oracle/              # PL/SQL + sqlplus handlers
│   ├── llm/client.py            # Ollama / OpenAI / Anthropic, flavor-aware prompts
│   ├── playbooks/
│   │   ├── mssql/               # ad-hoc playbooks the chatbot fires
│   │   └── oracle/
│   ├── inventory/
│   │   ├── hosts.ini.example
│   │   ├── databases.ini        # MSSQL section per DB (auto-generated)
│   │   └── mssql_databases.ini.example
│   ├── static/                  # chat UI (tab switcher, table + chart render)
│   ├── templates/index.html
│   └── tools/
│       ├── generate_mssql_databases_ini.py
│       └── generate_oracle_databases_ini.py
│
├── files/                       # SQL Server DBA scripts (PowerShell)
│   ├── *.ps1                    # Backups, CHECKDB, blocking, security audit, ...
│   └── checkmk_local/           # CheckMK custom checks for Windows
│
├── Oracle/                      # Oracle DBA scripts + inventory
│   ├── files/                   # Shell scripts (sqlplus + RMAN)
│   │   ├── lib/oracle_common.sh
│   │   └── checkmk_local/       # CheckMK plugins for Linux
│   ├── inventory/databases.ini  # Oracle section per DB (read by chatbot + playbooks)
│   └── dba_automation.yaml      # Bootstrap + cron for Oracle hosts
│
├── dba_automation.yaml          # Bootstrap + scheduled tasks for SQL Server hosts
├── bootstrap.sh                 # One-shot RHEL bootstrap for the management host
├── setup.yaml                   # Single source of truth for all knobs
├── ansible.cfg                  # forks=50 + pipelining
├── ticktator.py                 # CheckMK → ServiceNow notification bridge
├── sync_influx.sh               # Legacy CheckMK → InfluxDB poller
├── rundeckfacts.py              # SQL Server inventory → Rundeck facts
└── templates/thresholds.json.j2 # Rendered to C:\DBA\thresholds.json on hosts
```

## Setup (management host, fresh RHEL)

```bash
git clone <this repo> /opt/aacu && cd /opt/aacu
vim setup.yaml                                  # passwords, hostnames
sudo ./bootstrap.sh                             # Python, Ansible, CheckMK, nagflux,
                                                # Rundeck, Ollama, the chatbot service,
                                                # ticktator notifier, firewall
```

`bootstrap.sh` is idempotent. Skip phases with `SKIP_NAGFLUX=1`, `SKIP_RUNDECK=1`,
`SKIP_OLLAMA=1`, etc. Hostname is taken from `/etc/hosts`.

## Setup (target hosts)

Populate `/etc/ansible/hosts` with both groups:

```ini
[sql_servers]
sqlprod01.example.com
sqlprod02.example.com

[oracle_servers]
cor089xx1
cor089123
```

Then push the per-flavor DBA stack:

```bash
# SQL Server hosts (Windows / WinRM)
ansible-playbook -i /etc/ansible/hosts dba_automation.yaml --ask-vault-pass

# Oracle hosts (Linux / SSH)
ansible-playbook -i /etc/ansible/hosts Oracle/dba_automation.yaml --ask-vault-pass
```

Both playbooks install dbatools / dbatools-equivalents, deploy DBA scripts,
schedule the active-remediation tasks (cron / Task Scheduler), and drop
the CheckMK local plugins into the agent's `local/` dir.

## Building the database catalogue

The chatbot's dropdown reads from `databases.ini`. Generate / refresh both
catalogues from the Ansible custom facts that `db_inventory.{ps1,sh}` produced:

```bash
python3 AI/tools/generate_mssql_databases_ini.py    # → AI/inventory/databases.ini
python3 AI/tools/generate_oracle_databases_ini.py   # → Oracle/inventory/databases.ini
```

User-edited fields (passwords, retention, email lists) are preserved across
re-runs. Each tool takes `--dry-run` and `--from-tree <dir>`.

## The chatbot

http://&lt;management host&gt;:5000

- **Tab switcher** at the top — `SQL Server` ⇄ `Oracle`. Switching reloads
  the database dropdown and filters the session history to the active flavor.
- **Database picker** lists every section in the active flavor's
  `databases.ini`. Picking a DB resolves the target host automatically
  (each section's `ansible_servername`). Hosts not in `/etc/ansible/hosts`
  show with an amber ⚠ in the dropdown.
- **Intents** (auto-detected by the LLM): `sql_query` (SELECT-only),
  `influx_query` (CheckMK metrics, rendered as charts), `combo_query`,
  `health_check`, `backup_status`, `integrity_status`, `disk_status`,
  `agent_jobs`, `tempdb_status`, `security_audit`, `patch_level`,
  `alwayson_status`, `check_blocking_locks`, `add_datafile_space` —
  plus Oracle-only `create_restore_point`, `list_restore_points`,
  `grow_recovery_size`.
- **Read-only SQL gate** — every query passes through `handlers/sql_guard.py`;
  any non-SELECT / multi-statement / dangerous keyword is rejected before
  it ever leaves the chatbot process.
- **Ansible output disclosure** under every assistant message shows the
  exact `ansible-playbook …` command, return code, stdout, stderr.

## Operational pipeline

1. **CheckMK** scrapes every host (per-flavor local plugins emit a JSON line
   each minute / 5-min / 10-min / hourly / daily).
2. **nagflux** ships those perfdata points into **InfluxDB** (`checkmk` DB,
   user `checkmk`).
3. **ticktator.py** lives on the CheckMK site as a notification handler;
   it opens **ServiceNow** incidents for CRITICAL events and auto-resolves
   them on recovery, with a 4-hour dedup window per host+service.
4. **Rundeck** picks up the same Ansible inventory + the rundeck facts
   from `db_inventory` for job orchestration.

## Configuration — `setup.yaml`

Every threshold, schedule, path, password and group lives in `setup.yaml`.
`dba_automation.yaml` uses `vars_files: [setup.yaml]` and pushes
`thresholds.json` to `C:\DBA\thresholds.json` on each Windows host so the
local plugins read the same numbers without redeploying scripts.

Vault sensitive values:

```bash
ansible-vault encrypt_string '<password>' --name 'checkmk_password'
# paste the !vault block into setup.yaml
```

## Tests / smoke checks

```bash
# Python parses (run from repo root)
for f in AI/app.py AI/settings.py AI/llm/client.py AI/handlers/**/*.py AI/tools/*.py; do
  python3 -c "import ast; ast.parse(open('$f').read())" && echo OK $f
done

# Playbook YAML parses
for p in AI/playbooks/*/*.yml dba_automation.yaml Oracle/dba_automation.yaml; do
  python3 -c "import yaml; list(yaml.safe_load_all(open('$p')))" && echo OK $p
done

# SQL guard rejects DML
python3 -c "
import sys; sys.path.insert(0, 'AI')
from handlers.sql_guard import sanitize, UnsafeSqlError
for q in ['SELECT 1', 'DELETE FROM t', 'SELECT 1; DROP TABLE x']:
    try: sanitize(q); print('PASS', q)
    except UnsafeSqlError as e: print('BLOCK', q, '→', e)
"
```

## Where to start hacking

| You want to … | Edit |
|---|---|
| Add a new chatbot intent for both flavors | `AI/llm/client.py` (prompts) + `AI/app.py` (dispatch) + per-flavor `ops_handler.py` |
| Tweak DBA thresholds (disk %, backup age, …) | `setup.yaml` → `thresholds.json.j2` rolls them out |
| Change which Ansible group the chatbot reads | `setup.yaml → inventory.sql_servers_group / oracle_servers_group` |
| Add a new DBA script for Windows | `files/<Name>.ps1`, then schedule it in `dba_automation.yaml` |
| Add a new DBA script for Oracle | `Oracle/files/<Name>.sh`, then schedule it in `Oracle/dba_automation.yaml` |
| Replace Ollama with OpenAI/Claude | `setup.yaml → chatbot.llm.provider` (no code change) |
