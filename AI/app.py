"""
Unified DB Info Chatbot — serves both SQL Server and Oracle.

The UI shows a tab at the top (SQL Server / Oracle). Every API call carries
a `flavor` field (mssql | oracle); the dispatcher routes to the right
handler module:

    handlers.mssql   -> SQL Server (Windows hosts, dbatools, T-SQL)
    handlers.oracle  -> Oracle     (Linux hosts, sqlplus, PL/SQL)

InfluxDB queries are flavor-agnostic — CheckMK feeds the same database.
"""

import configparser
import os
import traceback

from flask import Flask, jsonify, render_template, request

import settings
from llm import client as llm_client
from handlers import influx_handler
from handlers.mssql  import sql_handler as mssql_sql,  ops_handler as mssql_ops
from handlers.oracle import sql_handler as oracle_sql, ops_handler as oracle_ops
from handlers.sql_guard import UnsafeSqlError


app = Flask(__name__)


# ---------------------------------------------------------------------------
# Flavor dispatch — pick the right SQL + ops modules for a request.
# ---------------------------------------------------------------------------

def _flavor_modules(flavor):
    """Return (sql_handler_module, ops_handler_module, group_name, ini_path)."""
    if (flavor or "").lower() == "oracle":
        return oracle_sql, oracle_ops, settings.ORACLE_GROUP, settings.ORACLE_DATABASES_INI
    return mssql_sql, mssql_ops, settings.MSSQL_GROUP, settings.MSSQL_DATABASES_INI


# ---------------------------------------------------------------------------
# Inventory + databases.ini readers
# ---------------------------------------------------------------------------

def _read_inventory():
    if not os.path.exists(settings.INVENTORY_PATH):
        return None
    parser = configparser.ConfigParser(allow_no_value=True, delimiters=("=",),
                                       interpolation=None)
    parser.optionxform = str
    try:
        parser.read(settings.INVENTORY_PATH)
    except configparser.Error:
        return None
    return parser


def _hosts_in_section(parser, section):
    if section not in parser:
        return []
    out = []
    for raw in parser[section].keys():
        if not raw or raw.startswith((";", "#")):
            continue
        host = raw.split()[0].strip()
        if host and not host.endswith(":vars"):
            out.append(host)
    return out


def _known_servers(flavor):
    """Hosts in the flavor's [sql_servers] / [oracle_servers] group."""
    parser = _read_inventory()
    if parser is None:
        return []
    _, _, group, _ = _flavor_modules(flavor)
    return sorted(set(_hosts_in_section(parser, group)))


def _read_databases_ini(flavor):
    _, _, _, path = _flavor_modules(flavor)
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


# Sections that aren't actual databases.
_DB_INI_RESERVED = {"sql_servers", "oracle_servers", "DEFAULT"}


def _databases_metadata(flavor):
    parser, path = _read_databases_ini(flavor)
    inv_hosts = set(_known_servers(flavor))

    if parser is None:
        return {
            "flavor": flavor,
            "databases": [],
            "databases_ini": path,
            "databases_ini_exists": False,
            "hint": f"databases.ini not found at {path}",
        }

    rows = []
    missing = 0
    for section in parser.sections():
        if section in _DB_INI_RESERVED:
            continue
        get = parser[section].get
        ans = (get("ansible_servername", "") or "").strip()
        in_inv = (ans in inv_hosts) if ans else False
        if not ans or not in_inv:
            missing += 1
        rows.append({
            "name":               section,
            "ansible_servername": ans or None,
            "in_inventory":       in_inv,
            "sql_instance":       (get("sql_instance", "") or "").strip() or None,
            "database":           (get("database", "") or section).strip(),
            "emaillist":          (get("emaillist", "") or "").strip() or None,
            "lastupdated":        (get("lastupdated", "") or "").strip() or None,
        })
    rows.sort(key=lambda r: r["name"].lower())
    return {
        "flavor": flavor,
        "databases": rows,
        "databases_ini": path,
        "databases_ini_exists": True,
        "inventory": settings.INVENTORY_PATH,
        "missing_server_count": missing,
        "hint": None if rows else "databases.ini contains no DB sections",
    }


def _resolve_db_section(flavor, database):
    if not database:
        return None
    parser, _ = _read_databases_ini(flavor)
    if parser is None:
        return None
    target_lc = database.strip().lower()
    for section in parser.sections():
        if section in _DB_INI_RESERVED:
            continue
        if section.lower() == target_lc:
            return section, parser[section]
    return None


def _resolve_server_for_db(flavor, database):
    found = _resolve_db_section(flavor, database)
    if not found:
        return None
    _, sec = found
    return (sec.get("ansible_servername", "") or "").strip() or None


def _resolve_db_name_for_section(flavor, database):
    found = _resolve_db_section(flavor, database)
    if not found:
        return database
    section, sec = found
    real = (sec.get("database", "") or "").strip()
    return real or section


# ---------------------------------------------------------------------------
# Intent dispatch
# ---------------------------------------------------------------------------

def _dispatch(flavor, intent):
    sql_h, ops_h, _, _ = _flavor_modules(flavor)
    action = intent.get("action", "chat")
    params = intent.get("params", {}) or {}

    # Auto-fill server from the picked database; rewrite section header to
    # the real DB name. Same hook applies to combo_query's sql sub-query.
    def _fill_from_db(p):
        if not isinstance(p, dict):
            return
        section = p.get("database")
        if not section:
            return
        real_db = _resolve_db_name_for_section(flavor, section)
        if real_db:
            p["database"] = real_db
        if not p.get("server"):
            srv = _resolve_server_for_db(flavor, section)
            if srv:
                p["server"] = srv

    _fill_from_db(params)
    if action == "combo_query":
        _fill_from_db(params.get("sql"))

    if action == "sql_query":
        return sql_h.run_query(
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
                result["sql"] = sql_h.run_query(
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
        if flavor == "oracle":
            return ops_h.check_blocking_locks(
                server=params.get("server"),
                database=params.get("database"),
            )
        return ops_h.check_blocking_locks(server=params.get("server"))

    if action == "add_datafile_space":
        if flavor == "oracle":
            datafile = params.get("datafile") or params.get("logical_file")
            return ops_h.add_datafile_space(
                server=params.get("server"),
                database=params.get("database"),
                datafile=datafile,
                add_mb=params.get("add_mb"),
            )
        return ops_h.add_datafile_space(
            server=params.get("server"),
            database=params.get("database"),
            logical_file=params.get("logical_file") or params.get("datafile"),
            add_mb=params.get("add_mb"),
        )

    if action == "health_check":
        return ops_h.health_check(server=params.get("server"))
    if action == "backup_status":
        return ops_h.backup_status(server=params.get("server"))
    if action == "integrity_status":
        return ops_h.integrity_status(server=params.get("server"))
    if action == "disk_status":
        return ops_h.disk_status(server=params.get("server"))
    if action == "agent_jobs":
        return ops_h.agent_jobs(
            server=params.get("server"),
            lookback_hours=params.get("lookback_hours"),
        )
    if action == "tempdb_status":
        return ops_h.tempdb_status(server=params.get("server"))
    if action == "security_audit":
        return ops_h.security_audit(server=params.get("server"))
    if action == "patch_level":
        return ops_h.patch_level(server=params.get("server"))
    if action == "alwayson_status":
        return ops_h.alwayson_status(server=params.get("server"))

    # Oracle-only intents
    if action == "create_restore_point" and flavor == "oracle":
        return ops_h.create_restore_point(
            server=params.get("server"),
            database=params.get("database"),
            name=params.get("name"),
            guarantee=bool(params.get("guarantee", False)),
        )
    if action == "list_restore_points" and flavor == "oracle":
        return ops_h.list_restore_points(
            server=params.get("server"),
            database=params.get("database"),
        )
    if action == "grow_recovery_size" and flavor == "oracle":
        return ops_h.grow_recovery_dest(
            server=params.get("server"),
            database=params.get("database"),
            add_gb=params.get("add_gb"),
        )

    return {"reply": params.get("reply", "I'm not sure how to help with that.")}


# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------

def _active_model():
    return {
        "ollama":    settings.OLLAMA_MODEL,
        "openai":    settings.OPENAI_MODEL,
        "anthropic": settings.ANTHROPIC_MODEL,
    }.get(settings.LLM_PROVIDER, "unknown")


def _normalize_flavor(value):
    return "oracle" if (value or "").lower().strip() == "oracle" else "mssql"


@app.route("/")
def index():
    return render_template("index.html",
                           provider=settings.LLM_PROVIDER,
                           model=_active_model())


@app.route("/api/<flavor>/databases")
def databases(flavor):
    return jsonify(_databases_metadata(_normalize_flavor(flavor)))


@app.route("/api/<flavor>/servers")
def servers(flavor):
    flavor = _normalize_flavor(flavor)
    _, _, group, _ = _flavor_modules(flavor)
    return jsonify({
        "flavor": flavor,
        "group":  group,
        "servers": _known_servers(flavor),
        "inventory": settings.INVENTORY_PATH,
        "inventory_exists": os.path.exists(settings.INVENTORY_PATH),
    })


@app.route("/api/chat", methods=["POST"])
def chat():
    payload      = request.get_json(silent=True) or {}
    user_message = (payload.get("message") or "").strip()
    flavor       = _normalize_flavor(payload.get("flavor"))
    selected_db  = (payload.get("database") or "").strip() or None
    if not user_message:
        return jsonify({"error": "Empty message."}), 400

    # 1) classify
    try:
        intent = llm_client.classify(
            user_message,
            known_servers=_known_servers(flavor),
            selected_database=selected_db,
            flavor=flavor,
        )
    except llm_client.LLMError as exc:
        return jsonify({"error": f"LLM error: {exc}"}), 502

    # Default the database from the picker for DB-aware intents.
    if selected_db:
        params = intent.get("params") or {}
        if isinstance(params, dict) and intent.get("action") not in ("chat", "influx_query"):
            params.setdefault("database", selected_db)
        sub = (params or {}).get("sql") if isinstance(params, dict) else None
        if isinstance(sub, dict):
            sub.setdefault("database", selected_db)

    # 2) dispatch
    try:
        tool_result = _dispatch(flavor, intent)
    except UnsafeSqlError as exc:
        tool_result = {"error": f"Refused unsafe SQL: {exc}"}
    except Exception as exc:
        tool_result = {
            "error": str(exc),
            "trace": traceback.format_exc().splitlines()[-5:],
        }

    # 3) summarise
    if intent.get("action") == "chat":
        reply = tool_result.get("reply") or "..."
    else:
        try:
            reply = llm_client.summarize(user_message, intent, tool_result)
        except llm_client.LLMError as exc:
            reply = f"(LLM summary unavailable: {exc})"

    return jsonify({
        "flavor": flavor,
        "reply":  reply,
        "intent": intent,
        "data":   tool_result,
    })


@app.route("/api/health")
def health():
    return jsonify({
        "ok": True,
        "provider": settings.LLM_PROVIDER,
        "model": _active_model(),
        "inventory": settings.INVENTORY_PATH,
        "inventory_exists": os.path.exists(settings.INVENTORY_PATH),
        "flavors": {
            "mssql":  {"group": settings.MSSQL_GROUP,  "databases_ini": settings.MSSQL_DATABASES_INI},
            "oracle": {"group": settings.ORACLE_GROUP, "databases_ini": settings.ORACLE_DATABASES_INI},
        },
    })


if __name__ == "__main__":
    app.run(
        host=settings.FLASK_HOST,
        port=settings.FLASK_PORT,
        debug=settings.FLASK_DEBUG,
        threaded=True,
    )
