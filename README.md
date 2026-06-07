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
│   │   ├── oracle/              # PL/SQL + sqlplus handlers
│   │   └── db2/                 # Db2 SQL + db2 CLP handlers
│   ├── llm/
│   │   ├── client.py            # Ollama / OpenAI / Anthropic, flavor-aware prompts
│   │   └── semantic_cache.py    # LanceDB intent cache for classify() (optional)
│   ├── playbooks/
│   │   ├── mssql/               # ad-hoc playbooks the chatbot fires
│   │   ├── oracle/
│   │   └── db2/
│   ├── static/                  # chat UI (tab switcher, table + chart render)
│   ├── templates/index.html
│   └── tools/
│       ├── generate_mssql_databases_ini.py
│       ├── generate_oracle_databases_ini.py
│       └── generate_db2_databases_ini.py
│
├── MSSQL/                       # SQL Server DBA scripts + inventory
│   ├── files/                   # PowerShell scripts
│   │   ├── *.ps1                # Backups, CHECKDB, blocking, security audit, ...
│   │   └── checkmk_local/       # CheckMK custom checks for Windows
│   ├── inventory/databases.ini  # MSSQL section per DB (read by chatbot + playbooks)
│   ├── dba_automation.yaml      # Bootstrap + scheduled tasks for SQL Server hosts
│   └── install_sqlserver.yaml   # SQL Server 2022 installer playbook
│
├── Oracle/                      # Oracle DBA scripts + inventory
│   ├── files/                   # Shell scripts (sqlplus + RMAN)
│   │   ├── lib/oracle_common.sh
│   │   └── checkmk_local/       # CheckMK plugins for Linux
│   ├── inventory/databases.ini  # Oracle section per DB (read by chatbot + playbooks)
│   └── dba_automation.yaml      # Bootstrap + cron for Oracle hosts
│
├── Db2/                         # Db2 (LUW) DBA scripts + inventory
│   ├── files/                   # Shell scripts (db2 CLP)
│   │   ├── lib/db2_common.sh
│   │   └── checkmk_local/       # CheckMK plugins for Linux
│   ├── inventory/databases.ini  # Db2 section per DB (read by chatbot + playbooks)
│   └── dba_automation.yaml      # Bootstrap + cron for Db2 hosts
│
├── auto_onboard.yml             # Nightly: push dba_automation to newly added hosts
├── rundeckfacts.py              # db_inventory (mssql/oracle/db2) → Rundeck facts
├── bootstrap.sh                 # One-shot RHEL bootstrap for the management host
├── setup.yaml                   # Single source of truth for all knobs
├── ansible.cfg                  # forks=50 + pipelining
├── ticktator.py                 # CheckMK → ServiceNow notification bridge
├── sync_influx.sh               # Legacy CheckMK → InfluxDB poller
└── templates/                   # Per-flavor thresholds.json.j2 (mssql/oracle/db2) + plugin cfg
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

[db2_servers]
db2host01
db2host02
```

Then push the per-flavor DBA stack:

```bash
# SQL Server hosts (Windows / WinRM)
ansible-playbook -i /etc/ansible/hosts MSSQL/dba_automation.yaml --ask-vault-pass

# Oracle hosts (Linux / SSH)
ansible-playbook -i /etc/ansible/hosts Oracle/dba_automation.yaml --ask-vault-pass
```

Both playbooks install dbatools / dbatools-equivalents, deploy DBA scripts,
schedule the active-remediation tasks (cron / Task Scheduler), and drop
the CheckMK local plugins into the agent's `local/` dir.

## Running options — full reference

Every entry point below assumes you are in the repo root unless noted.
All playbooks share the same inventory (`/etc/ansible/hosts`) and the same
`setup.yaml`, so options compose: tag filters, `--limit`, `--check`,
`--ask-vault-pass`, `-e var=value` all work as expected.

### Management host bootstrap (`bootstrap.sh`)

```bash
sudo ./bootstrap.sh                          # full bootstrap (CheckMK, Ansible, nagflux,
                                             # Rundeck, Ollama, chatbot service, ticktator,
                                             # firewall)
SKIP_NAGFLUX=1 sudo ./bootstrap.sh           # skip nagflux phase
SKIP_RUNDECK=1 sudo ./bootstrap.sh           # skip Rundeck
SKIP_OLLAMA=1  sudo ./bootstrap.sh           # skip local LLM install
SKIP_CHATBOT=1 sudo ./bootstrap.sh           # skip Flask chatbot service
SKIP_AUTOONBOARD=1 sudo ./bootstrap.sh       # skip the nightly auto-onboard cron
SKIP_TICKTATOR=1 sudo ./bootstrap.sh         # skip ServiceNow notifier
GH_TOKEN=ghp_… sudo -E ./bootstrap.sh        # also log gh CLI in with this PAT
```

### Install SQL Server 2022 on Windows (`MSSQL/install_sqlserver.yaml`)

Uses the `microsoft.sql.server` collection role; media path lives in
`setup.yaml → sql_install.source.*`. Run once per fresh host.

```bash
ansible-galaxy collection install microsoft.sql chocolatey.chocolatey ansible.windows

# Full install (engine + SSMS via chocolatey)
ansible-playbook -i /etc/ansible/hosts MSSQL/install_sqlserver.yaml --ask-vault-pass

# Single host
ansible-playbook MSSQL/install_sqlserver.yaml --limit sqlprod01 --ask-vault-pass

# Tag-filtered runs
ansible-playbook MSSQL/install_sqlserver.yaml --tags stage    # copy ISO/folder only, no install
ansible-playbook MSSQL/install_sqlserver.yaml --tags engine   # engine only (skip SSMS)
ansible-playbook MSSQL/install_sqlserver.yaml --tags ssms     # SSMS only (engine already present)
ansible-playbook MSSQL/install_sqlserver.yaml --tags verify   # smoke-test existing install

# Overrides without editing setup.yaml
ansible-playbook MSSQL/install_sqlserver.yaml \
    -e sql_install.edition=Developer \
    -e sql_install.instance_name=SQL01 \
    --ask-vault-pass
```

### SQL Server day-2 automation (`MSSQL/dba_automation.yaml`)

```bash
# Everything: install dbatools, push scripts, render thresholds.json,
# schedule tasks, drop CheckMK local plugins.
ansible-playbook -i /etc/ansible/hosts MSSQL/dba_automation.yaml --ask-vault-pass

# Per-host
ansible-playbook MSSQL/dba_automation.yaml --limit sqlprod01 --ask-vault-pass

# Tag-filtered (the playbook annotates every block — pick what you need):
ansible-playbook MSSQL/dba_automation.yaml --tags bootstrap      # dbatools, event source, dirs
ansible-playbook MSSQL/dba_automation.yaml --tags install        # alias for bootstrap+facts+checkmk
ansible-playbook MSSQL/dba_automation.yaml --tags facts          # push db_inventory.ps1, re-gather
ansible-playbook MSSQL/dba_automation.yaml --tags config         # render thresholds.json only
ansible-playbook MSSQL/dba_automation.yaml --tags scripts        # push all PowerShell scripts
ansible-playbook MSSQL/dba_automation.yaml --tags localplugins   # push CheckMK local checks
ansible-playbook MSSQL/dba_automation.yaml --tags checkmk        # CheckMK agent + plugins
ansible-playbook MSSQL/dba_automation.yaml --tags backups        # schedule FULL/DIFF/LOG tasks
ansible-playbook MSSQL/dba_automation.yaml --tags integrity      # schedule DBCC CHECKDB
ansible-playbook MSSQL/dba_automation.yaml --tags maintenance    # blocking, deadlocks, tempdb
ansible-playbook MSSQL/dba_automation.yaml --tags remediation    # active-remediation tasks
ansible-playbook MSSQL/dba_automation.yaml --tags security       # account/security monitors
ansible-playbook MSSQL/dba_automation.yaml --tags cleanup        # remove stale logs/tasks

# Dry-run / change-preview
ansible-playbook MSSQL/dba_automation.yaml --check --diff --ask-vault-pass
```

### Oracle day-2 automation (`Oracle/dba_automation.yaml`)

```bash
ansible-playbook -i /etc/ansible/hosts Oracle/dba_automation.yaml --ask-vault-pass

# Same tag vocabulary as the SQL playbook (mapped to shell scripts + cron)
ansible-playbook Oracle/dba_automation.yaml --tags config       # render thresholds
ansible-playbook Oracle/dba_automation.yaml --tags scripts      # push shell scripts
ansible-playbook Oracle/dba_automation.yaml --tags facts        # db_inventory.sh + re-gather
ansible-playbook Oracle/dba_automation.yaml --tags localplugins # CheckMK Linux plugins
ansible-playbook Oracle/dba_automation.yaml --tags backups      # RMAN cron jobs
ansible-playbook Oracle/dba_automation.yaml --tags integrity    # RMAN VALIDATE / DBV
ansible-playbook Oracle/dba_automation.yaml --tags maintenance  # index/space jobs
ansible-playbook Oracle/dba_automation.yaml --tags remediation  # active fixes
ansible-playbook Oracle/dba_automation.yaml --tags security     # account audit
ansible-playbook Oracle/dba_automation.yaml --tags cleanup
```

### Db2 day-2 automation (`Db2/dba_automation.yaml`)

```bash
ansible-playbook -i /etc/ansible/hosts Db2/dba_automation.yaml --ask-vault-pass

# Same tag vocabulary as the Oracle/SQL playbooks (mapped to db2 CLP + cron)
ansible-playbook Db2/dba_automation.yaml --tags config       # render thresholds
ansible-playbook Db2/dba_automation.yaml --tags scripts      # push shell scripts
ansible-playbook Db2/dba_automation.yaml --tags facts        # db_inventory.sh + re-gather
ansible-playbook Db2/dba_automation.yaml --tags localplugins # CheckMK Linux plugins
ansible-playbook Db2/dba_automation.yaml --tags backups      # online/incr/log backup cron
ansible-playbook Db2/dba_automation.yaml --tags integrity    # weekly INSPECT CHECK
ansible-playbook Db2/dba_automation.yaml --tags maintenance  # watchdog, blocking, REORG
ansible-playbook Db2/dba_automation.yaml --tags security     # DBADM/PUBLIC audit
ansible-playbook Db2/dba_automation.yaml --tags cleanup
```

Targets `[db2_servers]`; runs the `db2` CLP as the `db2inst1` instance owner.
Read-only monitoring (tablespaces, backups, HADR, security) runs as CheckMK
local plugins; active work (backup, INSPECT CHECK, REORG, forcing blockers) is
cron-scheduled only — never exposed as a chatbot intent.

### Nightly auto-onboarding (`auto_onboard.yml`)

Pushes each flavor's `dba_automation.yaml` to hosts **newly added** to
`/etc/ansible/hosts` — i.e. those that don't yet carry the onboarding marker
(`/opt/dba/.onboarded` on Linux, `C:\DBA\.onboarded` on Windows). `bootstrap.sh`
installs this as a nightly cron (`/etc/cron.d/aacu-auto-onboard`, 01:30); run it
by hand any time:

```bash
# Onboard only un-onboarded hosts (the nightly behaviour)
ansible-playbook -i /etc/ansible/hosts auto_onboard.yml \
    -e onboard_group=pending_onboard --ask-vault-pass

# Omit -e onboard_group to force a full refresh of every host in every group
ansible-playbook -i /etc/ansible/hosts auto_onboard.yml --ask-vault-pass
```

It detects new hosts, adds them to a dynamic `pending_onboard` group, imports
all three `dba_automation.yaml` playbooks (whose `hosts:` intersect their group
with `onboard_group`), then stamps the marker so each host is onboarded once.
Idempotent: a night with no new hosts matches zero hosts and does nothing.
For unattended runs the cron passes `--vault-password-file /etc/aacu/.vault_pass`
when that file exists.

### CIS Microsoft SQL Server 2022 Benchmark (`MSSQL/files/CISBenchmarkSQL2022.ps1`)

Runs on the Windows target — audit-only by default. With `-Remediate` it
captures the BEFORE state, appends a revert command to a rollback file,
then applies the fix.

```powershell
# Audit only (read-only) - writes JSON report to C:\Logs\SQL_CIS2022_<ts>.json
powershell -ExecutionPolicy Bypass `
  -File C:\ProgramData\Ansible\CISBenchmarkSQL2022.ps1

# Audit + emit JSON to stdout (for Ansible facts.d / win_shell capture)
powershell -ExecutionPolicy Bypass `
  -File CISBenchmarkSQL2022.ps1 -AsAnsibleFact

# L1 only / L2 only
powershell -File CISBenchmarkSQL2022.ps1 -Level L1
powershell -File CISBenchmarkSQL2022.ps1 -Level L2

# Restrict to specific controls
powershell -File CISBenchmarkSQL2022.ps1 -Controls 2.1,2.2,2.4,2.9,4.3

# Dry-run remediation - captures rollback file but does NOT execute fixes
powershell -File CISBenchmarkSQL2022.ps1 -Remediate -WhatIf `
  -Controls 2.1,2.2,2.4,2.5,2.9,2.13

# Apply remediation (after change approval). Each change is logged with
# BEFORE state + revert command; rollback file path is in the JSON output.
powershell -File CISBenchmarkSQL2022.ps1 -Remediate `
  -Controls 2.1,2.2,2.4,2.5,2.9,2.13 -AsAnsibleFact
```

From Ansible:

```bash
# Audit every Windows host
ansible sql_servers -m ansible.windows.win_shell \
  -a 'powershell.exe -ExecutionPolicy Bypass -File C:\ProgramData\Ansible\CISBenchmarkSQL2022.ps1 -AsAnsibleFact'
```

### Individual PowerShell scripts (`MSSQL/files/*.ps1`)

All scripts auto-discover local instances via the registry, use dbatools,
log to `C:\Logs\<Name>_<yyyyMMdd>.log` and the Windows Application event log
with source `SQL Server Health Check`. Read-only by default; active-remediation
scripts take parameters that gate the destructive action.

```powershell
# Health / audit (read-only)
powershell -File C:\DBA\scripts\SecurityAudit.ps1 -StaleLoginDays 90
powershell -File C:\DBA\scripts\PatchLevelCheck.ps1 -BuildMinAge_Days 180
powershell -File C:\DBA\scripts\MonitorAgentJobs.ps1
powershell -File C:\DBA\scripts\MonitorAlwaysOn.ps1
powershell -File C:\DBA\scripts\MonitorDiskSpace.ps1
powershell -File C:\DBA\scripts\MonitorTempDB.ps1
powershell -File C:\DBA\scripts\MonitorAccountSecurity.ps1
powershell -File C:\DBA\scripts\GetCheckDBStatus.ps1
powershell -File C:\DBA\scripts\CheckmssqlStatus.ps1

# Active maintenance / remediation (each takes safety parameters)
powershell -File C:\DBA\scripts\BackupDatabases.ps1 -BackupType Full
powershell -File C:\DBA\scripts\BackupDatabases.ps1 -BackupType Differential
powershell -File C:\DBA\scripts\BackupDatabases.ps1 -BackupType Log
powershell -File C:\DBA\scripts\VerifyBackups.ps1 -SampleCount 3
powershell -File C:\DBA\scripts\DBCCCheckDB.ps1 -PhysicalOnlyAboveGB 200
powershell -File C:\DBA\scripts\DetectBlockingLocks.ps1 -AutoKillMinutes 60
powershell -File C:\DBA\scripts\DetectDeadlocks.ps1 -WindowMinutes 35
powershell -File C:\DBA\scripts\IndexMaintenance.ps1 -RebuildPct 30 -ReorgPct 10

# CheckMK monitoring login (creates 'checkmk' SQL login with read-only role)
powershell -File C:\DBA\scripts\createcheckmk.ps1
```

### Chatbot (`AI/app.py`)

```bash
# Production: managed by systemd (bootstrap.sh installs the unit)
sudo systemctl status aacu-chatbot
sudo systemctl restart aacu-chatbot
sudo journalctl -u aacu-chatbot -f

# Dev / debug: run Flask directly
cd AI && python3 app.py                  # http://localhost:5000
FLASK_DEBUG=1 python3 AI/app.py          # auto-reload + tracebacks

# Override LLM at startup (provider auto-selects from whichever is configured)
ANTHROPIC_API_KEY=sk-… python3 AI/app.py     # Claude AI
OPENAI_API_KEY=sk-…    python3 AI/app.py
GEMINI_API_KEY=…       python3 AI/app.py     # Google Gemini
OCI_MODEL=cohere.command-r-plus OCI_REGION=us-ashburn-1 \
  OCI_COMPARTMENT_ID=ocid1.compartment… python3 AI/app.py   # Oracle OCI GenAI
# (auto-select priority: anthropic > openai > gemini > oci > ollama;
#  force one with LITELLM_MODEL=<provider/model>)
```

**Semantic cache** (LanceDB, embedded — no server). Configured under
`setup.yaml → chatbot.cache`; overridable by env:

```bash
pip install lancedb pyarrow            # already in AI/requirements.txt
ollama pull nomic-embed-text           # default embedder when no OpenAI key is set

CACHE_ENABLED=false python3 AI/app.py  # kill-switch (always hit the LLM)
CACHE_SIMILARITY=0.88 python3 AI/app.py# looser matching → more cache hits
CACHE_EMBED_MODEL=openai/text-embedding-3-small python3 AI/app.py
CACHE_DIR=/var/lib/aacu/cache python3 AI/app.py   # relocate the store
```

The cache auto-selects its embedder the same way as the chat model
(OpenAI key → `text-embedding-3-small`, else `ollama/nomic-embed-text`) and
silently no-ops if `lancedb` isn't installed. Hits/misses are logged under
the `aacu.cache` logger.

### Inventory / facts tools

```bash
# Rebuild the chatbot's per-DB catalogue from Ansible facts
python3 AI/tools/generate_mssql_databases_ini.py            # → MSSQL/inventory/databases.ini
python3 AI/tools/generate_mssql_databases_ini.py --dry-run
python3 AI/tools/generate_mssql_databases_ini.py \
        --from-tree /var/lib/ansible/facts_cache

python3 AI/tools/generate_oracle_databases_ini.py           # → Oracle/inventory/databases.ini
python3 AI/tools/generate_oracle_databases_ini.py --dry-run

python3 AI/tools/generate_db2_databases_ini.py              # → Db2/inventory/databases.ini
python3 AI/tools/generate_db2_databases_ini.py --dry-run

# Turn db_inventory facts (mssql/oracle/db2) into Rundeck resource facts.
# Run from a dir holding db_inventory*.json/.facts; writes <flavor>/<instance>/…
python3 rundeckfacts.py
```

### CheckMK → ServiceNow notifier (`ticktator.py`)

Normally invoked by CheckMK as a notification command (see
`/omd/sites/<site>/etc/check_mk/notify.d/`). Manual run:

```bash
# Dry-run (no ticket created)
TICKTATOR_DRY_RUN=1 ./ticktator.py \
    --host sqlprod01 --service "MSSQL_Backup" --state CRITICAL --output "Backup older than 30h"

# Real run (uses env from /etc/default/ticktator)
./ticktator.py --host sqlprod01 --service "MSSQL_Backup" --state CRITICAL --output "..."

# Tail the dedup state file
tail -f /var/lib/ticktator/state.json
journalctl -u check_mk@<site> -f | grep ticktator
```

### Legacy CheckMK → InfluxDB poller (`sync_influx.sh`)

```bash
# Manual one-shot pull (nagflux is the supported path now)
./sync_influx.sh

# Cron entry (every 5 min)
*/5 * * * * /opt/aacu/sync_influx.sh >> /var/log/sync_influx.log 2>&1
```

### Useful one-liners

```bash
# Re-render thresholds.json without reinstalling anything
ansible-playbook MSSQL/dba_automation.yaml --tags config --ask-vault-pass

# Re-gather Ansible custom facts only (after editing db_inventory.ps1)
ansible-playbook MSSQL/dba_automation.yaml --tags facts

# Force CIS scan on every Windows host and pull the report back
ansible sql_servers -m ansible.windows.win_shell \
  -a 'powershell -File C:\ProgramData\Ansible\CISBenchmarkSQL2022.ps1 -AsAnsibleFact' \
  --tree /tmp/cis_results

# Validate YAML / Jinja before pushing
ansible-playbook MSSQL/dba_automation.yaml --syntax-check
ansible-playbook MSSQL/install_sqlserver.yaml --syntax-check
ansible-lint MSSQL/dba_automation.yaml MSSQL/install_sqlserver.yaml

# Vault helpers
ansible-vault encrypt_string 'StrongP@ssw0rd!' --name 'sa_password'
ansible-vault view setup.yaml
ansible-vault edit setup.yaml
```

## Building the database catalogue

The chatbot's dropdown reads from `databases.ini`. Generate / refresh both
catalogues from the Ansible custom facts that `db_inventory.{ps1,sh}` produced:

```bash
python3 AI/tools/generate_mssql_databases_ini.py    # → MSSQL/inventory/databases.ini
python3 AI/tools/generate_oracle_databases_ini.py   # → Oracle/inventory/databases.ini
python3 AI/tools/generate_db2_databases_ini.py      # → Db2/inventory/databases.ini
```

User-edited fields (passwords, retention, email lists) are preserved across
re-runs. Each tool takes `--dry-run` and `--from-tree <dir>`.

## The chatbot

http://&lt;management host&gt;:5000

- **Tab switcher** at the top — `SQL Server` ⇄ `Oracle` ⇄ `Db2`. Switching reloads
  the database dropdown and filters the session history to the active flavor.
- **Database picker** lists every section in the active flavor's
  `databases.ini`. Picking a DB resolves the target host automatically
  (each section's `ansible_servername`). Hosts not in `/etc/ansible/hosts`
  show with an amber ⚠ in the dropdown.
- **Intents** (auto-detected by the LLM): `sql_query` (SELECT-only),
  `influx_query` (CheckMK metrics, rendered as charts), `combo_query`,
  `health_check`, `backup_status`, `integrity_status`, `disk_status`,
  `agent_jobs`, `tempdb_status`, `security_audit`, `patch_level`,
  `alwayson_status`, `check_blocking_locks`, `add_datafile_space`,
  `performance_review` (long-running SQL + top consumers + waits, with the
  assistant proposing remediations) — plus Oracle-only `create_restore_point`,
  `list_restore_points`, `grow_recovery_size`.
- **Read-only SQL gate** — every query passes through `handlers/sql_guard.py`;
  any non-SELECT / multi-statement / dangerous keyword is rejected before
  it ever leaves the chatbot process.
- **Semantic cache** (optional) — `llm/semantic_cache.py` embeds each message
  and looks it up in an embedded LanceDB store, so a near-identical prior
  question reuses its structured intent and skips the classify LLM call.
  Only intent is cached (partitioned by flavor + selected DB), never the
  summarized reply over live data. No-ops gracefully if `lancedb` is absent.
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
`MSSQL/dba_automation.yaml` uses `vars_files: [../setup.yaml]` and pushes
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
| Add a new DBA script for Windows | `MSSQL/files/<Name>.ps1`, then schedule it in `MSSQL/dba_automation.yaml` |
| Add a new DBA script for Oracle | `Oracle/files/<Name>.sh`, then schedule it in `Oracle/dba_automation.yaml` |
| Add a new DBA script for Db2 | `Db2/files/<Name>.sh`, then schedule it in `Db2/dba_automation.yaml` |
| Switch LLM provider (Claude / OpenAI / Gemini / Oracle OCI / Ollama) | `setup.yaml → chatbot.llm.*` or `LITELLM_MODEL=<provider/model>` (no code change) |
| Tune / disable the intent cache | `setup.yaml → chatbot.cache` (`enabled`, `similarity`, `embed_model`) |
