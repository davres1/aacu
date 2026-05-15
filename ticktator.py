#!/usr/bin/env python3
"""
ticktator.py — CheckMK notification → ServiceNow incident bridge.

Install on the CheckMK / OMD site host:

    cp ticktator.py /omd/sites/<SITE>/local/share/check_mk/notifications/ticktator
    chmod +x       /omd/sites/<SITE>/local/share/check_mk/notifications/ticktator

Then in WATO → Notifications, add a rule that invokes the "ticktator" script
on CRITICAL service events / DOWN host events. CheckMK passes context to the
script via environment variables prefixed with NOTIFY_ (see ENV section).

Configuration is read from env vars (override per CheckMK rule or set in
/etc/default/ticktator and source it from the CheckMK site shell):

    SNOW_INSTANCE          dev12345.service-now.com           (required)
    SNOW_USER / SNOW_PASS  basic-auth credentials             (required)
        - or -
    SNOW_OAUTH_TOKEN       OAuth bearer token (preferred)
    SNOW_TABLE             incident                           (default: incident)
    SNOW_ASSIGNMENT_GROUP  Database Operations
    SNOW_CALLER_ID         checkmk_svc
    SNOW_CMDB_CI_FIELD     cmdb_ci                            (default cmdb_ci)
    SNOW_DEFAULT_IMPACT    2          (1-high, 2-medium, 3-low)
    SNOW_DEFAULT_URGENCY   2
    TICKTATOR_DEDUP_HOURS  4          (drop duplicates for same host/service)
    TICKTATOR_STATE_FILE   /var/lib/ticktator/state.json
    TICKTATOR_LOG          /var/log/ticktator.log
    TICKTATOR_DRY_RUN      0          (set to 1 to log payload but not POST)

Exit codes:
    0  ticket created (or skipped as duplicate)
    1  config error
    2  HTTP / ServiceNow error
    3  unrecoverable runtime error

No third-party deps: uses stdlib only so it runs anywhere CheckMK does.
"""

from __future__ import annotations

import base64
import json
import os
import socket
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

LOG_PATH = os.environ.get("TICKTATOR_LOG", "/var/log/ticktator.log")
STATE_PATH = os.environ.get("TICKTATOR_STATE_FILE", "/var/lib/ticktator/state.json")
DEDUP_HOURS = int(os.environ.get("TICKTATOR_DEDUP_HOURS", "4"))
DRY_RUN = os.environ.get("TICKTATOR_DRY_RUN", "0") == "1"


def log(message: str) -> None:
    stamp = time.strftime("%Y-%m-%d %H:%M:%S")
    line = f"[{stamp}] {message}\n"
    sys.stderr.write(line)
    try:
        Path(LOG_PATH).parent.mkdir(parents=True, exist_ok=True)
        with open(LOG_PATH, "a", encoding="utf-8") as fh:
            fh.write(line)
    except OSError:
        pass


def env(name: str, default: str = "") -> str:
    return os.environ.get(name, default)


def must(name: str) -> str:
    value = env(name)
    if not value:
        log(f"FATAL: missing required env var {name}")
        sys.exit(1)
    return value


# ---------------------------------------------------------------------------
# Dedup state — a tiny JSON cache keyed by host+service.
# ---------------------------------------------------------------------------

def load_state() -> dict:
    try:
        with open(STATE_PATH, "r", encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, json.JSONDecodeError):
        return {}


def save_state(state: dict) -> None:
    try:
        Path(STATE_PATH).parent.mkdir(parents=True, exist_ok=True)
        tmp = STATE_PATH + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(state, fh)
        os.replace(tmp, STATE_PATH)
    except OSError as exc:
        log(f"WARN: could not persist state: {exc}")


def is_duplicate(state: dict, key: str) -> str | None:
    """Return the previously created incident number if within dedup window."""
    entry = state.get(key)
    if not entry:
        return None
    last = entry.get("ts", 0)
    if (time.time() - last) > DEDUP_HOURS * 3600:
        return None
    return entry.get("number")


def remember(state: dict, key: str, number: str) -> None:
    state[key] = {"ts": time.time(), "number": number}
    # Prune anything older than 24h to keep the file small.
    cutoff = time.time() - 86400
    for k in list(state.keys()):
        if state[k].get("ts", 0) < cutoff:
            state.pop(k, None)
    save_state(state)


# ---------------------------------------------------------------------------
# Severity mapping
# ---------------------------------------------------------------------------

# CheckMK gives us NOTIFY_SERVICESTATE in {OK, WARN, CRIT, UNKNOWN}
# and NOTIFY_HOSTSTATE in {UP, DOWN, UNREACHABLE}.
SERVICE_STATE_MAP = {
    "CRITICAL": ("1", "1"),  # (impact, urgency) — both high
    "CRIT":     ("1", "1"),
    "DOWN":     ("1", "1"),
    "UNREACHABLE": ("1", "2"),
    "WARNING":  ("2", "2"),
    "WARN":     ("2", "2"),
    "UNKNOWN":  ("2", "3"),
}


def severity_for(state: str) -> tuple[str, str]:
    impact, urgency = SERVICE_STATE_MAP.get(
        state.upper(),
        (env("SNOW_DEFAULT_IMPACT", "2"), env("SNOW_DEFAULT_URGENCY", "2")),
    )
    return impact, urgency


def is_critical(notification_type: str, service_state: str, host_state: str) -> bool:
    """Open a ticket only for PROBLEM notifications on CRITICAL / DOWN states."""
    if notification_type.upper() not in {"PROBLEM", "RECOVERY", "FLAPPINGSTART"}:
        # RECOVERY is allowed through so we can resolve open tickets later.
        return False
    if service_state and service_state.upper() in {"CRITICAL", "CRIT"}:
        return True
    if host_state and host_state.upper() in {"DOWN", "UNREACHABLE"}:
        return True
    return False


# ---------------------------------------------------------------------------
# CheckMK context → ServiceNow payload
# ---------------------------------------------------------------------------

def build_payload(ctx: dict) -> dict:
    host = ctx.get("HOSTNAME", "unknown-host")
    service = ctx.get("SERVICEDESC", "")
    service_state = ctx.get("SERVICESTATE", "")
    host_state = ctx.get("HOSTSTATE", "")
    output = ctx.get("SERVICEOUTPUT") or ctx.get("HOSTOUTPUT", "")
    long_output = ctx.get("LONGSERVICEOUTPUT") or ctx.get("LONGHOSTOUTPUT", "")
    notify_type = ctx.get("NOTIFICATIONTYPE", "PROBLEM")
    ts = ctx.get("SHORTDATETIME", time.strftime("%Y-%m-%d %H:%M:%S"))
    site = ctx.get("OMD_SITE", "")
    perf = ctx.get("SERVICEPERFDATA", "")

    state_for_severity = service_state or host_state
    impact, urgency = severity_for(state_for_severity)

    subject_state = service_state or host_state or "ALERT"
    short_desc = f"[{subject_state}] {host}"
    if service:
        short_desc += f" / {service}"

    description_lines = [
        f"CheckMK alert from {socket.gethostname()} (site: {site or 'n/a'})",
        f"Notification type : {notify_type}",
        f"Host              : {host}",
    ]
    if service:
        description_lines.append(f"Service           : {service}")
    description_lines += [
        f"State             : {state_for_severity}",
        f"When              : {ts}",
        "",
        "Output:",
        (output or "(no output)").strip(),
    ]
    if long_output:
        description_lines += ["", "Details:", long_output.strip()]
    if perf:
        description_lines += ["", f"Perfdata: {perf}"]

    payload = {
        "short_description": short_desc[:160],
        "description": "\n".join(description_lines),
        "impact": impact,
        "urgency": urgency,
        "caller_id": env("SNOW_CALLER_ID", "checkmk_svc"),
        "assignment_group": env("SNOW_ASSIGNMENT_GROUP", "Database Operations"),
        "category": env("SNOW_CATEGORY", "Database"),
        "subcategory": env("SNOW_SUBCATEGORY", "Monitoring"),
        "u_source": "checkmk",
        "u_checkmk_host": host,
        "u_checkmk_service": service,
        "u_checkmk_state": state_for_severity,
    }

    # Optional CI link — let an env var pick the field that holds the host name
    # in CMDB (some shops use cmdb_ci_name, others cmdb_ci).
    ci_field = env("SNOW_CMDB_CI_FIELD", "cmdb_ci")
    if ci_field:
        payload[ci_field] = host

    return payload


# ---------------------------------------------------------------------------
# ServiceNow REST call
# ---------------------------------------------------------------------------

def snow_request(method: str, path: str, body: dict | None = None) -> dict:
    instance = must("SNOW_INSTANCE").rstrip("/")
    if not instance.startswith("http"):
        instance = f"https://{instance}"
    url = f"{instance}/api/now/table/{path.lstrip('/')}"

    data = json.dumps(body).encode("utf-8") if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Accept", "application/json")
    req.add_header("Content-Type", "application/json")

    token = env("SNOW_OAUTH_TOKEN")
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    else:
        user = must("SNOW_USER")
        pw = must("SNOW_PASS")
        basic = base64.b64encode(f"{user}:{pw}".encode()).decode()
        req.add_header("Authorization", f"Basic {basic}")

    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            payload = resp.read().decode("utf-8")
            if resp.status >= 300:
                raise urllib.error.HTTPError(url, resp.status, payload, resp.headers, None)
            return json.loads(payload) if payload else {}
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace") if hasattr(exc, "read") else ""
        log(f"HTTP {exc.code} from ServiceNow: {detail[:500]}")
        raise


def create_incident(payload: dict) -> dict:
    table = env("SNOW_TABLE", "incident")
    if DRY_RUN:
        log(f"DRY_RUN: would POST to {table}: {json.dumps(payload)[:600]}")
        return {"result": {"number": "DRY-RUN", "sys_id": "0" * 32}}
    return snow_request("POST", table, payload)


def resolve_incident(number: str, note: str) -> None:
    """Best-effort resolve when CheckMK sends a RECOVERY notification."""
    table = env("SNOW_TABLE", "incident")
    found = snow_request("GET", f"{table}?sysparm_query=number={number}&sysparm_limit=1")
    rows = (found or {}).get("result") or []
    if not rows:
        log(f"resolve: incident {number} not found")
        return
    sys_id = rows[0]["sys_id"]
    body = {
        "state": "6",            # Resolved
        "close_code": "Solved (Permanently)",
        "close_notes": note,
    }
    if DRY_RUN:
        log(f"DRY_RUN: would PATCH {table}/{sys_id}: {body}")
        return
    snow_request("PATCH", f"{table}/{sys_id}", body)


# ---------------------------------------------------------------------------
# Main entrypoint
# ---------------------------------------------------------------------------

def read_context() -> dict:
    """Collect every NOTIFY_* variable CheckMK exported into the env."""
    ctx = {}
    for key, value in os.environ.items():
        if key.startswith("NOTIFY_"):
            ctx[key[len("NOTIFY_"):]] = value
    # CheckMK also exposes a few extras useful for context.
    for extra in ("OMD_SITE", "OMD_ROOT"):
        if extra in os.environ:
            ctx[extra] = os.environ[extra]
    return ctx


def main() -> int:
    ctx = read_context()
    if not ctx:
        log("FATAL: no NOTIFY_* env vars present — not invoked by CheckMK?")
        return 3

    notify_type = ctx.get("NOTIFICATIONTYPE", "PROBLEM")
    host = ctx.get("HOSTNAME", "")
    service = ctx.get("SERVICEDESC", "")
    service_state = ctx.get("SERVICESTATE", "")
    host_state = ctx.get("HOSTSTATE", "")

    dedup_key = f"{host}|{service}".lower()
    state = load_state()

    # Recovery: try to resolve any incident we opened for this key.
    if notify_type.upper() == "RECOVERY":
        prior = state.get(dedup_key, {}).get("number")
        if prior and prior != "DRY-RUN":
            try:
                resolve_incident(prior, f"CheckMK RECOVERY for {host}/{service or 'host'}")
                log(f"resolved {prior} after RECOVERY of {dedup_key}")
            except Exception as exc:  # noqa: BLE001
                log(f"resolve failed for {prior}: {exc}")
                return 2
        state.pop(dedup_key, None)
        save_state(state)
        return 0

    if not is_critical(notify_type, service_state, host_state):
        log(f"skip: {notify_type} {host}/{service} state={service_state or host_state} is not critical")
        return 0

    existing = is_duplicate(state, dedup_key)
    if existing:
        log(f"skip: duplicate within {DEDUP_HOURS}h, existing incident {existing} for {dedup_key}")
        return 0

    payload = build_payload(ctx)
    try:
        resp = create_incident(payload)
    except urllib.error.URLError as exc:
        log(f"network error reaching ServiceNow: {exc}")
        return 2
    except Exception as exc:  # noqa: BLE001
        log(f"unexpected error creating incident: {exc}")
        return 3

    number = (resp.get("result") or {}).get("number", "")
    sys_id = (resp.get("result") or {}).get("sys_id", "")
    log(f"opened {number or '?'} (sys_id={sys_id}) for {dedup_key} state={service_state or host_state}")
    if number:
        remember(state, dedup_key, number)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except SystemExit:
        raise
    except Exception as exc:  # noqa: BLE001
        log(f"FATAL: unhandled exception: {exc}")
        sys.exit(3)
