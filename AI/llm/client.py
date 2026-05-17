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
# LiteLLM-backed completion call.
#
# LiteLLM speaks ollama / openai / anthropic / azure / bedrock / gemini /
# vllm / etc. behind one .completion() API. Provider routing is driven by
# the model prefix (e.g. "anthropic/claude-…", "openai/gpt-…", "ollama/…").
#
# We push API keys / base URLs into the env vars LiteLLM expects, then call
# completion_with_fallbacks so a stalled Ollama silently falls back to an
# OpenAI/Anthropic key if one is configured.
# ---------------------------------------------------------------------------

import logging
import os
import time

try:
    import litellm
    from litellm import completion_with_fallbacks
    _LITELLM_OK = True
except ImportError:                # pragma: no cover - install gap
    _LITELLM_OK = False

_log = logging.getLogger("aacu.llm")


def _prime_litellm_env_once():
    """Mirror settings → env vars that LiteLLM picks up natively."""
    if getattr(_prime_litellm_env_once, "_done", False):
        return
    if settings.OPENAI_API_KEY:
        os.environ.setdefault("OPENAI_API_KEY", settings.OPENAI_API_KEY)
    if settings.OPENAI_BASE_URL and settings.OPENAI_BASE_URL != "https://api.openai.com/v1":
        os.environ.setdefault("OPENAI_API_BASE", settings.OPENAI_BASE_URL)
    if settings.ANTHROPIC_API_KEY:
        os.environ.setdefault("ANTHROPIC_API_KEY", settings.ANTHROPIC_API_KEY)
    if settings.OLLAMA_BASE_URL:
        os.environ.setdefault("OLLAMA_API_BASE", settings.OLLAMA_BASE_URL)

    if _LITELLM_OK:
        litellm.drop_params = True                # silently drop unsupported params per-provider
        litellm.suppress_debug_info = not settings.LITELLM_DEBUG
        litellm.set_verbose = settings.LITELLM_DEBUG
        # Tighten the global timeout/retry defaults too.
        litellm.request_timeout = settings.LITELLM_TIMEOUT

    _prime_litellm_env_once._done = True


def chat(messages, max_tokens=None, temperature=None):
    """Send a chat completion through LiteLLM. Returns the assistant text.

    Raises LLMError on connection / authentication / shape failures.
    """
    if not _LITELLM_OK:
        raise LLMError("litellm is not installed (`pip install litellm`)")

    _prime_litellm_env_once()

    model = settings.LITELLM_MODEL
    fallbacks = settings.LITELLM_FALLBACKS
    params = dict(
        messages=messages,
        temperature=settings.LLM_TEMPERATURE if temperature is None else temperature,
        max_tokens=settings.LLM_MAX_TOKENS if max_tokens is None else max_tokens,
        timeout=settings.LITELLM_TIMEOUT,
        num_retries=settings.LITELLM_NUM_RETRIES,
    )

    started = time.monotonic()
    try:
        # completion_with_fallbacks tries `model` first, then each entry in
        # `fallbacks` on connection error / timeout / 5xx / rate limit.
        if fallbacks:
            resp = completion_with_fallbacks(model=model, fallbacks=fallbacks, **params)
        else:
            resp = litellm.completion(model=model, **params)
    except Exception as exc:                       # noqa: BLE001
        _log.warning("LLM call failed model=%s fallbacks=%s err=%s",
                     model, fallbacks, exc)
        raise LLMError(f"LLM request failed (model={model}): {exc}") from exc
    finally:
        _log.info("LLM call model=%s duration_ms=%d",
                  model, int((time.monotonic() - started) * 1000))

    try:
        return (resp.choices[0].message.content or "").strip()
    except (AttributeError, IndexError, KeyError) as exc:
        raise LLMError(f"Unexpected LLM response shape: {exc}") from exc


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
