#!/usr/bin/env python3
"""
generate_databases_ini.py
-------------------------

Walk every Oracle host in the Ansible inventory, pull each host's
`ansible_local.db_inventory` fact (produced by Oracle/files/db_inventory.sh
deployed at /etc/ansible/facts.d/db_inventory.fact), and emit a
`databases.ini` with one [<DB_NAME>] section per discovered database.

  * `ansible_servername` is set from the host that reported the DB.
  * Existing sections (passwords, retention, emaillist, appsserver…) are
    PRESERVED — the script only adds newly-discovered DBs and updates
    `ansible_servername` / `lastupdated`.

Two ways to source facts:
  1. Live  — shells out to `ansible -m setup` against the inventory.
  2. Cached — points at a directory of pre-fetched JSON facts (one file
     per host, as produced by `ansible -m setup --tree <dir>`).

Usage:
    python3 generate_databases_ini.py \\
        --inventory /etc/ansible/hosts \\
        --group oracle_servers \\
        --out Oracle/inventory/databases.ini

    python3 generate_databases_ini.py --from-tree /tmp/facts \\
        --out Oracle/inventory/databases.ini --dry-run
"""

from __future__ import annotations

import argparse
import configparser
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from collections import OrderedDict
from datetime import datetime
from pathlib import Path


# Fields the user owns manually — preserved verbatim from any existing
# section. New sections get an empty placeholder.
USER_OWNED_FIELDS = (
    "username",
    "syspass",
    "emaillist",
    "retention",
    "appsserver",
    "appsuserid",
    "appspasswd",
    "aqenabled",
)

# Fields we always (re)write from facts.
MANAGED_FIELDS = ("ansible_servername", "lastupdated")


# ---------------------------------------------------------------------------
# Fact sources
# ---------------------------------------------------------------------------

def gather_facts_live(inventory: str, group: str, tree_dir: str) -> dict:
    """Run ansible -m setup --tree to dump each host's facts to a directory.

    Returns a dict {hostname: parsed_fact_dict}.
    """
    print(f"[live] running ansible -m setup against [{group}] in {inventory} …")
    cmd = [
        "ansible", "-i", inventory, group,
        "-m", "setup", "-a", "filter=ansible_local",
        "--tree", tree_dir,
    ]
    proc = subprocess.run(cmd, capture_output=True, text=True, timeout=900)
    if proc.returncode != 0:
        sys.stderr.write(proc.stdout + proc.stderr + "\n")
        raise SystemExit(f"ansible -m setup exited {proc.returncode}")
    return load_facts_from_tree(tree_dir)


def load_facts_from_tree(tree_dir: str) -> dict:
    """Read a directory of `ansible -m setup --tree` outputs (one JSON per host)."""
    out = {}
    for entry in os.scandir(tree_dir):
        if not entry.is_file():
            continue
        try:
            with open(entry.path, "r", encoding="utf-8") as fh:
                data = json.load(fh)
        except (OSError, json.JSONDecodeError) as exc:
            print(f"[warn] could not read {entry.name}: {exc}", file=sys.stderr)
            continue
        # `--tree` output wraps facts under "ansible_facts".
        out[entry.name] = data.get("ansible_facts", data)
    return out


# ---------------------------------------------------------------------------
# Fact extraction
# ---------------------------------------------------------------------------

def extract_databases(per_host_facts: dict) -> list[dict]:
    """Pull every (host, db) pair out of the per-host fact dicts."""
    rows = []
    for host, facts in per_host_facts.items():
        local = (facts or {}).get("ansible_local", {})
        inv = (local or {}).get("db_inventory", {})
        if not isinstance(inv, dict):
            continue
        host_hint = inv.get("hostname") or host
        for db in inv.get("databases", []) or []:
            name = (db.get("db_unique_name") or db.get("db_name") or db.get("sid") or "").strip()
            if not name:
                continue
            rows.append({
                "name": name,
                "host": host_hint,
                "sid": db.get("sid", ""),
                "version": db.get("version", ""),
                "open_mode": db.get("open_mode", ""),
                "database_role": db.get("database_role", ""),
                "log_mode": db.get("log_mode", ""),
                "size_mb": db.get("total_size_mb", ""),
            })
    return rows


# ---------------------------------------------------------------------------
# databases.ini merge
# ---------------------------------------------------------------------------

# Use a permissive parser so we don't choke on the username = {dict} value.
def _new_parser() -> configparser.ConfigParser:
    p = configparser.ConfigParser(
        allow_no_value=True,
        delimiters=("=",),
        interpolation=None,
    )
    p.optionxform = str
    return p


def merge_into_ini(existing_path: Path, db_rows: list[dict]) -> tuple[configparser.ConfigParser, dict]:
    """Return (parser, stats) with newly-discovered DBs added.

    Existing user-owned fields are preserved. ansible_servername + lastupdated
    are always overwritten. A `[oracle_servers]` group is kept/created with the
    union of hostnames so the file is still inventory-aware.
    """
    parser = _new_parser()
    if existing_path.exists():
        parser.read(existing_path)

    stats = {"added": 0, "updated": 0, "unchanged": 0, "hosts": set()}
    today = datetime.now().strftime("%Y-%m-%d %H:%M:%S")

    # Rebuild the [oracle_servers] roster from observed hosts (union with any
    # existing entries to avoid losing manually-added hosts).
    hosts = set()
    if parser.has_section("oracle_servers"):
        for key in parser["oracle_servers"]:
            host = key.split()[0].strip()
            if host:
                hosts.add(host)
    for row in db_rows:
        hosts.add(row["host"])
        stats["hosts"].add(row["host"])

    # Wipe + rewrite the group so order is deterministic.
    if parser.has_section("oracle_servers"):
        parser.remove_section("oracle_servers")
    parser.add_section("oracle_servers")
    for h in sorted(hosts):
        parser.set("oracle_servers", h, None)

    # Upsert per-DB sections.
    for row in db_rows:
        name = row["name"]
        # Case-insensitive lookup so PHHSDG8 and phhsdg8 don't double up.
        matched = next((s for s in parser.sections() if s.lower() == name.lower()), None)
        if matched is None:
            parser.add_section(name)
            for field in USER_OWNED_FIELDS:
                parser.set(name, field, "")            # leave blank for the user to fill in
            stats["added"] += 1
            matched = name

        old_host = parser.get(matched, "ansible_servername", fallback="")
        parser.set(matched, "ansible_servername", row["host"])
        parser.set(matched, "lastupdated",        today)
        if old_host and old_host != row["host"]:
            stats["updated"] += 1
        else:
            stats["unchanged"] += 1

    return parser, stats


def write_ini(parser: configparser.ConfigParser, out_path: Path, dry_run: bool) -> None:
    if dry_run:
        parser.write(sys.stdout, space_around_delimiters=True)
        return

    if out_path.exists():
        backup = out_path.with_suffix(out_path.suffix + ".bak")
        shutil.copy2(out_path, backup)
        print(f"[backup] wrote {backup}")

    out_path.parent.mkdir(parents=True, exist_ok=True)
    with out_path.open("w", encoding="utf-8") as fh:
        parser.write(fh, space_around_delimiters=True)
    print(f"[ok] wrote {out_path}")


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(
        formatter_class=argparse.RawDescriptionHelpFormatter,
        description=__doc__,
    )
    ap.add_argument("--inventory", default="/etc/ansible/hosts",
                    help="Ansible inventory (live mode).")
    ap.add_argument("--group", default="oracle_servers",
                    help="Inventory group to target (live mode).")
    ap.add_argument("--from-tree", metavar="DIR",
                    help="Skip ansible; load facts from a directory of "
                         "JSON files (one per host, --tree output).")
    ap.add_argument("--out", default="Oracle/inventory/databases.ini",
                    type=Path, help="Where to write databases.ini.")
    ap.add_argument("--dry-run", action="store_true",
                    help="Print the resulting INI to stdout, don't write.")
    args = ap.parse_args(argv)

    # 1. gather facts
    if args.from_tree:
        per_host = load_facts_from_tree(args.from_tree)
    else:
        tmp = tempfile.mkdtemp(prefix="ora_facts_")
        try:
            per_host = gather_facts_live(args.inventory, args.group, tmp)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    if not per_host:
        print("[error] no facts gathered", file=sys.stderr)
        return 2

    # 2. extract DBs
    rows = extract_databases(per_host)
    print(f"[scan] {len(rows)} database(s) across {len({r['host'] for r in rows})} host(s)")
    if not rows:
        print("[error] no databases found in facts — is db_inventory.fact deployed?",
              file=sys.stderr)
        return 3

    # 3. merge into existing INI
    parser, stats = merge_into_ini(args.out, rows)
    print(f"[merge] added={stats['added']} updated={stats['updated']} "
          f"unchanged={stats['unchanged']} hosts={len(stats['hosts'])}")

    # 4. write (or dry-run)
    write_ini(parser, args.out, args.dry_run)
    return 0


if __name__ == "__main__":
    sys.exit(main())
