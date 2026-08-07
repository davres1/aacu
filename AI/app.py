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
import logging
import os
import time
import traceback
import uuid

from flask import Flask, Response, g, jsonify, render_template, request

import settings
from llm import client as llm_client
from handlers import influx_handler
from handlers import report_pdf
from handlers.mssql  import sql_handler as mssql_sql,  ops_handler as mssql_ops
from handlers.oracle import sql_handler as oracle_sql, ops_handler as oracle_ops
from handlers.db2    import sql_handler as db2_sql,    ops_handler as db2_ops
from handlers.mysql   import sql_handler as mysql_sql,   ops_handler as mysql_ops
from handlers.mariadb     import sql_handler as mariadb_sql,     ops_handler as mariadb_ops
from handlers.postgresql  import sql_handler as postgresql_sql,  ops_handler as postgresql_ops
from handlers.sql_guard import UnsafeSqlError


# ---------------------------------------------------------------------------
# Structured logging
#
# When running under gunicorn the worker captures stdout/stderr and writes
# to the configured access/error logs. We add request-correlation ids so
# multiple concurrent users can be traced.
# ---------------------------------------------------------------------------

_log_level = os.environ.get("LOG_LEVEL", "INFO").upper()
logging.basicConfig(
    level=getattr(logging, _log_level, logging.INFO),
    format="%(asctime)s %(levelname)-7s %(name)s [%(reqid)s] %(message)s",
)

class _ReqIdFilter(logging.Filter):
    def filter(self, record):                       # noqa: D401
        record.reqid = getattr(g, "reqid", "-") if _in_request_context() else "-"
        return True

def _in_request_context():
    try:
        from flask import has_request_context
        return has_request_context()
    except Exception:                                # pragma: no cover
        return False

for h in logging.getLogger().handlers:
    h.addFilter(_ReqIdFilter())

log = logging.getLogger("aacu.app")
log.info("starting unified DBA chatbot, model=%s fallbacks=%s",
         settings.LITELLM_MODEL, settings.LITELLM_FALLBACKS)


app = Flask(__name__)


@app.before_request
def _attach_request_id():
    g.reqid = (request.headers.get("X-Request-ID")
               or uuid.uuid4().hex[:12])
    g.started = time.monotonic()


@app.after_request
def _log_response(resp):
    try:
        dur_ms = int((time.monotonic() - g.started) * 1000)
        log.info("%s %s -> %d in %dms", request.method, request.path,
                 resp.status_code, dur_ms)
        resp.headers["X-Request-ID"] = g.reqid
    except Exception:                                # never fail in after_request
        pass
    return resp


# ---------------------------------------------------------------------------
# Flavor dispatch — pick the right SQL + ops modules for a request.
# ---------------------------------------------------------------------------

def _flavor_modules(flavor):
    """Return (sql_handler_module, ops_handler_module, group_name, ini_path)."""
    f = (flavor or "").lower()
    if f == "oracle":
        return oracle_sql, oracle_ops, settings.ORACLE_GROUP, settings.ORACLE_DATABASES_INI
    if f == "db2":
        return db2_sql, db2_ops, settings.DB2_GROUP, settings.DB2_DATABASES_INI
    if f == "mysql":
        return mysql_sql, mysql_ops, settings.MYSQL_GROUP, settings.MYSQL_DATABASES_INI
    if f == "mariadb":
        return mariadb_sql, mariadb_ops, settings.MARIADB_GROUP, settings.MARIADB_DATABASES_INI
    if f == "postgresql":
        return postgresql_sql, postgresql_ops, settings.POSTGRESQL_GROUP, settings.POSTGRESQL_DATABASES_INI
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
_DB_INI_RESERVED = {"sql_servers", "oracle_servers", "db2_servers", "mysql_servers",
                    "mariadb_servers", "postgresql_servers", "DEFAULT"}


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
# Server status — CPU / memory / disk utilization from InfluxDB, with a
# rule-based verdict (under- / over- / well-utilized) and, for SQL Server,
# licensing-aware cost-reduction hints.
#
# Thresholds are conservative defaults used across VMware/CloudOps capacity
# planning: <30% mean and <60% p95 = under-utilized; >75% mean or >90% p95 =
# over-utilized; otherwise well-utilized. Adjustable via env if needed.
# ---------------------------------------------------------------------------

# SQL Server list-price constants (per 2-core pack; unchanged 2022 -> 2025).
_SQL_2CORE_ENTERPRISE = 15123
_SQL_2CORE_STANDARD   = 3945
_SQL_MIN_CORES_ENT    = 8
_SQL_MIN_CORES_STD    = 4
_SQL_SERVER_LICENCE   = 989      # Standard Server+CAL server licence
_SQL_CAL              = 230      # per user/device CAL


def _classify(mean, p95, name):
    """Map a metric's mean+p95 utilisation to an under/well/over verdict."""
    if mean is None or p95 is None:
        return {"metric": name, "verdict": "unknown", "reason": "no data points in range"}
    if mean < 30 and p95 < 60:
        return {
            "metric":  name,
            "verdict": "under",
            "reason": (f"{name} mean {mean}% / p95 {p95}% — sustained low load "
                       "leaves headroom that could be reclaimed."),
        }
    if mean > 75 or p95 > 90:
        return {
            "metric":  name,
            "verdict": "over",
            "reason": (f"{name} mean {mean}% / p95 {p95}% — running hot; "
                       "risks queueing, throttling and SLA breach."),
        }
    return {
        "metric":  name,
        "verdict": "well",
        "reason":  f"{name} mean {mean}% / p95 {p95}% — within a healthy operating band.",
    }


def _mssql_licensing_advice(cores, edition, users, has_sa, is_passive):
    """
    Apply the SQL-Server-specific right-sizing rules the user asked for.
    Returns a list of {finding, saving_estimate} dicts; empty when no
    licensing context was supplied.
    """
    edition = (edition or "").strip().lower()
    tips = []
    if not edition and not cores:
        return tips

    if edition == "standard":
        # 1. Server+CAL vs per-core break-even (~30 users on a 4-core box).
        if users is not None and cores is not None:
            per_core_cost = max(cores, _SQL_MIN_CORES_STD) / 2 * _SQL_2CORE_STANDARD
            cal_cost      = _SQL_SERVER_LICENCE + _SQL_CAL * int(users)
            if int(users) < 30 and cal_cost < per_core_cost:
                tips.append({
                    "finding": (f"With ~{users} users on a {cores}-core Standard host, "
                                f"Server+CAL (${cal_cost:,}) is cheaper than per-core "
                                f"(${per_core_cost:,})."),
                    "saving_estimate": per_core_cost - cal_cost,
                })
            elif int(users) >= 30 and per_core_cost < cal_cost:
                tips.append({
                    "finding": (f"With ~{users} users, per-core (${per_core_cost:,}) is "
                                f"cheaper than Server+CAL (${cal_cost:,})."),
                    "saving_estimate": cal_cost - per_core_cost,
                })

        # 2. Right-size vCPU: every unnecessary 2-core pack ≈ $3,945.
        if cores is not None and cores > _SQL_MIN_CORES_STD:
            tips.append({
                "finding": ("If sustained CPU headroom is >70% for 7 days, drop 2 vCPUs — "
                            f"each 2-core pack on Standard costs ${_SQL_2CORE_STANDARD:,}."),
                "saving_estimate": _SQL_2CORE_STANDARD,
            })

    if edition == "enterprise":
        # Audit whether Enterprise is actually needed.
        tips.append({
            "finding": ("1 in 3 estates run Enterprise where Standard would fit. "
                        "If you don't use multi-secondary AlwaysOn, unlimited "
                        "virtualisation, or readable secondaries, Standard 2025 "
                        "covers the old 24-core / 128GB Enterprise triggers."),
            "saving_estimate": (_SQL_2CORE_ENTERPRISE - _SQL_2CORE_STANDARD)
                                * max((cores or _SQL_MIN_CORES_ENT), _SQL_MIN_CORES_ENT) / 2,
        })
        if cores is not None and cores > _SQL_MIN_CORES_ENT:
            tips.append({
                "finding": ("Each unused 2-core pack on Enterprise costs "
                            f"${_SQL_2CORE_ENTERPRISE:,} — right-size vCPUs based on real load."),
                "saving_estimate": _SQL_2CORE_ENTERPRISE,
            })

    # 3. Passive replica licensing.
    if is_passive:
        if has_sa:
            tips.append({
                "finding": "Passive failover replica is free of charge under active Software Assurance — no additional core licences needed.",
                "saving_estimate": None,
            })
        else:
            tips.append({
                "finding": ("Passive replica without Software Assurance is billable — "
                            "either add SA or fold this workload into a licensed active node."),
                "saving_estimate": None,
            })

    return tips


def _overall_verdict(classifications):
    """Roll the per-metric verdicts into a single verdict for the host."""
    verdicts = [c["verdict"] for c in classifications]
    if "over" in verdicts:
        return "over"
    # Under-utilised only if EVERY known metric is under.
    known = [v for v in verdicts if v in ("under", "well")]
    if known and all(v == "under" for v in known):
        return "under"
    if "well" in verdicts:
        return "well"
    return "unknown"


def _server_status(flavor, host, time_range, cores, edition, users,
                   has_software_assurance, is_passive_replica):
    if not host:
        return {"error": "host is required (pass ?host=<name> or select a database)"}
    util = influx_handler.server_utilization(host=host, time_range=time_range)
    metrics = util.get("metrics", {})

    classifications = []
    for name in ("cpu", "memory", "disk"):
        stats = (metrics.get(name) or {}).get("stats") or {}
        classifications.append(_classify(stats.get("mean"), stats.get("p95"), name))

    verdict = _overall_verdict(classifications)

    # Contextual recommendations driven by the verdict.
    reasoning = []
    if verdict == "under":
        reasoning.append("All three vitals show sustained low utilisation — the host is oversized for its workload.")
        reasoning.append("Recommend: shrink vCPU / memory in the next maintenance window; consolidate onto a shared instance; or reclaim disk that hasn't grown in weeks.")
    elif verdict == "over":
        reasoning.append("At least one vital is running hot — throughput or SLA risk.")
        reasoning.append("Recommend: profile hot workload (see performance_review); add vCPU / memory; move IO-heavy files to faster storage; verify statistics & indexes.")
    elif verdict == "well":
        reasoning.append("Utilisation sits inside a healthy operating band — no immediate resize action recommended.")
    else:
        reasoning.append("Not enough data in the selected window to classify — extend time_range or check that CheckMK is feeding InfluxDB for this host.")

    licensing = []
    if flavor == "mssql":
        licensing = _mssql_licensing_advice(
            cores=cores,
            edition=edition,
            users=users,
            has_sa=has_software_assurance,
            is_passive=is_passive_replica,
        )
        if verdict == "under" and cores and (edition or "").lower() == "standard":
            reasoning.append(
                f"With Standard edition at {cores} cores under-utilised, dropping "
                f"2 vCPUs saves ${_SQL_2CORE_STANDARD:,} in list-price licensing per year.")
        if verdict == "under" and cores and (edition or "").lower() == "enterprise":
            reasoning.append(
                f"Enterprise at {cores} cores under-utilised: an audit "
                f"downgrade to Standard could save ${(_SQL_2CORE_ENTERPRISE - _SQL_2CORE_STANDARD) * max(cores, _SQL_MIN_CORES_ENT) // 2:,} per year.")

    return {
        "host":            host,
        "flavor":          flavor,
        "time_range":      util.get("time_range"),
        "verdict":         verdict,
        "classifications": classifications,
        "reasoning":       reasoning,
        "licensing":       licensing,
        "context": {
            "cores":                  cores,
            "edition":                edition,
            "users":                  users,
            "has_software_assurance": has_software_assurance,
            "is_passive_replica":     is_passive_replica,
        },
        # Raw series for the front-end to chart (CPU / memory / disk).
        "metrics": {
            name: {
                "measurement": (metrics.get(name) or {}).get("measurement"),
                "time_range":  (metrics.get(name) or {}).get("time_range"),
                "aggregation": (metrics.get(name) or {}).get("aggregation"),
                "series":      (metrics.get(name) or {}).get("series", []),
                "stats":       (metrics.get(name) or {}).get("stats"),
                "error":       (metrics.get(name) or {}).get("error"),
            } for name in ("cpu", "memory", "disk")
        },
    }


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
        if flavor in ("oracle", "db2", "mysql", "mariadb"):
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
        if flavor in ("db2", "mysql", "mariadb"):
            return ops_h.add_datafile_space(
                server=params.get("server"),
                database=params.get("database"),
                tablespace=params.get("tablespace") or params.get("logical_file"),
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
    if action == "performance_review":
        return ops_h.performance_review(server=params.get("server"))
    if action == "server_status":
        return _server_status(
            flavor=flavor,
            host=params.get("host") or params.get("server"),
            time_range=params.get("time_range") or "7d",
            cores=params.get("cores"),
            edition=params.get("edition"),
            users=params.get("users"),
            has_software_assurance=params.get("has_software_assurance"),
            is_passive_replica=bool(params.get("is_passive_replica", False)),
        )

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
        "gemini":    settings.GEMINI_MODEL,
        "oci":       settings.OCI_MODEL,
    }.get(settings.LLM_PROVIDER, settings.LITELLM_MODEL or "unknown")


def _normalize_flavor(value):
    v = (value or "").lower().strip()
    if v == "oracle":
        return "oracle"
    if v == "db2":
        return "db2"
    if v == "mysql":
        return "mysql"
    if v == "mariadb":
        return "mariadb"
    if v == "postgresql":
        return "postgresql"
    return "mssql"


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


@app.route("/api/<flavor>/report.pdf")
def report_pdf_endpoint(flavor):
    """Render the flavor's thresholds template + (optionally) inventory facts
    into a human-readable PDF and return it as an attachment."""
    flavor = _normalize_flavor(flavor)
    # Inventory is optional - a future caller can POST a JSON body containing
    # the merged ansible_local.db_inventory facts, but for the default GET we
    # produce a thresholds-only report so the button works without orchestration.
    inventory = None
    if request.method == "POST":
        payload = request.get_json(silent=True) or {}
        inventory = payload.get("inventory") or None
    try:
        pdf_bytes = report_pdf.build_report(flavor, inventory=inventory)
    except FileNotFoundError as exc:
        return jsonify({"error": str(exc)}), 404
    except Exception as exc:                              # pragma: no cover
        log.exception("PDF report generation failed")
        return jsonify({"error": f"PDF render failed: {exc}"}), 500

    stamp = time.strftime("%Y%m%d_%H%M%S")
    fname = f"{flavor}_health_report_{stamp}.pdf"
    return Response(
        pdf_bytes,
        mimetype="application/pdf",
        headers={
            "Content-Disposition": f'attachment; filename="{fname}"',
            "Cache-Control":       "no-store",
        },
    )


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
            "db2":    {"group": settings.DB2_GROUP,    "databases_ini": settings.DB2_DATABASES_INI},
            "mysql":  {"group": settings.MYSQL_GROUP,  "databases_ini": settings.MYSQL_DATABASES_INI},
            "mariadb":    {"group": settings.MARIADB_GROUP,    "databases_ini": settings.MARIADB_DATABASES_INI},
            "postgresql": {"group": settings.POSTGRESQL_GROUP, "databases_ini": settings.POSTGRESQL_DATABASES_INI},
        },
    })


if __name__ == "__main__":
    app.run(
        host=settings.FLASK_HOST,
        port=settings.FLASK_PORT,
        debug=settings.FLASK_DEBUG,
        threaded=True,
    )
