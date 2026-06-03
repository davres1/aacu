"""
Optional semantic cache for intent classification, backed by LanceDB.

The chatbot's classify() step turns a natural-language message into a
structured intent (action + params). Semantically equivalent questions
("how big is DB X" / "what's the size of database X") should resolve to the
same intent without a fresh LLM round-trip — that's the "fast results" win.

This module is a thin vector-store wrapper: the caller (llm.client) computes
the embedding via the LiteLLM gateway and hands us the vector. We look it up
in an embedded, file-based LanceDB table; a hit above the configured cosine
similarity threshold returns the cached intent, a miss returns None and the
caller falls back to the LLM, then store()s the fresh result.

Everything degrades gracefully: if lancedb isn't installed or CACHE_ENABLED
is false, enabled() is False and the chatbot behaves exactly as before. Any
runtime error is logged and swallowed — the cache must never break a request.

We deliberately cache ONLY classification (language -> intent), never the
summarize() step, which renders live DB/metric data that would go stale.
"""

import json
import logging
import os
import threading

import settings

_log = logging.getLogger("aacu.cache")

try:
    import lancedb
    import pyarrow as pa
    _LANCEDB_OK = True
except ImportError:                 # pragma: no cover - optional dependency
    _LANCEDB_OK = False

_TABLE_NAME = "intent_cache"

_lock = threading.Lock()
_table = None                       # opened lazily on first use


def enabled():
    """True when the cache is installed and switched on in settings."""
    return _LANCEDB_OK and settings.CACHE_ENABLED


def _escape(value):
    """Escape a string for a LanceDB SQL filter literal (single quotes)."""
    return (value or "").replace("'", "''")


def _get_table(dim):
    """Open (or create) the cache table. `dim` is the embedding width.

    Thread-safe and idempotent — gthread gunicorn workers share one table
    handle per process. The schema's fixed-width vector is sized from the
    first embedding the running model produces.
    """
    global _table
    if _table is not None:
        return _table
    with _lock:
        if _table is not None:                       # set while we waited
            return _table
        os.makedirs(settings.CACHE_DIR, exist_ok=True)
        db = lancedb.connect(settings.CACHE_DIR)
        if _TABLE_NAME in db.table_names():
            _table = db.open_table(_TABLE_NAME)
        else:
            schema = pa.schema([
                pa.field("vector",    pa.list_(pa.float32(), dim)),
                pa.field("namespace", pa.string()),
                pa.field("message",   pa.string()),
                pa.field("intent",    pa.string()),
            ])
            _table = db.create_table(_TABLE_NAME, schema=schema)
            _log.info("created intent cache at %s (dim=%d)", settings.CACHE_DIR, dim)
    return _table


def lookup(vector, namespace):
    """Return a cached intent dict for `vector` within `namespace`, or None.

    `namespace` partitions the cache by flavor + selected database so an
    mssql intent never satisfies an oracle request (and vice versa).
    """
    if not enabled():
        return None
    try:
        tbl = _get_table(len(vector))
        rows = (tbl.search(vector)
                   .metric("cosine")
                   .where(f"namespace = '{_escape(namespace)}'", prefilter=True)
                   .limit(1)
                   .to_list())
    except Exception as exc:                         # noqa: BLE001
        _log.warning("cache lookup failed (ns=%s): %s", namespace, exc)
        return None

    if not rows:
        return None
    row = rows[0]
    # LanceDB cosine search returns cosine *distance* (1 - cosine similarity).
    similarity = 1.0 - float(row.get("_distance", 1.0))
    if similarity < settings.CACHE_SIMILARITY:
        _log.debug("cache miss sim=%.3f < %.3f ns=%s",
                   similarity, settings.CACHE_SIMILARITY, namespace)
        return None
    try:
        intent = json.loads(row["intent"])
    except (KeyError, json.JSONDecodeError):
        return None
    _log.info("cache hit sim=%.3f ns=%s", similarity, namespace)
    return intent


def store(vector, message, namespace, intent):
    """Persist a freshly classified intent so future near-matches hit cache."""
    if not enabled():
        return
    try:
        tbl = _get_table(len(vector))
        tbl.add([{
            "vector":    vector,
            "namespace": namespace,
            "message":   message,
            "intent":    json.dumps(intent),
        }])
    except Exception as exc:                         # noqa: BLE001
        _log.warning("cache store failed (ns=%s): %s", namespace, exc)
