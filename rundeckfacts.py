#!/usr/bin/env python3
"""
Parse db_inventory JSON output (SQL Server / Oracle / Db2) and create Rundeck
fact files for each database instance, with instance properties and databases.

Flavor-agnostic — handles every db_inventory shape this repo produces:
  * mssql : {"mssql": {"<host>\\<instance>": {..., "databases": [...]}}}
  * db2   : {"db2":   {"<host>\\<instance>": {..., "databases": [...]}}}
  * oracle: either {"oracle": {"<sid>": {...}}} OR the flat collector shape
            {"hostname": ..., "databases": [...]} (one implicit instance).

Output is written under <flavor>/<instance>/ so multiple flavors can be
processed from the same working directory without collisions.
"""

import json
import os
import sys
import glob

FLAVORS = ("mssql", "oracle", "db2")


def convert_value_to_string(value):
    """Convert any value to string safely"""
    if value is None:
        return "N/A"
    elif isinstance(value, bool):
        return "Yes" if value else "No"
    elif isinstance(value, (list, dict)):
        return json.dumps(value)
    else:
        return str(value)


def create_fact_file(directory, filename, value):
    """Create a JSON fact file for Rundeck"""
    fact_path = os.path.join(directory, f"{filename}.json")
    value_str = convert_value_to_string(value)
    fact_content = [{"name": filename, "value": value_str, "selected": True}]
    with open(fact_path, "w") as f:
        json.dump(fact_content, f, indent=2)
    return fact_path


def _instances_for_flavor(json_data, flavor):
    """Return the {instance: instance_data} dict for a flavor, normalizing the
    two Oracle shapes into the same instance-model the others use."""
    block = json_data.get(flavor)
    if isinstance(block, dict):
        return block
    # Oracle flat collector: {"hostname":..., "databases":[...]} — synthesize
    # a single instance keyed by hostname.
    if flavor == "oracle" and isinstance(json_data.get("databases"), list) \
            and not any(k in json_data for k in FLAVORS):
        host = json_data.get("hostname") or json_data.get("fqdn") or "oracle"
        props = {k: v for k, v in json_data.items() if k != "databases"}
        props["databases"] = json_data["databases"]
        return {host: props}
    return {}


def _process_instance(flavor, instance_name, instance_data):
    """Write properties + databases fact files for one instance under
    <flavor>/<instance>/. Returns the database name list."""
    instance_dir = os.path.join(flavor, instance_name.replace("\\", "_").replace(":", ""))
    properties_dir = os.path.join(instance_dir, "properties")
    databases_dir = os.path.join(instance_dir, "databases")
    os.makedirs(properties_dir, exist_ok=True)
    os.makedirs(databases_dir, exist_ok=True)

    print(f"\n=== {flavor} instance: {instance_name} ===")
    for prop_key, prop_value in instance_data.items():
        if prop_key == "databases":
            continue
        create_fact_file(properties_dir, prop_key, prop_value)
        print(f"  - properties/{prop_key}.json = {convert_value_to_string(prop_value)}")

    db_names = []
    dbs = instance_data.get("databases")
    if isinstance(dbs, list):
        for db in dbs:
            db_name = db.get("name", "Unknown") if isinstance(db, dict) else str(db)
            db_names.append(db_name)
            db_subdir = os.path.join(databases_dir, str(db_name))
            os.makedirs(db_subdir, exist_ok=True)
            if isinstance(db, dict):
                for k, v in db.items():
                    create_fact_file(db_subdir, k, v)
        db_list_path = os.path.join(instance_dir, "database_list.json")
        with open(db_list_path, "w") as f:
            json.dump([{"name": n, "value": n, "selected": True} for n in db_names], f, indent=2)
        print(f"  - {len(db_names)} database(s)")
    return db_names


def process_db_inventory(json_data):
    """Process a db_inventory document across all flavors it contains."""
    found = {f: _instances_for_flavor(json_data, f) for f in FLAVORS}
    if not any(found.values()):
        print("Error: no recognised flavor block (mssql/oracle/db2) or 'databases' list found")
        return []

    processed = []
    for flavor, instances in found.items():
        if not instances:
            continue
        flavor_insts = []
        for instance_name, instance_data in instances.items():
            if not isinstance(instance_data, dict):
                continue
            _process_instance(flavor, instance_name, instance_data)
            flavor_insts.append(instance_name)
            processed.append(f"{flavor}/{instance_name}")
        # Per-flavor instance list (e.g. mssql_instances.json).
        with open(f"{flavor}_instances.json", "w") as f:
            json.dump([{"name": i, "value": i, "selected": True} for i in flavor_insts], f, indent=2)

    # Combined list across flavors.
    with open("db_instances.json", "w") as f:
        json.dump([{"name": i, "value": i, "selected": True} for i in processed], f, indent=2)

    print(f"\n=== Summary === processed {len(processed)} instance(s) across "
          f"{sum(1 for v in found.values() if v)} flavor(s)")
    return processed


def main():
    """Process every db_inventory facts file in the working directory."""
    fact_files = glob.glob("db_inventory*.json") + glob.glob("db_inventory*.facts")
    if not fact_files:
        print("Error: No db_inventory files found")
        print("Looking for: db_inventory*.json or db_inventory*.facts")
        return 1

    rc = 0
    for fact_file in fact_files:
        print(f"\n{'='*60}\nProcessing file: {fact_file}\n{'='*60}")
        try:
            with open(fact_file, "r") as f:
                json_data = json.load(f)
            process_db_inventory(json_data)
        except json.JSONDecodeError as e:
            print(f"Error: Invalid JSON in {fact_file} - {e}"); rc = 1
        except Exception as e:                                  # noqa: BLE001
            print(f"Error processing {fact_file}: {e}"); rc = 1
    return rc


if __name__ == "__main__":
    sys.exit(main())
