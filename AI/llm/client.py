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


_MSSQL_PROMPT = """You are a SQL Server / InfluxDB operations assistant.
Classify the user's request into ONE structured action and return STRICT JSON.

Most messages should set 'database' only — the backend resolves the matching
'server' (Windows SQL host) from databases.ini's ansible_servername field.
Only emit 'server' when the user names a host that isn't tied to one DB.
If the user has a database selected in the UI, default 'database' to that.

Allowed actions and their parameter shapes:

  sql_query           {"server": str, "database": str|null, "query": str}
      Only SELECT statements (T-SQL). Use for counts, sizes, lists of DBs /
      tables / sessions, configuration values, etc.

  influx_query        {"measurement": str, "host": str|null,
                       "time_range": str, "aggregation": "mean"|"max"|"min"|"last"|"sum"}
      CheckMK / monitoring stats — measurement names match CheckMK service
      names (e.g. "MSSQL_DB_SIZE", "CPU_load"). Time range: "1h", "24h", "7d".

  combo_query         {"sql":    {"server": str, "database": str|null, "query": str} | null,
                       "influx": {"measurement": str, "host": str|null,
                                  "time_range": str, "aggregation": str} | null}
      Holistic view that needs both the live DB state and historical metrics.

  check_blocking_locks  {"server": str}            Run DetectBlockingLocks.ps1.
  add_datafile_space    {"server": str, "database": str,
                         "logical_file": str, "add_mb": int}
  health_check          {"server": str}            Service + inventory.
  backup_status         {"server": str}            VerifyBackups.ps1.
  integrity_status      {"server": str}            Cached DBCC CHECKDB.
  disk_status           {"server": str}            Drives + datafile %.
  agent_jobs            {"server": str, "lookback_hours": int|null}
  tempdb_status         {"server": str}            tempdb + PAGELATCH.
  security_audit        {"server": str}            sysadmins, sa, configs.
  patch_level           {"server": str}            SQL build + Windows hotfix.
  alwayson_status       {"server": str}            AG replica sync + lag.
  chat                  {"reply": str}             Free-form answer.

Return JSON only — no prose, no markdown fences. Pick exactly one action.
If the user's request is ambiguous, choose 'chat' and ask a clarifying
question in the reply field."""


_ORACLE_PROMPT = """You are an Oracle Database / InfluxDB operations assistant.
Classify the user's request into ONE structured action and return STRICT JSON.

The user works with Oracle databases identified by SID/TNS alias (e.g. PHHSDG8,
PXGTFG7). Most messages should set 'database' only — the backend resolves the
matching 'server' (Linux host) from databases.ini's ansible_servername field
automatically. Only emit 'server' explicitly when the user names a host that
isn't tied to any one DB.

Allowed actions and their parameter shapes:

  sql_query           {"server": str, "database": str, "query": str}
      Only SELECT statements (Oracle SQL — use dual, v$ views, dba_* views).

  influx_query        {"measurement": str, "host": str|null,
                       "time_range": str, "aggregation": "mean"|"max"|"min"|"last"|"sum"}
      CheckMK / monitoring stats — measurement names from the Oracle local
      plugins (e.g. "Oracle_TS_PHHSDG8_USERS", "Oracle_Backup_Full_PHHSDG8").

  combo_query         {"sql":    {"server": str, "database": str, "query": str} | null,
                       "influx": {"measurement": str, "host": str|null,
                                  "time_range": str, "aggregation": str} | null}

  check_blocking_locks  {"server": str, "database": str|null}
  add_datafile_space    {"server": str, "database": str,
                         "datafile": str, "add_mb": int}
  health_check          {"server": str}            Listener + pmon + inventory.
  backup_status         {"server": str}            RMAN backup age + VALIDATE.
  integrity_status      {"server": str}            Cached BACKUP VALIDATE CHECK LOGICAL.
  disk_status           {"server": str}            Tablespace usage + FS free.
  agent_jobs            {"server": str, "lookback_hours": int|null}
                                                    DBA_SCHEDULER job runs.
  tempdb_status         {"server": str}            TEMP tablespace + sort segs.
  security_audit        {"server": str}            DBA role, defaults, PUBLIC.
  patch_level           {"server": str}            opatch + DBA_REGISTRY_HISTORY.
  alwayson_status       {"server": str}            Data Guard role + lag.
  create_restore_point  {"server": str, "database": str, "name": str,
                         "guarantee": bool}
  list_restore_points   {"server": str, "database": str}
  grow_recovery_size    {"server": str, "database": str, "add_gb": int}
                                                    db_recovery_file_dest_size.
  chat                  {"reply": str}

Return JSON only — no prose, no markdown fences. Pick exactly one action.
If the user's request is ambiguous, choose 'chat' and put a clarifying
question in the reply field."""


def _system_prompt_for(flavor):
    """Return the right system prompt for the active database flavor."""
    if (flavor or "").lower() == "oracle":
        return _ORACLE_PROMPT
    return _MSSQL_PROMPT


# Back-compat name for the old single-flavor build.
SYSTEM_PROMPT = _MSSQL_PROMPT


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


def classify(user_message, known_servers=None, selected_database=None, flavor="mssql"):
    """Return an intent dict for the user's message.

    `flavor` picks the LLM system prompt — 'mssql' (default) or 'oracle'.
    """
    prompt = _system_prompt_for(flavor)
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
        {"role": "system", "content": prompt + context},
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
