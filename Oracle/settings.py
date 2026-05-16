"""
Chatbot configuration — Oracle edition.

Same loader pattern as AI/settings.py but defaults point at the Oracle
script directory, the `oracle_servers` inventory group, and the local
databases.ini for credentials.
"""

import os

try:
    import yaml
except ImportError:
    yaml = None


BASE_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_DIR = os.path.dirname(BASE_DIR)
PLAYBOOK_DIR = os.path.join(BASE_DIR, "playbooks")
SCRIPTS_DIR  = os.path.join(BASE_DIR, "files")           # Oracle scripts live here
DATABASES_INI = os.path.join(BASE_DIR, "inventory", "databases.ini")
SETUP_YAML   = os.environ.get("SETUP_YAML", os.path.join(REPO_DIR, "setup.yaml"))


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
# LLM
# ---------------------------------------------------------------------------
LLM_PROVIDER = _env("LLM_PROVIDER", _path("chatbot", "llm", "provider", default="ollama"))
OLLAMA_BASE_URL = _env("OLLAMA_BASE_URL", _path("chatbot", "llm", "ollama", "base_url", default="http://localhost:11434"))
OLLAMA_MODEL    = _env("OLLAMA_MODEL",    _path("chatbot", "llm", "ollama", "model",    default="llama3.1:8b"))
OLLAMA_TIMEOUT  = int(_env("OLLAMA_TIMEOUT", _path("chatbot", "llm", "ollama", "timeout", default=120)))
OPENAI_API_KEY  = _env("OPENAI_API_KEY",  _path("chatbot", "llm", "openai", "api_key",  default=""))
OPENAI_BASE_URL = _env("OPENAI_BASE_URL", _path("chatbot", "llm", "openai", "base_url", default="https://api.openai.com/v1"))
OPENAI_MODEL    = _env("OPENAI_MODEL",    _path("chatbot", "llm", "openai", "model",    default="gpt-4o-mini"))
ANTHROPIC_API_KEY = _env("ANTHROPIC_API_KEY", _path("chatbot", "llm", "anthropic", "api_key", default=""))
ANTHROPIC_MODEL   = _env("ANTHROPIC_MODEL",   _path("chatbot", "llm", "anthropic", "model",   default="claude-sonnet-4-6"))
LLM_TEMPERATURE = float(_env("LLM_TEMPERATURE", _path("chatbot", "llm", "temperature", default=0.1)))
LLM_MAX_TOKENS  = int(_env("LLM_MAX_TOKENS",   _path("chatbot", "llm", "max_tokens",  default=1024)))


# ---------------------------------------------------------------------------
# Ansible — Oracle defaults
# ---------------------------------------------------------------------------
INVENTORY_PATH      = _env("ANSIBLE_INVENTORY", _path("inventory", "path", default="/etc/ansible/hosts"))
INVENTORY_SQL_GROUP = _env("ANSIBLE_ORACLE_GROUP",
                           _path("inventory", "oracle_servers_group", default="oracle_servers"))
ANSIBLE_BIN         = _env("ANSIBLE_PLAYBOOK_BIN", "ansible-playbook")
ANSIBLE_TIMEOUT     = int(_env("ANSIBLE_TIMEOUT", "600"))


# ---------------------------------------------------------------------------
# InfluxDB
# ---------------------------------------------------------------------------
INFLUX_HOST     = _env("INFLUX_HOST",     _path("chatbot", "influxdb", "host",     default="localhost"))
INFLUX_PORT     = int(_env("INFLUX_PORT", _path("chatbot", "influxdb", "port",     default=8086)))
INFLUX_DATABASE = _env("INFLUX_DATABASE", _path("chatbot", "influxdb", "database", default="checkmk"))
INFLUX_USER     = _env("INFLUX_USER",     _path("chatbot", "influxdb", "user",     default="checkmk"))
INFLUX_PASSWORD = _env("INFLUX_PASSWORD", _path("chatbot", "influxdb", "password", default="checkmk"))
INFLUX_SSL      = (_env("INFLUX_SSL",     str(_path("chatbot", "influxdb", "ssl",  default=False))).lower() == "true")


# ---------------------------------------------------------------------------
# SQL safety (Oracle PL/SQL aware denylist)
# ---------------------------------------------------------------------------
SQL_DENY_KEYWORDS = {
    "insert", "update", "delete", "merge", "truncate",
    "drop", "alter", "create", "rename", "comment",
    "grant", "revoke",
    "commit", "rollback", "savepoint",
    "exec", "execute", "begin", "declare", "call",
    "shutdown", "startup", "kill", "lock",
    "utl_file", "utl_http", "dbms_lob", "dbms_xmlgen",
    "into",  # SELECT ... INTO TABLE creates a new table
}
SQL_MAX_ROWS = int(_env("SQL_MAX_ROWS", _path("chatbot", "sql", "max_rows", default=200)))


# ---------------------------------------------------------------------------
# Oracle-specific
# ---------------------------------------------------------------------------
ORACLE_DATABASES_INI = _env("ORACLE_DATABASES_INI", DATABASES_INI)
ORACLE_OS_USER       = _env("ORACLE_OS_USER", "oracle")


# ---------------------------------------------------------------------------
# Flask
# ---------------------------------------------------------------------------
FLASK_HOST  = _env("FLASK_HOST", _path("chatbot", "flask", "host",  default="0.0.0.0"))
FLASK_PORT  = int(_env("FLASK_PORT", _path("chatbot", "flask", "port",  default=5001)))   # different port than AI/
FLASK_DEBUG = (_env("FLASK_DEBUG", str(_path("chatbot", "flask", "debug", default=False))).lower() == "true")
