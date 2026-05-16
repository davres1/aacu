"""
Thin LLM client that selects a provider based on settings.LLM_PROVIDER.

The chatbot uses the LLM for two things:
  1. classify(user_message)  -> structured intent (JSON action + parameters)
  2. summarize(intent, data) -> natural-language reply over tool results
"""

import json
import re

import requests

import settings


SYSTEM_PROMPT = """You are a SQL Server / InfluxDB operations assistant.
Classify the user's request into ONE structured action and return STRICT JSON.

Most messages should set 'database' only — the backend resolves the matching
'server' (Windows SQL host) from databases.ini's ansible_servername field
automatically. Only emit 'server' explicitly when the user names a host that
isn't tied to one DB (e.g. "check disk on sqlprod01"). When the user has a
database selected in the UI, default the 'database' field to that value
unless the user names a different one.

Allowed actions and their parameter shapes:

  sql_query           {"server": str, "database": str|null, "query": str}
      Only SELECT statements. Use this when the user asks to look up data,
      counts, sizes, lists of databases/tables, configuration values, etc.

  influx_query        {"measurement": str, "host": str|null,
                       "time_range": str, "aggregation": "mean"|"max"|"min"|"last"|"sum"}
      Use this for CheckMK / monitoring stats: CPU, memory, disk, oracle
      tablespaces, MSSQL waits, etc. time_range examples: "1h", "24h", "7d".
      Measurement names match CheckMK service names (e.g. "MSSQL_DB_SIZE",
      "ORA_TABLESPACES", "CPU_load"). Returns time-series the UI plots.

  combo_query         {"sql":    {"server": str, "database": str|null, "query": str} | null,
                       "influx": {"measurement": str, "host": str|null,
                                  "time_range": str, "aggregation": str}    | null}
      Use this when the user wants a holistic view that needs BOTH the live
      database state (via SQL) AND the historical metrics (via InfluxDB) —
      e.g. "how is sqlprod01 doing", "give me a status of MyAppDB on
      sqlprod02 with growth trend". Either sub-query may be null but at
      least one must be set.

  check_blocking_locks  {"server": str}
      Runs DetectBlockingLocks.ps1 against the server.

  add_datafile_space    {"server": str, "database": str,
                         "logical_file": str, "add_mb": int}
      Grows a database datafile by add_mb megabytes.

  health_check          {"server": str}
      Runs the full DB health-check (instance status + inventory).

  backup_status         {"server": str}
      Reports last full/log backup age per database (uses VerifyBackups.ps1).

  integrity_status      {"server": str}
      Returns latest DBCC CHECKDB results (clean/errors/failed counts).

  disk_status           {"server": str}
      Drive % free + per-datafile free %, autogrow risks.

  agent_jobs            {"server": str, "lookback_hours": int|null}
      Failed / long-running / disabled SQL Agent jobs in the window.

  tempdb_status         {"server": str}
      tempdb usage + PAGELATCH contention + top tempdb consumers.

  security_audit        {"server": str}
      Sysadmin members, sa state, dangerous configs, weak logins,
      stale logins, orphaned users, public-role grants, TDE, cert expiry.

  patch_level           {"server": str}
      SQL build/CU age + Windows hotfix age.

  alwayson_status       {"server": str}
      AlwaysOn AG replica sync, lag, suspended databases.

  chat                  {"reply": str}
      Free-form answer when no tool is appropriate.

Return JSON only — no prose, no markdown fences. Pick exactly one action.
If the user's request is ambiguous, choose "chat" and put a clarifying
question in the reply field."""


class LLMError(RuntimeError):
    pass


# ---------------------------------------------------------------------------
# Provider implementations
# ---------------------------------------------------------------------------

def _ollama_chat(messages, max_tokens=None, temperature=None):
    url = f"{settings.OLLAMA_BASE_URL.rstrip('/')}/api/chat"
    payload = {
        "model": settings.OLLAMA_MODEL,
        "messages": messages,
        "stream": False,
        "options": {
            "temperature": settings.LLM_TEMPERATURE if temperature is None else temperature,
            "num_predict": settings.LLM_MAX_TOKENS if max_tokens is None else max_tokens,
        },
    }
    try:
        resp = requests.post(url, json=payload, timeout=settings.OLLAMA_TIMEOUT)
        resp.raise_for_status()
    except requests.RequestException as exc:
        raise LLMError(f"Ollama request failed: {exc}") from exc

    data = resp.json()
    return data.get("message", {}).get("content", "").strip()


def _openai_chat(messages, max_tokens=None, temperature=None):
    if not settings.OPENAI_API_KEY:
        raise LLMError("OPENAI_API_KEY not set")
    url = f"{settings.OPENAI_BASE_URL.rstrip('/')}/chat/completions"
    payload = {
        "model": settings.OPENAI_MODEL,
        "messages": messages,
        "temperature": settings.LLM_TEMPERATURE if temperature is None else temperature,
        "max_tokens": settings.LLM_MAX_TOKENS if max_tokens is None else max_tokens,
    }
    headers = {"Authorization": f"Bearer {settings.OPENAI_API_KEY}"}
    try:
        resp = requests.post(url, json=payload, headers=headers, timeout=settings.OLLAMA_TIMEOUT)
        resp.raise_for_status()
    except requests.RequestException as exc:
        raise LLMError(f"OpenAI request failed: {exc}") from exc
    return resp.json()["choices"][0]["message"]["content"].strip()


def _anthropic_chat(messages, max_tokens=None, temperature=None):
    if not settings.ANTHROPIC_API_KEY:
        raise LLMError("ANTHROPIC_API_KEY not set")
    system = ""
    converted = []
    for m in messages:
        if m["role"] == "system":
            system = m["content"]
        else:
            converted.append({"role": m["role"], "content": m["content"]})
    url = "https://api.anthropic.com/v1/messages"
    headers = {
        "x-api-key": settings.ANTHROPIC_API_KEY,
        "anthropic-version": "2023-06-01",
        "content-type": "application/json",
    }
    payload = {
        "model": settings.ANTHROPIC_MODEL,
        "system": system,
        "messages": converted,
        "max_tokens": settings.LLM_MAX_TOKENS if max_tokens is None else max_tokens,
        "temperature": settings.LLM_TEMPERATURE if temperature is None else temperature,
    }
    try:
        resp = requests.post(url, json=payload, headers=headers, timeout=settings.OLLAMA_TIMEOUT)
        resp.raise_for_status()
    except requests.RequestException as exc:
        raise LLMError(f"Anthropic request failed: {exc}") from exc
    return resp.json()["content"][0]["text"].strip()


_DISPATCH = {
    "ollama":    _ollama_chat,
    "openai":    _openai_chat,
    "anthropic": _anthropic_chat,
}


def chat(messages, **kwargs):
    fn = _DISPATCH.get(settings.LLM_PROVIDER)
    if fn is None:
        raise LLMError(f"Unknown LLM_PROVIDER: {settings.LLM_PROVIDER}")
    return fn(messages, **kwargs)


# ---------------------------------------------------------------------------
# Higher-level helpers
# ---------------------------------------------------------------------------

_JSON_BLOCK = re.compile(r"\{.*\}", re.DOTALL)


def classify(user_message, known_servers=None, selected_database=None):
    """Return an intent dict for the user's message."""
    context_parts = []
    if known_servers:
        context_parts.append(f"Known servers in inventory: {', '.join(known_servers)}")
    if selected_database:
        context_parts.append(
            f"The user currently has database '{selected_database}' selected in the UI. "
            "Default the 'database' field to this value unless the user names a different one."
        )
    context = ("\n\n" + "\n".join(context_parts)) if context_parts else ""

    messages = [
        {"role": "system", "content": SYSTEM_PROMPT + context},
        {"role": "user", "content": user_message},
    ]
    raw = chat(messages)

    match = _JSON_BLOCK.search(raw)
    if not match:
        return {"action": "chat", "params": {"reply": raw or "Sorry, I didn't catch that."}}
    try:
        parsed = json.loads(match.group(0))
    except json.JSONDecodeError:
        return {"action": "chat", "params": {"reply": raw}}

    # Tolerate both {"action": "...", "params": {...}} and flat {"action": "...", ...}.
    if "action" in parsed and "params" in parsed:
        return parsed
    if "action" in parsed:
        action = parsed.pop("action")
        return {"action": action, "params": parsed}
    return {"action": "chat", "params": {"reply": raw}}


def summarize(user_message, intent, tool_result):
    """Ask the LLM to turn raw tool output into a friendly answer."""
    messages = [
        {"role": "system",
         "content": "You are a database operations assistant. "
                    "Summarize the tool result for the user in clear, concise prose. "
                    "If the result has tabular data, render a short markdown table. "
                    "Never invent values not present in the data."},
        {"role": "user",
         "content": (f"User asked: {user_message}\n\n"
                     f"Action taken: {intent.get('action')}\n"
                     f"Parameters: {json.dumps(intent.get('params', {}))}\n\n"
                     f"Tool result:\n{json.dumps(tool_result, default=str)[:6000]}")},
    ]
    try:
        return chat(messages, temperature=0.2)
    except LLMError as exc:
        # Even if the LLM is unreachable, we still want to surface the data.
        return f"(LLM summary unavailable: {exc})\n\n```json\n{json.dumps(tool_result, default=str, indent=2)[:2000]}\n```"
