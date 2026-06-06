"""
Query InfluxDB v1 (the database CheckMK stats are pushed into by
sync_influx.sh in the repo root).
"""

import re

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
