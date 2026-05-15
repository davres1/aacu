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

_PREFERRED_GROUPS = ("sql_servers", "mssql", "oracle", "databases", "db")


def _known_servers():
    """Pull host names from the Ansible inventory at settings.INVENTORY_PATH.

    Prefers the DB-flavoured groups but falls back to every host in the file
    so we still work with a generic /etc/ansible/hosts.
    """
    if not os.path.exists(settings.INVENTORY_PATH):
        return []
    parser = configparser.ConfigParser(allow_no_value=True, delimiters=("=",))
    parser.optionxform = str
    try:
        parser.read(settings.INVENTORY_PATH)
    except configparser.Error:
        return []

    def _hosts_in(section):
        out = []
        for raw in parser[section].keys():
            if not raw or raw.startswith((";", "#")):
                continue
            # Strip Ansible inline vars: "host01 ansible_user=svc" -> "host01"
            host = raw.split()[0].strip()
            if host and not host.endswith(":vars"):
                out.append(host)
        return out

    preferred = []
    for grp in _PREFERRED_GROUPS:
        if grp in parser:
            preferred.extend(_hosts_in(grp))
    if preferred:
        return sorted(set(preferred))

    all_hosts = []
    for section in parser.sections():
        if section.endswith(":vars") or section.endswith(":children"):
            continue
        all_hosts.extend(_hosts_in(section))
    return sorted(set(all_hosts))


# ---------------------------------------------------------------------------
# Intent dispatch
# ---------------------------------------------------------------------------

def _dispatch(intent):
    action = intent.get("action", "chat")
    params = intent.get("params", {}) or {}

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
    return jsonify({"servers": _known_servers()})


@app.route("/api/chat", methods=["POST"])
def chat():
    payload = request.get_json(silent=True) or {}
    user_message = (payload.get("message") or "").strip()
    if not user_message:
        return jsonify({"error": "Empty message."}), 400

    # 1) classify
    try:
        intent = llm_client.classify(user_message, known_servers=_known_servers())
    except llm_client.LLMError as exc:
        return jsonify({"error": f"LLM error: {exc}"}), 502

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
