"""
Chatbot configuration — unified for SQL Server and Oracle.

The chatbot serves both flavors from one Flask app. UI tabs select the flavor;
the backend reads per-flavor paths from this file (or env, or setup.yaml).
"""

import os

try:
    import yaml
except ImportError:
    yaml = None


# ---------------------------------------------------------------------------
# Layout
# ---------------------------------------------------------------------------
BASE_DIR     = os.path.dirname(os.path.abspath(__file__))
REPO_DIR     = os.path.dirname(BASE_DIR)
PLAYBOOK_DIR = os.path.join(BASE_DIR, "playbooks")    # contains mssql/ + oracle/ + db2/
SCRIPTS_DIR  = os.path.join(REPO_DIR, "MSSQL", "files")  # Windows DBA PowerShell

# Per-flavor inventory paths. databases.ini files live next to each flavor's
# DBA scripts so they're shared with the on-host Ansible playbooks.
MSSQL_DATABASES_INI_DEFAULT  = os.path.join(REPO_DIR, "MSSQL",  "inventory", "databases.ini")
ORACLE_DATABASES_INI_DEFAULT = os.path.join(REPO_DIR, "Oracle", "inventory", "databases.ini")
DB2_DATABASES_INI_DEFAULT    = os.path.join(REPO_DIR, "Db2",    "inventory", "databases.ini")
MYSQL_DATABASES_INI_DEFAULT  = os.path.join(REPO_DIR, "MySQL",   "inventory", "databases.ini")
MARIADB_DATABASES_INI_DEFAULT = os.path.join(REPO_DIR, "MariaDB", "inventory", "databases.ini")

SETUP_YAML = os.environ.get("SETUP_YAML", os.path.join(REPO_DIR, "setup.yaml"))


def _load_setup():
    if yaml is None or not os.path.exists(SETUP_YAML):
        return {}
    try:
        with open(SETUP_YAML, "r", encoding="utf-8") as fh:
            return yaml.safe_load(fh) or {}
    except (OSError, yaml.YAMLError):
        return {}


_SETUP = _load_setup()


def _path(*keys, default=None):
    node = _SETUP
    for key in keys:
        if not isinstance(node, dict) or key not in node:
            return default
        node = node[key]
    return node if node is not None else default


def _env(name, default):
    return os.environ.get(name, default)


# ---------------------------------------------------------------------------
# LLM — single LiteLLM call routes to the right provider by model prefix.
#
# Default selection: highest-quality reachable provider based on which API
# keys are set. Override with LITELLM_MODEL=<provider/model> at any time.
#
#   ollama/llama3.1:8b       → http://localhost:11434
#   openai/gpt-4o-mini       → OPENAI_API_KEY
#   anthropic/claude-…       → ANTHROPIC_API_KEY        (Claude AI)
#   gemini/gemini-…          → GEMINI_API_KEY           (Google Gemini)
#   oci/<model-ocid>         → OCI GenAI (Oracle); auth via ~/.oci/config
#   azure/<deployment>       → AZURE_API_KEY + AZURE_API_BASE
#   bedrock/anthropic.claude-…
# ---------------------------------------------------------------------------
LLM_PROVIDER    = _env("LLM_PROVIDER",     _path("chatbot", "llm", "provider",     default="ollama"))

# Legacy keys retained for the auto-selection fallback below.
OLLAMA_BASE_URL = _env("OLLAMA_BASE_URL",  _path("chatbot", "llm", "ollama", "base_url", default="http://localhost:11434"))
OLLAMA_MODEL    = _env("OLLAMA_MODEL",     _path("chatbot", "llm", "ollama", "model",    default="llama3.1:8b"))
OLLAMA_TIMEOUT  = int(_env("OLLAMA_TIMEOUT", _path("chatbot", "llm", "ollama", "timeout", default=60)))
OPENAI_API_KEY  = _env("OPENAI_API_KEY",   _path("chatbot", "llm", "openai", "api_key",  default=""))
OPENAI_BASE_URL = _env("OPENAI_BASE_URL",  _path("chatbot", "llm", "openai", "base_url", default="https://api.openai.com/v1"))
OPENAI_MODEL    = _env("OPENAI_MODEL",     _path("chatbot", "llm", "openai", "model",    default="gpt-4o-mini"))
ANTHROPIC_API_KEY = _env("ANTHROPIC_API_KEY", _path("chatbot", "llm", "anthropic", "api_key", default=""))
ANTHROPIC_MODEL   = _env("ANTHROPIC_MODEL",   _path("chatbot", "llm", "anthropic", "model",   default="claude-sonnet-4-6"))

# Google Gemini — LiteLLM routes "gemini/<model>" off GEMINI_API_KEY.
GEMINI_API_KEY  = _env("GEMINI_API_KEY",   _path("chatbot", "llm", "gemini", "api_key", default=""))
GEMINI_MODEL    = _env("GEMINI_MODEL",     _path("chatbot", "llm", "gemini", "model",   default="gemini-2.0-flash"))

# Oracle OCI Generative AI — LiteLLM routes "oci/<model-ocid-or-name>".
# Authentication uses the standard OCI SDK config (~/.oci/config) or instance
# principals; region + compartment are required and exported for LiteLLM.
OCI_MODEL          = _env("OCI_MODEL",          _path("chatbot", "llm", "oci", "model",          default=""))
OCI_REGION         = _env("OCI_REGION",         _path("chatbot", "llm", "oci", "region",         default=""))
OCI_COMPARTMENT_ID = _env("OCI_COMPARTMENT_ID", _path("chatbot", "llm", "oci", "compartment_id", default=""))

LLM_TEMPERATURE = float(_env("LLM_TEMPERATURE", _path("chatbot", "llm", "temperature", default=0.1)))
LLM_MAX_TOKENS  = int(_env("LLM_MAX_TOKENS",   _path("chatbot", "llm", "max_tokens",  default=1024)))


def _auto_litellm_model():
    """Pick a model string for LiteLLM based on which providers are configured.

    Priority: Anthropic (Claude) > OpenAI > Google Gemini > Oracle OCI > Ollama.
    """
    if ANTHROPIC_API_KEY:
        return f"anthropic/{ANTHROPIC_MODEL}"
    if OPENAI_API_KEY:
        # 'openai/' prefix is optional but keeps the format consistent.
        return f"openai/{OPENAI_MODEL}"
    if GEMINI_API_KEY:
        return f"gemini/{GEMINI_MODEL}"
    if OCI_MODEL:
        return f"oci/{OCI_MODEL}"
    return f"ollama/{OLLAMA_MODEL}"


# Active model — explicit override beats auto-detection.
LITELLM_MODEL = _env("LITELLM_MODEL", _path("chatbot", "llm", "model", default="")) or _auto_litellm_model()

# Fallback chain: comma-separated model strings tried in order if the primary
# 5xx/timeouts. The auto chain is "best of what's reachable", reversed.
def _default_fallback_chain():
    primary = LITELLM_MODEL
    chain = []
    candidates = []
    if ANTHROPIC_API_KEY:
        candidates.append(f"anthropic/{ANTHROPIC_MODEL}")
    if OPENAI_API_KEY:
        candidates.append(f"openai/{OPENAI_MODEL}")
    if GEMINI_API_KEY:
        candidates.append(f"gemini/{GEMINI_MODEL}")
    if OCI_MODEL:
        candidates.append(f"oci/{OCI_MODEL}")
    candidates.append(f"ollama/{OLLAMA_MODEL}")
    for m in candidates:
        if m != primary and m not in chain:
            chain.append(m)
    return chain


_fb_env = _env("LITELLM_FALLBACKS", "")
LITELLM_FALLBACKS = (
    [m.strip() for m in _fb_env.split(",") if m.strip()]
    if _fb_env
    else _default_fallback_chain()
)

# Network behaviour — per-call timeout and retry count. Ollama is slow on CPU;
# 60s is a sensible upper bound. OpenAI / Anthropic usually finish in a few s.
LITELLM_TIMEOUT     = int(_env("LITELLM_TIMEOUT",     _path("chatbot", "llm", "timeout",       default=60)))
LITELLM_NUM_RETRIES = int(_env("LITELLM_NUM_RETRIES", _path("chatbot", "llm", "num_retries",   default=2)))

# Optional: silence LiteLLM verbose logging in production.
LITELLM_DEBUG = (_env("LITELLM_DEBUG", str(_path("chatbot", "llm", "debug", default=False))).lower() == "true")


# ---------------------------------------------------------------------------
# Semantic cache — LanceDB-backed cache for the classify() step.
#
# Near-identical questions ("how big is DB X" / "size of database X") resolve
# to the same structured intent without a fresh LLM round-trip. Only the
# language->intent classification is cached, never the summarize() step
# (which renders live DB/metric data and would go stale).
#
# Embeddings go through the same LiteLLM gateway as completions, so the cache
# inherits whatever provider is configured. Auto-selection mirrors the chat
# model: OpenAI if a key is set, else local Ollama (nomic-embed-text — pull it
# with `ollama pull nomic-embed-text`).
# ---------------------------------------------------------------------------
def _auto_embed_model():
    if OPENAI_API_KEY:
        return "openai/text-embedding-3-small"
    if GEMINI_API_KEY:
        return "gemini/text-embedding-004"
    return "ollama/nomic-embed-text"


CACHE_ENABLED     = (_env("CACHE_ENABLED", str(_path("chatbot", "cache", "enabled", default=True))).lower() == "true")
CACHE_DIR         = _env("CACHE_DIR", _path("chatbot", "cache", "dir", default=os.path.join(BASE_DIR, ".cache", "lancedb")))
CACHE_SIMILARITY  = float(_env("CACHE_SIMILARITY", _path("chatbot", "cache", "similarity", default=0.92)))
CACHE_EMBED_MODEL = _env("CACHE_EMBED_MODEL", _path("chatbot", "cache", "embed_model", default="")) or _auto_embed_model()


# ---------------------------------------------------------------------------
# Ansible — both inventories live in /etc/ansible/hosts. Per-flavor group
# names default to sql_servers / oracle_servers and are overridable.
# ---------------------------------------------------------------------------
INVENTORY_PATH       = _env("ANSIBLE_INVENTORY",    _path("inventory", "path",                  default="/etc/ansible/hosts"))
MSSQL_GROUP          = _env("ANSIBLE_SQL_GROUP",    _path("inventory", "sql_servers_group",     default="sql_servers"))
ORACLE_GROUP         = _env("ANSIBLE_ORACLE_GROUP", _path("inventory", "oracle_servers_group", default="oracle_servers"))
DB2_GROUP            = _env("ANSIBLE_DB2_GROUP",    _path("inventory", "db2_servers_group",     default="db2_servers"))
MYSQL_GROUP          = _env("ANSIBLE_MYSQL_GROUP",  _path("inventory", "mysql_servers_group",   default="mysql_servers"))
MARIADB_GROUP        = _env("ANSIBLE_MARIADB_GROUP", _path("inventory", "mariadb_servers_group", default="mariadb_servers"))
MSSQL_DATABASES_INI  = _env("MSSQL_DATABASES_INI",  MSSQL_DATABASES_INI_DEFAULT)
ORACLE_DATABASES_INI = _env("ORACLE_DATABASES_INI", ORACLE_DATABASES_INI_DEFAULT)
DB2_DATABASES_INI    = _env("DB2_DATABASES_INI",    DB2_DATABASES_INI_DEFAULT)
MYSQL_DATABASES_INI  = _env("MYSQL_DATABASES_INI",  MYSQL_DATABASES_INI_DEFAULT)
MARIADB_DATABASES_INI = _env("MARIADB_DATABASES_INI", MARIADB_DATABASES_INI_DEFAULT)
ANSIBLE_BIN          = _env("ANSIBLE_PLAYBOOK_BIN", "ansible-playbook")
ANSIBLE_TIMEOUT      = int(_env("ANSIBLE_TIMEOUT",  "600"))

# Back-compat alias used by older imports.
INVENTORY_SQL_GROUP  = MSSQL_GROUP


# ---------------------------------------------------------------------------
# InfluxDB (shared — same CheckMK pipeline)
# ---------------------------------------------------------------------------
INFLUX_HOST     = _env("INFLUX_HOST",     _path("chatbot", "influxdb", "host",     default="localhost"))
INFLUX_PORT     = int(_env("INFLUX_PORT", _path("chatbot", "influxdb", "port",     default=8086)))
INFLUX_DATABASE = _env("INFLUX_DATABASE", _path("chatbot", "influxdb", "database", default="checkmk"))
INFLUX_USER     = _env("INFLUX_USER",     _path("chatbot", "influxdb", "user",     default="checkmk"))
INFLUX_PASSWORD = _env("INFLUX_PASSWORD", _path("chatbot", "influxdb", "password", default="checkmk"))
INFLUX_SSL      = (_env("INFLUX_SSL",     str(_path("chatbot", "influxdb", "ssl",  default=False))).lower() == "true")


# ---------------------------------------------------------------------------
# SQL safety — single denylist covers both T-SQL and PL/SQL.
# ---------------------------------------------------------------------------
SQL_DENY_KEYWORDS = {
    "insert", "update", "delete", "merge", "truncate",
    "drop", "alter", "create", "rename", "comment",
    "grant", "revoke", "deny",
    "commit", "rollback", "savepoint",
    "exec", "execute", "begin", "declare", "call",
    "shutdown", "startup", "kill", "lock",
    "backup", "restore", "bulk",
    "openrowset", "openquery", "sp_configure", "xp_cmdshell",
    "utl_file", "utl_http", "dbms_lob", "dbms_xmlgen",
    "into",
    # Db2 utility / admin verbs (CLP + SQL-callable) that must never run via chat.
    "load", "import", "export", "reorg", "runstats",
    "prune", "quiesce", "activate", "deactivate",
}
SQL_MAX_ROWS = int(_env("SQL_MAX_ROWS", _path("chatbot", "sql", "max_rows", default=200)))


# ---------------------------------------------------------------------------
# Oracle-specific
# ---------------------------------------------------------------------------
ORACLE_OS_USER = _env("ORACLE_OS_USER", "oracle")


# ---------------------------------------------------------------------------
# Db2-specific
# ---------------------------------------------------------------------------
DB2_OS_USER = _env("DB2_OS_USER", "db2inst1")


# ---------------------------------------------------------------------------
# MySQL / MariaDB-specific
# ---------------------------------------------------------------------------
MYSQL_OS_USER   = _env("MYSQL_OS_USER", "root")
MARIADB_OS_USER = _env("MARIADB_OS_USER", "root")


# ---------------------------------------------------------------------------
# Flask
# ---------------------------------------------------------------------------
FLASK_HOST  = _env("FLASK_HOST", _path("chatbot", "flask", "host",  default="0.0.0.0"))
FLASK_PORT  = int(_env("FLASK_PORT", _path("chatbot", "flask", "port", default=5000)))
FLASK_DEBUG = (_env("FLASK_DEBUG", str(_path("chatbot", "flask", "debug", default=False))).lower() == "true")
