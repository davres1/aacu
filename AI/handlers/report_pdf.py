"""
report_pdf.py - render a human-readable DBA dashboard PDF from a rendered
thresholds.json template (mssql or oracle flavor).

The PDF is intentionally self-contained and printer-friendly:
  - Cover page (flavor, generated_at, host the report came from)
  - Executive summary    (counts, score bands)
  - CIS compliance       (benchmark name, critical controls, auto-remediate)
  - Threshold reference  (every section of thresholds.json as a table)
  - Database inventory   (when ansible_local.db_inventory facts are passed in)
  - Backup status        (when present)
  - Charts catalogue     (lists every chart the chatbot UI renders, with
                          datasource + thresholds - the PDF isn't trying to
                          re-render the live charts)
  - Diagrams             (mermaid source as monospace code blocks)

Pure ReportLab platypus - no headless browsers, no Pango/Cairo. Safe to run
on any host the chatbot already runs on.
"""

from __future__ import annotations

import io
import json
import os
from datetime import datetime

from jinja2 import Environment, FileSystemLoader
from reportlab.lib import colors
from reportlab.lib.enums import TA_LEFT
from reportlab.lib.pagesizes import LETTER
from reportlab.lib.styles import ParagraphStyle, getSampleStyleSheet
from reportlab.lib.units import inch
from reportlab.platypus import (
    BaseDocTemplate,
    Frame,
    KeepTogether,
    PageBreak,
    PageTemplate,
    Paragraph,
    Preformatted,
    Spacer,
    Table,
    TableStyle,
)

import settings


# ---------------------------------------------------------------------------
# Threshold-template rendering
# ---------------------------------------------------------------------------
_TEMPLATE_BY_FLAVOR = {
    "oracle": "oracle_thresholds.json.j2",
    "db2":    "db2_thresholds.json.j2",
    "mysql":  "mysql_thresholds.json.j2",
    "mariadb":"mariadb_thresholds.json.j2",
    "mssql":  "mssql_thresholds.json.j2",
}


def _norm_flavor(flavor: str) -> str:
    f = (flavor or "").lower()
    return f if f in _TEMPLATE_BY_FLAVOR else "mssql"


def _template_path(flavor: str) -> str:
    fname = _TEMPLATE_BY_FLAVOR[_norm_flavor(flavor)]
    return os.path.join(settings.REPO_DIR, "templates", fname)


def _setup_context() -> dict:
    """Load setup.yaml as the Jinja context for the threshold templates."""
    try:
        import yaml
    except ImportError:
        return {}
    if not os.path.exists(settings.SETUP_YAML):
        return {}
    try:
        with open(settings.SETUP_YAML, "r", encoding="utf-8") as fh:
            ctx = yaml.safe_load(fh) or {}
    except (OSError, yaml.YAMLError):
        return {}
    # Provide the same magic ansible_date_time fact the template expects.
    ctx.setdefault(
        "ansible_date_time",
        {"iso8601": datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")},
    )
    return ctx


def load_thresholds(flavor: str) -> dict:
    """Render the j2 thresholds template for `flavor` against setup.yaml."""
    flavor = _norm_flavor(flavor)
    path = _template_path(flavor)
    if not os.path.exists(path):
        raise FileNotFoundError(f"thresholds template not found: {path}")
    env = Environment(
        loader=FileSystemLoader(os.path.dirname(path)),
        autoescape=False,
        trim_blocks=False,
        lstrip_blocks=False,
    )
    rendered = env.get_template(os.path.basename(path)).render(**_setup_context())
    return json.loads(rendered)


# ---------------------------------------------------------------------------
# Style helpers
# ---------------------------------------------------------------------------
_BRAND = colors.HexColor("#1e40af")
_BRAND_LIGHT = colors.HexColor("#60a5fa")
_GOOD = colors.HexColor("#28a745")
_WARN = colors.HexColor("#ffc107")
_BAD = colors.HexColor("#dc3545")
_MUTED = colors.HexColor("#6c757d")


def _styles():
    s = getSampleStyleSheet()
    s.add(ParagraphStyle("h1b", parent=s["Heading1"], textColor=_BRAND, spaceAfter=12))
    s.add(ParagraphStyle("h2b", parent=s["Heading2"], textColor=_BRAND, spaceBefore=14, spaceAfter=6))
    s.add(ParagraphStyle("h3b", parent=s["Heading3"], textColor=_BRAND, spaceBefore=8, spaceAfter=4))
    s.add(ParagraphStyle("body", parent=s["BodyText"], spaceAfter=4, leading=13))
    s.add(ParagraphStyle("muted", parent=s["BodyText"], textColor=_MUTED, fontSize=9, leading=11))
    s.add(ParagraphStyle("kvkey", parent=s["BodyText"], fontName="Helvetica-Bold", textColor=_BRAND))
    s.add(ParagraphStyle("mono", parent=s["Code"], fontSize=8, leading=10, leftIndent=0, alignment=TA_LEFT))
    return s


def _header_footer(canvas, doc):
    canvas.saveState()
    flavor = getattr(doc, "_aacu_flavor", "")
    generated = getattr(doc, "_aacu_generated", "")
    # Header band
    canvas.setFillColor(_BRAND)
    canvas.rect(0, LETTER[1] - 0.5 * inch, LETTER[0], 0.5 * inch, fill=1, stroke=0)
    canvas.setFillColor(colors.white)
    canvas.setFont("Helvetica-Bold", 11)
    canvas.drawString(0.6 * inch, LETTER[1] - 0.33 * inch,
                      f"Database Health Report - {flavor.upper()}")
    canvas.setFont("Helvetica", 9)
    canvas.drawRightString(LETTER[0] - 0.6 * inch, LETTER[1] - 0.33 * inch, generated)
    # Footer
    canvas.setFillColor(_MUTED)
    canvas.setFont("Helvetica", 8)
    canvas.drawString(0.6 * inch, 0.4 * inch,
                      "Generated by the DBA Chatbot - confidential, internal use only")
    canvas.drawRightString(LETTER[0] - 0.6 * inch, 0.4 * inch,
                           f"Page {canvas.getPageNumber()}")
    canvas.restoreState()


# ---------------------------------------------------------------------------
# Table builders
# ---------------------------------------------------------------------------
def _kv_table(rows, col_widths=(2.0 * inch, 4.5 * inch)):
    t = Table(rows, colWidths=list(col_widths))
    t.setStyle(TableStyle([
        ("FONT",       (0, 0), (-1, -1), "Helvetica", 9),
        ("FONT",       (0, 0), (0, -1),  "Helvetica-Bold", 9),
        ("TEXTCOLOR",  (0, 0), (0, -1),  _BRAND),
        ("VALIGN",     (0, 0), (-1, -1), "TOP"),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 3),
        ("TOPPADDING",    (0, 0), (-1, -1), 3),
        ("LINEBELOW",  (0, 0), (-1, -2), 0.25, colors.lightgrey),
    ]))
    return t


def _section_table(header, rows, col_widths=None):
    full = [header] + rows
    t = Table(full, colWidths=col_widths, repeatRows=1)
    t.setStyle(TableStyle([
        ("BACKGROUND", (0, 0), (-1, 0), _BRAND),
        ("TEXTCOLOR",  (0, 0), (-1, 0), colors.white),
        ("FONT",       (0, 0), (-1, 0), "Helvetica-Bold", 9),
        ("FONT",       (0, 1), (-1, -1), "Helvetica", 8),
        ("VALIGN",     (0, 0), (-1, -1), "TOP"),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 4),
        ("TOPPADDING",    (0, 0), (-1, -1), 4),
        ("ROWBACKGROUNDS", (0, 1), (-1, -1), [colors.whitesmoke, colors.white]),
        ("GRID",       (0, 0), (-1, -1), 0.25, colors.lightgrey),
    ]))
    return t


def _fmt(v):
    if v is None:
        return ""
    if isinstance(v, bool):
        return "yes" if v else "no"
    if isinstance(v, (list, tuple)):
        return ", ".join(str(x) for x in v) if v else "-"
    if isinstance(v, dict):
        # one-line dict summary
        return ", ".join(f"{k}={v!s}" for k, v in v.items())[:120]
    return str(v)


# ---------------------------------------------------------------------------
# Section builders
# ---------------------------------------------------------------------------
def _cover(story, S, flavor, thresholds):
    story.append(Spacer(1, 1.0 * inch))
    title = {"mssql": "SQL Server", "oracle": "Oracle", "db2": "Db2",
             "mysql": "MySQL", "mariadb": "MariaDB"}.get(flavor, "SQL Server")
    story.append(Paragraph(f"{title} Database Health Report", S["h1b"]))
    story.append(Spacer(1, 0.1 * inch))
    benchmark = (thresholds.get("cis") or {}).get("benchmark", "")
    if benchmark:
        story.append(Paragraph(f"Benchmark: <b>{benchmark}</b>", S["body"]))
    story.append(Paragraph(
        f"Generated: {thresholds.get('generated_at', datetime.utcnow().isoformat())}",
        S["muted"],
    ))
    story.append(Paragraph(
        f"Source template: <i>templates/{flavor}_thresholds.json.j2</i>",
        S["muted"],
    ))
    story.append(Spacer(1, 0.4 * inch))
    story.append(Paragraph(
        "This report is auto-generated from the single source of truth "
        "(setup.yaml + the Jinja threshold templates rendered for this flavor). "
        "Numbers shown here match what the CheckMK local plugins use to alert, "
        "the chatbot dashboard uses to render charts, and the Ansible facts "
        "consumers use to flag drift. Hand this PDF to a stakeholder who "
        "doesn't have access to Grafana / CheckMK and they can still see the "
        "compliance and capacity posture at a glance.",
        S["body"],
    ))
    story.append(PageBreak())


def _executive_summary(story, S, thresholds):
    story.append(Paragraph("Executive Summary", S["h2b"]))
    cis = thresholds.get("cis") or {}
    backups = thresholds.get("backups") or {}
    disk = thresholds.get("disk") or {}

    rows = [
        [Paragraph("Benchmark",         S["kvkey"]), Paragraph(_fmt(cis.get("benchmark")),         S["body"])],
        [Paragraph("Green score",       S["kvkey"]), Paragraph(f">= {_fmt((cis.get('score_thresholds') or {}).get('green_min'))}%",  S["body"])],
        [Paragraph("Yellow score",      S["kvkey"]), Paragraph(f">= {_fmt((cis.get('score_thresholds') or {}).get('yellow_min'))}%", S["body"])],
        [Paragraph("Red score",         S["kvkey"]), Paragraph(f"<= {_fmt((cis.get('score_thresholds') or {}).get('red_max'))}%",    S["body"])],
        [Paragraph("Critical controls", S["kvkey"]), Paragraph(_fmt(cis.get("critical_controls")), S["body"])],
        [Paragraph("Full backup SLA",   S["kvkey"]), Paragraph(f"{_fmt(backups.get('full_max_age_hours'))} h",  S["body"])],
        [Paragraph("Log backup SLA",    S["kvkey"]), Paragraph(f"{_fmt(backups.get('log_max_age_hours'))} h",   S["body"])],
        [Paragraph("Disk warn / crit",  S["kvkey"]), Paragraph(f"{_fmt(disk.get('drive_free_pct_warn'))} / {_fmt(disk.get('drive_free_pct_crit'))} %", S["body"])],
    ]
    story.append(_kv_table(rows))
    story.append(Spacer(1, 0.15 * inch))


def _threshold_sections(story, S, thresholds):
    """Every section of the rendered thresholds.json as a 2-column table."""
    skip_keys = {
        "version", "flavor", "generated_by", "generated_at",
        "dashboard", "influxdb",     # rendered separately
    }
    story.append(Paragraph("Threshold Reference", S["h2b"]))
    story.append(Paragraph(
        "Every configurable threshold this environment uses to grade health. "
        "These values are rendered from <i>setup.yaml</i> and pushed to every "
        "host so local plugins and the chatbot agree.",
        S["muted"],
    ))
    for section in sorted(thresholds.keys()):
        if section in skip_keys:
            continue
        value = thresholds[section]
        story.append(Paragraph(section.replace("_", " ").title(), S["h3b"]))
        rows = []
        if isinstance(value, dict):
            for k in sorted(value.keys()):
                rows.append([
                    Paragraph(k.replace("_", " "), S["kvkey"]),
                    Paragraph(_fmt(value[k]), S["body"]),
                ])
            story.append(_kv_table(rows))
        elif isinstance(value, list):
            rows = [[Paragraph(_fmt(item), S["body"])] for item in value]
            t = Table(rows or [[""]], colWidths=[6.5 * inch])
            t.setStyle(TableStyle([
                ("FONT", (0, 0), (-1, -1), "Helvetica", 9),
                ("LINEBELOW", (0, 0), (-1, -2), 0.25, colors.lightgrey),
                ("TOPPADDING", (0, 0), (-1, -1), 2),
                ("BOTTOMPADDING", (0, 0), (-1, -1), 2),
            ]))
            story.append(t)
        else:
            story.append(Paragraph(_fmt(value), S["body"]))
        story.append(Spacer(1, 0.08 * inch))


def _charts_catalogue(story, S, thresholds):
    charts = ((thresholds.get("dashboard") or {}).get("charts") or [])
    if not charts:
        return
    story.append(PageBreak())
    story.append(Paragraph("Dashboard Charts", S["h2b"]))
    story.append(Paragraph(
        "The live chatbot UI renders these charts; this PDF lists them so a "
        "reader knows what panels exist and where their data comes from.",
        S["muted"],
    ))
    rows = []
    for c in charts:
        thrs = c.get("thresholds") or []
        thr_txt = ", ".join(
            f"{t.get('value')}={t.get('color','')}" for t in thrs
        ) if thrs else "-"
        rows.append([
            Paragraph(_fmt(c.get("id")), S["body"]),
            Paragraph(_fmt(c.get("title")), S["body"]),
            Paragraph(_fmt(c.get("type")), S["body"]),
            Paragraph(_fmt(c.get("datasource") or "facts"), S["body"]),
            Paragraph(_fmt(c.get("query") or c.get("source")), S["body"]),
            Paragraph(thr_txt, S["body"]),
        ])
    story.append(_section_table(
        ["id", "title", "type", "datasource", "query / source", "thresholds"],
        rows,
        col_widths=[0.9 * inch, 1.6 * inch, 0.7 * inch, 0.7 * inch, 1.8 * inch, 0.8 * inch],
    ))


def _influx_queries(story, S, thresholds):
    influx = thresholds.get("influxdb") or {}
    queries = influx.get("queries") or {}
    if not queries:
        return
    story.append(PageBreak())
    story.append(Paragraph("InfluxDB Time-Series Queries", S["h2b"]))
    info = (
        f"InfluxDB: <b>{_fmt(influx.get('host'))}</b>:{_fmt(influx.get('port'))} "
        f"DB <b>{_fmt(influx.get('database'))}</b>  - "
        f"default window <b>{_fmt(influx.get('default_window'))}</b>, "
        f"bucket <b>{_fmt(influx.get('default_bucket'))}</b>"
    )
    story.append(Paragraph(info, S["body"]))
    story.append(Spacer(1, 0.1 * inch))
    rows = []
    for name in sorted(queries.keys()):
        rows.append([
            Paragraph(name, S["kvkey"]),
            Paragraph(_fmt(queries[name]), S["mono"]),
        ])
    story.append(_kv_table(rows, col_widths=(1.4 * inch, 5.1 * inch)))


def _diagrams(story, S, thresholds):
    diagrams = ((thresholds.get("dashboard") or {}).get("diagrams") or [])
    if not diagrams:
        return
    story.append(PageBreak())
    story.append(Paragraph("Architecture Diagrams (Mermaid source)", S["h2b"]))
    story.append(Paragraph(
        "These diagrams render inline in the chatbot using mermaid.js. The "
        "source text is included here so a reader can paste it into "
        "<i>mermaid.live</i> to regenerate the rendered version.",
        S["muted"],
    ))
    for d in diagrams:
        story.append(Paragraph(_fmt(d.get("title")) or _fmt(d.get("id")), S["h3b"]))
        body = d.get("definition") or ""
        # Mermaid definitions use literal \n in the JSON - convert for display.
        body = body.replace("\\n", "\n")
        story.append(KeepTogether([
            Preformatted(body, S["mono"]),
            Spacer(1, 0.12 * inch),
        ]))


def _inventory_section(story, S, inventory: dict | None, flavor: str):
    """When live ansible_local.db_inventory facts are passed in, render an
    inventory snapshot. Shape is flavor-specific."""
    if not inventory:
        return
    story.append(PageBreak())
    story.append(Paragraph("Database Inventory Snapshot", S["h2b"]))
    if flavor in ("mssql", "db2", "mysql", "mariadb"):
        # These all use the instance->databases shape; facts nest under the flavor key.
        instances = (inventory.get(flavor) or inventory.get("mssql") or {})
        for inst_name in sorted(instances.keys()):
            inst = instances[inst_name] or {}
            story.append(Paragraph(inst_name, S["h3b"]))
            rows = [
                [Paragraph("Version",       S["kvkey"]), Paragraph(_fmt(inst.get("version")),       S["body"])],
                [Paragraph("Edition",       S["kvkey"]), Paragraph(_fmt(inst.get("edition")),       S["body"])],
                [Paragraph("Patch level",   S["kvkey"]), Paragraph(_fmt(inst.get("patch_level")),   S["body"])],
                [Paragraph("Databases",     S["kvkey"]), Paragraph(_fmt(inst.get("database_count")),S["body"])],
                [Paragraph("Total size (MB)", S["kvkey"]), Paragraph(_fmt(inst.get("total_db_size_mb")), S["body"])],
                [Paragraph("CIS score",     S["kvkey"]), Paragraph(_fmt((inst.get("cis_compliance") or {}).get("compliance_score")), S["body"])],
            ]
            story.append(_kv_table(rows))
            dbs = inst.get("databases") or []
            if dbs:
                drows = []
                for d in dbs:
                    drows.append([
                        Paragraph(_fmt(d.get("name")),           S["body"]),
                        Paragraph(_fmt(d.get("status")),         S["body"]),
                        Paragraph(_fmt(d.get("recovery_model")), S["body"]),
                        Paragraph(_fmt(d.get("size_mb")),        S["body"]),
                        Paragraph(_fmt(d.get("last_backup_date")), S["body"]),
                        Paragraph("yes" if d.get("cis_compliant", True) else "no", S["body"]),
                    ])
                story.append(_section_table(
                    ["database", "status", "recovery", "size MB", "last backup", "cis ok"],
                    drows,
                    col_widths=[1.5 * inch, 0.7 * inch, 0.9 * inch, 0.8 * inch, 1.5 * inch, 0.6 * inch],
                ))
            story.append(Spacer(1, 0.15 * inch))
    else:
        # Oracle inventory shape: ansible_local.db_inventory.oracle.<host>
        oracle = inventory.get("oracle") or inventory
        for host in sorted(oracle.keys()):
            entry = oracle[host] or {}
            story.append(Paragraph(host, S["h3b"]))
            rows = [
                [Paragraph("Open mode",   S["kvkey"]), Paragraph(_fmt(entry.get("open_mode")),  S["body"])],
                [Paragraph("Role",        S["kvkey"]), Paragraph(_fmt(entry.get("database_role")), S["body"])],
                [Paragraph("DB size GB",  S["kvkey"]), Paragraph(_fmt(entry.get("db_size_gb")), S["body"])],
                [Paragraph("Last full backup", S["kvkey"]), Paragraph(_fmt(entry.get("last_full_backup")), S["body"])],
                [Paragraph("Flashback ON",     S["kvkey"]), Paragraph(_fmt(entry.get("flashback_on")), S["body"])],
            ]
            story.append(_kv_table(rows))
            story.append(Spacer(1, 0.1 * inch))


# ---------------------------------------------------------------------------
# Public entry point
# ---------------------------------------------------------------------------
def build_report(flavor: str, inventory: dict | None = None) -> bytes:
    """Render the thresholds template for `flavor` and produce a PDF.

    `inventory` is optional - pass the merged ansible_local.db_inventory
    facts and an extra snapshot section is appended.
    """
    flavor = _norm_flavor(flavor)
    thresholds = load_thresholds(flavor)

    buf = io.BytesIO()
    doc = BaseDocTemplate(
        buf,
        pagesize=LETTER,
        leftMargin=0.6 * inch,
        rightMargin=0.6 * inch,
        topMargin=0.7 * inch,
        bottomMargin=0.6 * inch,
        title=f"{flavor.upper()} Database Health Report",
        author="DBA Chatbot",
    )
    doc._aacu_flavor = flavor
    doc._aacu_generated = thresholds.get("generated_at", datetime.utcnow().isoformat())

    frame = Frame(
        doc.leftMargin, doc.bottomMargin,
        doc.width, doc.height,
        showBoundary=0,
    )
    doc.addPageTemplates([PageTemplate(id="main", frames=[frame], onPage=_header_footer)])

    S = _styles()
    story = []
    _cover(story, S, flavor, thresholds)
    _executive_summary(story, S, thresholds)
    _threshold_sections(story, S, thresholds)
    _charts_catalogue(story, S, thresholds)
    _influx_queries(story, S, thresholds)
    _inventory_section(story, S, inventory, flavor)
    _diagrams(story, S, thresholds)

    doc.build(story)
    return buf.getvalue()
