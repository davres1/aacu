#!/usr/bin/env python3
"""
generate_databases_ini.py — IBM Db2 (LUW) edition
-------------------------------------------------

Walks every Db2 host in the Ansible inventory, pulls each host's
`ansible_local.db_inventory` fact (produced by Db2/files/db_inventory.sh
deployed at /etc/ansible/facts.d/db_inventory.fact), and writes
Db2/inventory/databases.ini with one [<DB_NAME>] section per discovered
database.

  * `ansible_servername` is set from the host that reported the DB.
  * `db2_instance` is the instance the DB lives in (host\\instance).
  * Existing sections (connuser, connpass, retention, emaillist, ...) are
    PRESERVED — re-running picks up newly added DBs without clobbering edits.

Two ways to source facts:
  1. Live  — shells out to `ansible -m setup` against the inventory.
  2. Cached — points at a directory of pre-fetched JSON facts (one per host,
     as produced by `ansible -m setup --tree <dir>`).

Usage:
    python3 generate_db2_databases_ini.py
    python3 generate_db2_databases_ini.py --from-tree /tmp/facts --dry-run
"""

from __future__ import annotations

import argparse
import configparser
import json
import os
import shutil
import subprocess
import sys
import tempfile
from datetime import datetime
from pathlib import Path


# Db2 has no fixed "system database" set the way SQL Server does; the catalog
# lives inside each database (SYSCAT.*). Kept for symmetry with the other
# generators — populate if a site wants to exclude admin/sample DBs by default.
SYSTEM_DBS: set[str] = set()

# Fields managed manually — preserved verbatim from existing sections.
USER_OWNED_FIELDS = (
    "connuser", "connpass",
    "environment", "emaillist", "retention",
)

# Fields the generator always (re)writes.
MANAGED_FIELDS = ("ansible_servername", "db2_instance", "database",
                  "version", "edition", "lastupdated")


# ---------------------------------------------------------------------------
# Fact sources
# ---------------------------------------------------------------------------

def gather_facts_live(inventory: str, group: str, tree_dir: str) -> dict:
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
        out[entry.name] = data.get("ansible_facts", data)
    return out


# ---------------------------------------------------------------------------
# Fact extraction
# ---------------------------------------------------------------------------

def extract_databases(per_host_facts: dict, include_system: bool) -> list[dict]:
    """db_inventory.sh emits:
       ansible_local.db_inventory.db2 = {
           "<host>\\<instance>": {
               "instance_name": "...",  "version": ...,  "edition": "...",
               "databases": [{"name": "SAMPLE", ...}, ...],
           }, ...
       }
    """
    rows = []
    for host, facts in per_host_facts.items():
        local = (facts or {}).get("ansible_local", {})
        inv = (local or {}).get("db_inventory", {})
        if not isinstance(inv, dict):
            continue

        host_hint = inv.get("computer_name") or inv.get("hostname") or host
        db2 = inv.get("db2") or {}
        if not isinstance(db2, dict):
            continue

        for instance_key, instance_info in db2.items():
            if not isinstance(instance_info, dict):
                continue
            instance_name = instance_info.get("instance_name") or instance_key
            version       = str(instance_info.get("full_version", instance_info.get("version", "")))
            edition       = instance_info.get("edition", "")

            for db in instance_info.get("databases", []) or []:
                name = (db.get("name") or "").strip()
                if not name:
                    continue
                if not include_system and name in SYSTEM_DBS:
                    continue
                rows.append({
                    "name":         name,
                    "host":         host_hint,
                    "db2_instance": instance_name,
                    "database":     name,
                    "version":      version,
                    "edition":      edition,
                    "status":       db.get("status", ""),
                    "size_mb":      db.get("size_mb", ""),
                })
    return rows


# ---------------------------------------------------------------------------
# databases.ini merge
# ---------------------------------------------------------------------------

def _new_parser() -> configparser.ConfigParser:
    p = configparser.ConfigParser(
        allow_no_value=True,
        delimiters=("=",),
        interpolation=None,
    )
    p.optionxform = str
    return p


def merge_into_ini(existing_path: Path, db_rows: list[dict]) -> tuple[configparser.ConfigParser, dict]:
    parser = _new_parser()
    if existing_path.exists():
        parser.read(existing_path)

    stats = {"added": 0, "updated": 0, "unchanged": 0, "hosts": set()}
    today = datetime.now().strftime("%Y-%m-%d %H:%M:%S")

    # Rebuild [db2_servers] roster.
    hosts = set()
    if parser.has_section("db2_servers"):
        for key in parser["db2_servers"]:
            host = key.split()[0].strip()
            if host:
                hosts.add(host)
    for row in db_rows:
        hosts.add(row["host"])
        stats["hosts"].add(row["host"])

    if parser.has_section("db2_servers"):
        parser.remove_section("db2_servers")
    parser.add_section("db2_servers")
    for h in sorted(hosts):
        parser.set("db2_servers", h, None)

    # Handle name collisions across hosts: if "TRADEDB" exists on two hosts,
    # the second one gets `TRADEDB__<host>` as its section header.
    used_sections: set[str] = set(parser.sections())

    for row in db_rows:
        candidate = row["name"]
        existing = next((s for s in parser.sections() if s.lower() == candidate.lower()), None)

        if existing is not None:
            existing_host = parser.get(existing, "ansible_servername", fallback="")
            if existing_host and existing_host != row["host"]:
                candidate = f"{candidate}__{row['host'].split('.')[0]}"
                existing = next((s for s in parser.sections() if s.lower() == candidate.lower()), None)

        if existing is None:
            parser.add_section(candidate)
            for field in USER_OWNED_FIELDS:
                parser.set(candidate, field, "")
            stats["added"] += 1
            matched = candidate
        else:
            matched = existing

        old_host = parser.get(matched, "ansible_servername", fallback="")
        parser.set(matched, "ansible_servername", row["host"])
        parser.set(matched, "db2_instance",       row["db2_instance"])
        parser.set(matched, "database",           row["database"])
        parser.set(matched, "version",            row["version"])
        parser.set(matched, "edition",            row["edition"])
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
    ap.add_argument("--group", default="db2_servers",
                    help="Inventory group to target (live mode).")
    ap.add_argument("--from-tree", metavar="DIR",
                    help="Load facts from a directory of JSON files (--tree output).")
    ap.add_argument("--out", default="Db2/inventory/databases.ini", type=Path,
                    help="Where to write databases.ini.")
    ap.add_argument("--dry-run", action="store_true",
                    help="Print the result to stdout instead of writing.")
    ap.add_argument("--include-system-dbs", action="store_true",
                    help="Also emit sections for any DBs listed in SYSTEM_DBS.")
    args = ap.parse_args(argv)

    # 1. gather
    if args.from_tree:
        per_host = load_facts_from_tree(args.from_tree)
    else:
        tmp = tempfile.mkdtemp(prefix="db2_facts_")
        try:
            per_host = gather_facts_live(args.inventory, args.group, tmp)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    if not per_host:
        print("[error] no facts gathered", file=sys.stderr)
        return 2

    # 2. extract
    rows = extract_databases(per_host, include_system=args.include_system_dbs)
    print(f"[scan] {len(rows)} database(s) across {len({r['host'] for r in rows})} host(s)")
    if not rows:
        print("[error] no databases found — is db_inventory.sh deployed and "
              "ansible_local.db_inventory populated?", file=sys.stderr)
        return 3

    # 3. merge
    parser, stats = merge_into_ini(args.out, rows)
    print(f"[merge] added={stats['added']} updated={stats['updated']} "
          f"unchanged={stats['unchanged']} hosts={len(stats['hosts'])}")

    # 4. write
    write_ini(parser, args.out, args.dry_run)
    return 0


if __name__ == "__main__":
    sys.exit(main())
