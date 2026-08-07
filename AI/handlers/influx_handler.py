"""
Query InfluxDB v1 (the database CheckMK stats are pushed into by
sync_influx.sh in the repo root).
"""

import re
import statistics as _statistics

from influxdb import InfluxDBClient

import settings


_DURATION = re.compile(r"^\d+[smhdw]$")


def _client():
    return InfluxDBClient(
        host=settings.INFLUX_HOST,
        port=settings.INFLUX_PORT,
        username=settings.INFLUX_USER,
        password=settings.INFLUX_PASSWORD,
        database=settings.INFLUX_DATABASE,
        ssl=settings.INFLUX_SSL,
        verify_ssl=settings.INFLUX_SSL,
        timeout=15,
    )


def _validated_duration(time_range):
    tr = (time_range or "1h").strip().lower()
    return tr if _DURATION.match(tr) else "1h"


def _validated_agg(agg):
    return agg if agg in {"mean", "max", "min", "last", "sum"} else "mean"


def query(measurement, host=None, time_range="1h", aggregation="mean"):
    if not measurement or not re.match(r"^[A-Za-z0-9._-]+$", measurement):
        return {"error": f"Invalid measurement name: {measurement!r}"}

    tr = _validated_duration(time_range)
    agg = _validated_agg(aggregation)

    where = [f"time > now() - {tr}"]
    bind = {}
    if host:
        where.append("host = $host")
        bind["host"] = host

    influx_q = (
        f'SELECT {agg}("value") AS value '
        f'FROM "{measurement}" '
        f"WHERE {' AND '.join(where)} "
        f"GROUP BY time(1m), host fill(none)"
    )

    cli = _client()
    try:
        rs = cli.query(influx_q, bind_params=bind)
    except Exception as exc:  # influxdb client wraps many error types
        return {"error": f"InfluxDB query failed: {exc}", "query": influx_q}

    series = []
    for (_meas, tags), points in rs.items() or []:
        series.append({
            "host": (tags or {}).get("host"),
            "points": list(points),
        })

    return {
        "query": influx_q,
        "measurement": measurement,
        "time_range": tr,
        "aggregation": agg,
        "series": series,
    }


def list_measurements():
    cli = _client()
    try:
        rs = cli.query("SHOW MEASUREMENTS")
        return [row["name"] for row in rs.get_points()]
    except Exception as exc:
        return {"error": str(exc)}


# ---------------------------------------------------------------------------
# Server utilization
#
# Pulls the three "primary vitals" (CPU, memory, disk) that CheckMK feeds
# into InfluxDB and produces both a raw time-series (for charting) and a
# statistical summary (mean / p95 / peak). The caller uses the summary to
# classify the server as under- / over- / well-utilized.
#
# Measurement names are configurable so ops teams can point at whatever their
# CheckMK setup emits (e.g. "CPU_load" vs "cpu_utilization").
# ---------------------------------------------------------------------------

def _percentile(values, pct):
    if not values:
        return None
    ordered = sorted(values)
    k = (len(ordered) - 1) * (pct / 100.0)
    lo = int(k)
    hi = min(lo + 1, len(ordered) - 1)
    frac = k - lo
    return ordered[lo] + (ordered[hi] - ordered[lo]) * frac


def _series_stats(series):
    """Flatten every host's points into a single value stream and return stats."""
    vals = []
    hosts = []
    for s in series or []:
        host = s.get("host")
        if host and host not in hosts:
            hosts.append(host)
        for p in s.get("points") or []:
            v = p.get("value")
            if v is None:
                continue
            try:
                vals.append(float(v))
            except (TypeError, ValueError):
                continue
    if not vals:
        return {"samples": 0, "hosts": hosts}
    return {
        "samples": len(vals),
        "hosts":   hosts,
        "min":     round(min(vals), 2),
        "max":     round(max(vals), 2),
        "mean":    round(_statistics.fmean(vals), 2),
        "median":  round(_statistics.median(vals), 2),
        "p95":     round(_percentile(vals, 95), 2),
    }


def server_utilization(host=None, time_range="7d"):
    """
    Query CPU, memory, and disk utilization for `host` over `time_range`
    (default 7d) and return series + summary stats for each.

    Measurement names come from settings.INFLUX_MEASUREMENT_* so they can be
    aligned with whatever the CheckMK plugin names emit.
    """
    tr = _validated_duration(time_range)
    metrics = {
        "cpu":    getattr(settings, "INFLUX_MEASUREMENT_CPU",    "cpu_utilization"),
        "memory": getattr(settings, "INFLUX_MEASUREMENT_MEMORY", "memory_utilization"),
        "disk":   getattr(settings, "INFLUX_MEASUREMENT_DISK",   "disk_utilization"),
    }
    result = {"host": host, "time_range": tr, "metrics": {}}
    for name, measurement in metrics.items():
        data = query(measurement=measurement, host=host, time_range=tr, aggregation="mean")
        if isinstance(data, dict) and data.get("error"):
            result["metrics"][name] = {
                "measurement": measurement,
                "error":       data.get("error"),
                "series":      [],
                "stats":       {"samples": 0},
            }
            continue
        result["metrics"][name] = {
            "measurement": measurement,
            "time_range":  tr,
            "aggregation": "mean",
            "series":      data.get("series", []),
            "stats":       _series_stats(data.get("series", [])),
        }
    return result
