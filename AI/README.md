# DB Info Chatbot

Flask chatbot that answers database questions and runs a small set of
**read-only / additive** operations against SQL Server hosts. It uses
Ollama by default for the LLM, Ansible (WinRM) to reach Windows
SQL Server hosts, and the InfluxDB instance fed by `sync_influx.sh`
for CheckMK metrics.

```
AI/
├── app.py                  Flask entry point
├── settings.py             LLM / Ansible / InfluxDB config
├── requirements.txt
├── llm/
│   └── client.py           Provider-agnostic LLM client + intent parser
├── handlers/
│   ├── ansible_runner.py   ansible-playbook subprocess wrapper
│   ├── sql_guard.py        SELECT-only sanitiser
│   ├── sql_handler.py      Read-only SQL via dbatools
│   ├── influx_handler.py   CheckMK stats from InfluxDB v1
│   └── ops_handler.py      Blocking locks / datafile grow / health check
├── playbooks/
│   ├── run_sql_query.yml
│   ├── check_blocking_locks.yml
│   ├── add_datafile_space.yml
│   └── health_check.yml
├── inventory/
│   └── hosts.ini.example
├── templates/index.html
└── static/{styles.css,chat.js}
```

## What it can do

| Intent | What it runs |
|---|---|
| `sql_query` | `Invoke-DbaQuery -ReadOnly` on the target. Rejects anything that isn't a single `SELECT` / `WITH ... SELECT`. Rendered as a table. |
| `influx_query` | InfluxDB v1 query against the `influx` database that `sync_influx.sh` populates from CheckMK RRDs. Rendered as a Chart.js line chart. |
| `combo_query` | Runs an InfluxDB query **and** a SELECT in one turn, then the LLM writes a single answer that references both. The UI shows the table + the chart together. |
| `check_blocking_locks` | Copies and runs [`files/DetectBlockingLocks.ps1`](../files/DetectBlockingLocks.ps1). |
| `add_datafile_space` | `ALTER DATABASE … MODIFY FILE` to grow a logical file by N MB (read current size first). |
| `health_check` | Runs [`files/CheckmssqlStatus.ps1`](../files/CheckmssqlStatus.ps1) + [`files/db_inventory.ps1`](../files/db_inventory.ps1) and merges them with the Rundeck-style facts from [`rundeckfacts.py`](../rundeckfacts.py). |
| `chat` | Free-form answer when no tool fits (the LLM asks a clarifying question). |

## Setup

```bash
cd AI
pip install -r requirements.txt
# Default inventory location is /etc/ansible/hosts.
# Point ANSIBLE_INVENTORY elsewhere if you keep yours in a different file:
#   export ANSIBLE_INVENTORY=/path/to/hosts
```

Make sure Ollama already has the model you want pulled:

```bash
ollama pull llama3.1:8b
```

Override defaults via environment variables. Common ones:

| Var | Default | Purpose |
|---|---|---|
| `LLM_PROVIDER` | `ollama` | `ollama` / `openai` / `anthropic` |
| `OLLAMA_MODEL` | `llama3.1:8b` | Model tag served by your local Ollama |
| `INFLUX_HOST` | `localhost` | Matches `sync_influx.sh` |
| `INFLUX_DATABASE` | `influx` | Same |
| `ANSIBLE_INVENTORY` | `/etc/ansible/hosts` | Where the host list lives |
| `SQL_MAX_ROWS` | `200` | Cap on rows surfaced to chat |

## Run

```bash
python app.py
# then open http://localhost:5000
```

`GET /api/health` reports the resolved provider/model and which servers
the chatbot can see in the inventory.

## Safety model

* The chatbot **never** issues a write/DDL statement. `handlers/sql_guard.py`
  strips comments, forbids `;`-separated statements, and only lets
  `SELECT` / `WITH` through. The keyword denylist in `settings.SQL_DENY_KEYWORDS`
  blocks `INSERT`, `UPDATE`, `DELETE`, `DROP`, `ALTER`, `EXEC`,
  `xp_cmdshell`, etc.
* `add_datafile_space` is the only *additive* operation. It can only grow a
  file (never shrink) and caps a single growth at 100 GiB.
* All target access goes through Ansible — credentials live in the
  inventory, not in the chatbot process.
