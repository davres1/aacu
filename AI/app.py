"""
Flask-based DB info chatbot.

Run with:
    python app.py
or:
    flask --app app run --host 0.0.0.0 --port 5000
"""

import configparser
import os
import traceback

from flask import Flask, jsonify, render_template, request

import settings
from llm import client as llm_client
from handlers import (
    influx_handler,
    ops_handler,
    sql_handler,
)
from handlers.sql_guard import UnsafeSqlError

app = Flask(__name__)


# ---------------------------------------------------------------------------
# Inventory helpers
# ---------------------------------------------------------------------------

def _read_inventory():
    """Parse the Ansible inventory file. Returns the ConfigParser or None."""
    if not os.path.exists(settings.INVENTORY_PATH):
        return None
    parser = configparser.ConfigParser(allow_no_value=True, delimiters=("=",))
    parser.optionxform = str
    try:
        parser.read(settings.INVENTORY_PATH)
    except configparser.Error:
        return None
    return parser


def _hosts_in_section(parser, section):
    """Return the host names in the given INI section, stripping inline vars."""
    if section not in parser:
        return []
    out = []
    for raw in parser[section].keys():
        if not raw or raw.startswith((";", "#")):
            continue
        host = raw.split()[0].strip()              # "host01 ansible_user=x" -> "host01"
        if host and not host.endswith(":vars"):
            out.append(host)
    return out


def _known_servers():
    """Hosts in the configured [sql_servers] group (settings.INVENTORY_SQL_GROUP).

    Strict: returns only hosts in that one group. Configure via
    setup.yaml -> inventory.sql_servers_group (default 'sql_servers').
    """
    parser = _read_inventory()
    if parser is None:
        return []
    return sorted(set(_hosts_in_section(parser, settings.INVENTORY_SQL_GROUP)))


def _servers_metadata():
    """Detailed response for /api/servers — surfaces config issues to the UI."""
    parser = _read_inventory()
    inv_exists = parser is not None
    group = settings.INVENTORY_SQL_GROUP
    if not inv_exists:
        return {
            "group": group,
            "servers": [],
            "inventory": settings.INVENTORY_PATH,
            "inventory_exists": False,
            "group_exists": False,
            "hint": f"Inventory file not found at {settings.INVENTORY_PATH}",
        }
    group_exists = group in parser
    return {
        "group": group,
        "servers": sorted(set(_hosts_in_section(parser, group))),
        "inventory": settings.INVENTORY_PATH,
        "inventory_exists": True,
        "group_exists": group_exists,
        "hint": None if group_exists
                     else f"Group [{group}] not found in {settings.INVENTORY_PATH}",
    }


# ---------------------------------------------------------------------------
# databases.ini reader — one section per SQL Server database. Each section
# carries ansible_servername + sql_instance + database; the chatbot uses the
# section to drive both the UI dropdown and the auto-server-resolve hook.
# ---------------------------------------------------------------------------

_DB_INI_RESERVED_SECTIONS = {"sql_servers", "DEFAULT"}


def _read_databases_ini():
    path = settings.MSSQL_DATABASES_INI
    if not path or not os.path.exists(path):
        return None, path
    parser = configparser.ConfigParser(allow_no_value=True, delimiters=("=",),
                                       interpolation=None)
    parser.optionxform = str
    try:
        parser.read(path)
    except configparser.Error:
        return None, path
    return parser, path


def _databases_metadata():
    """Every SQL Server database known to the chatbot, with config sanity flags."""
    parser, path = _read_databases_ini()
    inv_hosts = set(_known_servers())

    if parser is None:
        return {
            "databases": [],
            "databases_ini": path,
            "databases_ini_exists": False,
            "hint": (f"databases.ini not found at {path}. Run "
                     "`python3 AI/tools/generate_databases_ini.py` to create it."),
        }

    rows = []
    missing = 0
    for section in parser.sections():
        if section in _DB_INI_RESERVED_SECTIONS:
            continue
        get = parser[section].get
        ansible_servername = (get("ansible_servername", "") or "").strip()
        in_inv = (ansible_servername in inv_hosts) if ansible_servername else False
        if not ansible_servername or not in_inv:
            missing += 1
        rows.append({
            "name":               section,
            "ansible_servername": ansible_servername or None,
            "in_inventory":       in_inv,
            "sql_instance":       (get("sql_instance", "") or "").strip() or None,
            "database":           (get("database", "") or section).strip(),
            "environment":        (get("environment", "") or "").strip() or None,
            "edition":            (get("edition", "") or "").strip() or None,
            "version":            (get("version", "") or "").strip() or None,
            "emaillist":          (get("emaillist", "") or "").strip() or None,
            "lastupdated":        (get("lastupdated", "") or "").strip() or None,
        })

    rows.sort(key=lambda r: r["name"].lower())

    return {
        "databases":            rows,
        "databases_ini":        path,
        "databases_ini_exists": True,
        "inventory":            settings.INVENTORY_PATH,
        "inventory_group":      settings.INVENTORY_SQL_GROUP,
        "missing_server_count": missing,
        "hint":                 None if rows else "databases.ini contains no DB sections",
    }


def _resolve_db_section(database):
    """Case-insensitive lookup of a databases.ini section."""
    if not database:
        return None
    parser, _ = _read_databases_ini()
    if parser is None:
        return None
    target_lc = database.strip().lower()
    for section in parser.sections():
        if section in _DB_INI_RESERVED_SECTIONS:
            continue
        if section.lower() == target_lc:
            return section, parser[section]
    return None


def _resolve_server_for_db(database):
    """Look up ansible_servername in databases.ini for a given DB name."""
    found = _resolve_db_section(database)
    if not found:
        return None
    section, sec = found
    return (sec.get("ansible_servername", "") or "").strip() or None


def _resolve_instance_for_db(database):
    """Look up sql_instance in databases.ini; fall back to ansible_servername."""
    found = _resolve_db_section(database)
    if not found:
        return None
    section, sec = found
    inst = (sec.get("sql_instance", "") or "").strip()
    return inst or (sec.get("ansible_servername", "") or "").strip() or None


def _resolve_db_name_for_section(database):
    """Map a [section-header] back to the real `database` field if set."""
    found = _resolve_db_section(database)
    if not found:
        return database
    section, sec = found
    real = (sec.get("database", "") or "").strip()
    return real or section


# ---------------------------------------------------------------------------
# Intent dispatch
# ---------------------------------------------------------------------------

def _dispatch(intent):
    action = intent.get("action", "chat")
    params = intent.get("params", {}) or {}

    # Auto-fill `server` (and rewrite section-header → real DB name) from the
    # picked database. The chat UI sends the section header as `database`;
    # we look it up in databases.ini and populate both `server` and the
    # actual DB name. Works for combo_query's sql sub-query too.
    def _fill_from_db(p):
        if not isinstance(p, dict):
            return
        section = p.get("database")
        if not section:
            return
        # Always rewrite to the real DB name from the section.
        real_db = _resolve_db_name_for_section(section)
        if real_db:
            p["database"] = real_db
        if not p.get("server"):
            srv = _resolve_server_for_db(section)
            if srv:
                p["server"] = srv

    _fill_from_db(params)
    if action == "combo_query":
        _fill_from_db(params.get("sql"))

    if action == "sql_query":
        return sql_handler.run_query(
            server=params.get("server"),
            database=params.get("database"),
            raw_query=params.get("query", ""),
        )

    if action == "influx_query":
        return influx_handler.query(
            measurement=params.get("measurement", ""),
            host=params.get("host"),
            time_range=params.get("time_range", "1h"),
            aggregation=params.get("aggregation", "mean"),
        )

    if action == "combo_query":
        sql_part    = params.get("sql")    or None
        influx_part = params.get("influx") or None
        result = {}
        if sql_part:
            try:
                result["sql"] = sql_handler.run_query(
                    server=sql_part.get("server"),
                    database=sql_part.get("database"),
                    raw_query=sql_part.get("query", ""),
                )
            except UnsafeSqlError as exc:
                result["sql"] = {"error": f"Refused unsafe SQL: {exc}"}
            except Exception as exc:
                result["sql"] = {"error": str(exc)}
        if influx_part:
            try:
                result["influx"] = influx_handler.query(
                    measurement=influx_part.get("measurement", ""),
                    host=influx_part.get("host"),
                    time_range=influx_part.get("time_range", "1h"),
                    aggregation=influx_part.get("aggregation", "mean"),
                )
            except Exception as exc:
                result["influx"] = {"error": str(exc)}
        return result

    if action == "check_blocking_locks":
        return ops_handler.check_blocking_locks(server=params.get("server"))

    if action == "add_datafile_space":
        return ops_handler.add_datafile_space(
            server=params.get("server"),
            database=params.get("database"),
            logical_file=params.get("logical_file"),
            add_mb=params.get("add_mb"),
        )

    if action == "health_check":
        return ops_handler.health_check(server=params.get("server"))

    if action == "backup_status":
        return ops_handler.backup_status(server=params.get("server"))

    if action == "integrity_status":
        return ops_handler.integrity_status(server=params.get("server"))

    if action == "disk_status":
        return ops_handler.disk_status(server=params.get("server"))

    if action == "agent_jobs":
        return ops_handler.agent_jobs(
            server=params.get("server"),
            lookback_hours=params.get("lookback_hours"),
        )

    if action == "tempdb_status":
        return ops_handler.tempdb_status(server=params.get("server"))

    if action == "security_audit":
        return ops_handler.security_audit(server=params.get("server"))

    if action == "patch_level":
        return ops_handler.patch_level(server=params.get("server"))

    if action == "alwayson_status":
        return ops_handler.alwayson_status(server=params.get("server"))

    # action == "chat" or unknown
    return {"reply": params.get("reply", "I'm not sure how to help with that.")}


# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------

@app.route("/")
def index():
    return render_template("index.html",
                           provider=settings.LLM_PROVIDER,
                           model=_active_model())


@app.route("/api/servers")
def servers():
    return jsonify(_servers_metadata())


@app.route("/api/databases")
def databases():
    return jsonify(_databases_metadata())


@app.route("/api/chat", methods=["POST"])
def chat():
    payload = request.get_json(silent=True) or {}
    user_message = (payload.get("message") or "").strip()
    selected_db  = (payload.get("database") or "").strip() or None
    if not user_message:
        return jsonify({"error": "Empty message."}), 400

    # 1) classify
    try:
        intent = llm_client.classify(
            user_message,
            known_servers=_known_servers(),
            selected_database=selected_db,
        )
    except llm_client.LLMError as exc:
        return jsonify({"error": f"LLM error: {exc}"}), 502

    # If the LLM left 'database' empty for a database-aware action, fall back
    # to the dropdown selection. Skip 'chat' and 'influx_query' (no DB needed).
    if selected_db:
        params = intent.get("params") or {}
        if isinstance(params, dict) and intent.get("action") not in ("chat", "influx_query"):
            params.setdefault("database", selected_db)
        sub = (params or {}).get("sql") if isinstance(params, dict) else None
        if isinstance(sub, dict):
            sub.setdefault("database", selected_db)

    # 2) dispatch
    try:
        tool_result = _dispatch(intent)
    except UnsafeSqlError as exc:
        tool_result = {"error": f"Refused unsafe SQL: {exc}"}
    except Exception as exc:  # surface every handler failure as data, not a 500
        tool_result = {
            "error": str(exc),
            "trace": traceback.format_exc().splitlines()[-5:],
        }

    # 3) summarise (the LLM turns tool output into a friendly reply)
    if intent.get("action") == "chat":
        reply = tool_result.get("reply") or "..."
    else:
        try:
            reply = llm_client.summarize(user_message, intent, tool_result)
        except llm_client.LLMError as exc:
            reply = f"(LLM summary unavailable: {exc})"

    return jsonify({
        "reply": reply,
        "intent": intent,
        "data": tool_result,
    })


@app.route("/api/health")
def health():
    return jsonify({
        "ok": True,
        "provider": settings.LLM_PROVIDER,
        "model": _active_model(),
        "inventory": settings.INVENTORY_PATH,
        "inventory_exists": os.path.exists(settings.INVENTORY_PATH),
        "scripts_dir": settings.SCRIPTS_DIR,
        "known_servers": _known_servers(),
    })


def _active_model():
    return {
        "ollama":    settings.OLLAMA_MODEL,
        "openai":    settings.OPENAI_MODEL,
        "anthropic": settings.ANTHROPIC_MODEL,
    }.get(settings.LLM_PROVIDER, "unknown")


if __name__ == "__main__":
    # threaded=True so concurrent users / parallel Ansible runs don't block
    # each other on the dev server. For higher concurrency in production,
    # front this with gunicorn or waitress.
    app.run(
        host=settings.FLASK_HOST,
        port=settings.FLASK_PORT,
        debug=settings.FLASK_DEBUG,
        threaded=True,
    )
