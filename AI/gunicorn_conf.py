"""
gunicorn config for the unified DBA chatbot.

Launch from the systemd unit (see bootstrap.sh Phase 8) with:

    cd AI && exec gunicorn -c gunicorn_conf.py app:app

Worker model: `gthread` — every request handler blocks on Ansible / LLM /
InfluxDB calls, so we want many threads per process, not many processes.
Tune the (workers x threads) product to the expected concurrent-user count.

Override any value at runtime via env, e.g.:
    GUNICORN_WORKERS=8 GUNICORN_THREADS=16 systemctl restart dba-chatbot
"""

import multiprocessing
import os


def _int(env_name, default):
    try:
        return int(os.environ.get(env_name, default))
    except (TypeError, ValueError):
        return default


bind         = os.environ.get("GUNICORN_BIND", f"0.0.0.0:{os.environ.get('FLASK_PORT', '5000')}")
workers      = _int("GUNICORN_WORKERS", max(2, (multiprocessing.cpu_count() // 2) or 2))
worker_class = os.environ.get("GUNICORN_WORKER_CLASS", "gthread")
threads      = _int("GUNICORN_THREADS", 8)

# Ansible runs + LLM calls can take a minute or two end-to-end, so the
# per-request timeout must be high. Default 300s.
timeout         = _int("GUNICORN_TIMEOUT", 300)
graceful_timeout= _int("GUNICORN_GRACEFUL_TIMEOUT", 30)
keepalive       = _int("GUNICORN_KEEPALIVE", 5)

# Recycle workers after N requests / N + jitter seconds to bound memory.
max_requests        = _int("GUNICORN_MAX_REQUESTS", 1000)
max_requests_jitter = _int("GUNICORN_MAX_REQUESTS_JITTER", 100)

# Logging — to stdout/stderr so journald (systemd) captures them.
accesslog   = "-"
errorlog    = "-"
loglevel    = os.environ.get("GUNICORN_LOG_LEVEL", "info")
access_log_format = '%(h)s %(l)s %(u)s "%(r)s" %(s)s %(b)s "%(f)s" "%(a)s" %(D)sus'

# `preload_app=True` imports `app:app` once in the master process before
# forking — saves memory (copy-on-write) and surfaces import errors at
# startup instead of on the first request.
preload_app = True

# Don't capture stdout of subprocesses (ansible-playbook prints a lot).
capture_output = False


def post_fork(server, worker):
    """Each worker logs its pid and the resolved LLM model on boot."""
    # Late-import settings so we read post-fork env / setup.yaml state.
    try:
        import settings   # noqa: WPS433
        server.log.info("worker pid=%d ready (model=%s, fallbacks=%s)",
                        worker.pid, settings.LITELLM_MODEL, settings.LITELLM_FALLBACKS)
    except Exception as exc:                          # pragma: no cover
        server.log.warning("post_fork settings probe failed: %s", exc)
