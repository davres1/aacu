# Import json Python module
#!/usr/bin/env python3
"""
    Script to parse db_inventory.ps1 JSON output and create Rundeck fact files
    for each SQL Server instance with instance properties and databases.
"""

import json
import os
import sys
import glob
from pathlib import Path

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
    
    with open(fact_path, 'w') as f:
        json.dump(fact_content, f, indent=2)
    
    return fact_path

def process_db_inventory(json_data):
    """Process db_inventory.ps1 output and create fact files"""
    
    instances_list = []
    
    # Extract mssql instances from the JSON
    if "mssql" not in json_data:
        print("Error: 'mssql' key not found in JSON output")
        return
    
    mssql_data = json_data["mssql"]
    
    # Process each SQL Server instance
    for instance_name, instance_data in mssql_data.items():
        print(f"\n=== Processing SQL Server Instance: {instance_name} ===")
        
        # Create instance directory
        instance_dir = instance_name.replace("\\", "_").replace(":", "")
        if not os.path.isdir(instance_dir):
            os.makedirs(instance_dir)
        
        instances_list.append(instance_name)
        
        # Create subdirectories for properties and databases
        properties_dir = os.path.join(instance_dir, "properties")
        databases_dir = os.path.join(instance_dir, "databases")
        
        if not os.path.isdir(properties_dir):
            os.makedirs(properties_dir)
        if not os.path.isdir(databases_dir):
            os.makedirs(databases_dir)
        
        # Process instance properties
        print(f"\nCreating property files in {properties_dir}:")
        for prop_key, prop_value in instance_data.items():
            if prop_key == "databases":
                continue  # Handle databases separately
            
            fact_file = create_fact_file(properties_dir, prop_key, prop_value)
            print(f"  - Created: {prop_key}.json = {convert_value_to_string(prop_value)}")
        
        # Process databases
        if "databases" in instance_data and isinstance(instance_data["databases"], list):
            print(f"\nCreating database files in {databases_dir}:")
            db_names = []
            
            for db in instance_data["databases"]:
                db_name = db.get("name", "Unknown")
                db_names.append(db_name)
                
                db_subdir = os.path.join(databases_dir, db_name)
                if not os.path.isdir(db_subdir):
                    os.makedirs(db_subdir)
                
                # Create fact files for each database property
                for db_prop_key, db_prop_value in db.items():
                    fact_file = create_fact_file(db_subdir, db_prop_key, db_prop_value)
                    print(f"  - Created: {db_name}/{db_prop_key}.json = {convert_value_to_string(db_prop_value)}")
            
            # Create database list file
            db_list_path = os.path.join(instance_dir, "database_list.json")
            with open(db_list_path, 'w') as f:
                db_list_content = [{"name": name, "value": name, "selected": True} for name in db_names]
                json.dump(db_list_content, f, indent=2)
            print(f"  - Created: database_list.json with {len(db_names)} databases")
    
    # Create summary file with all instances
    with open('sql_instances.json', 'w') as f:
        instances_content = [{"name": inst, "value": inst, "selected": True} for inst in instances_list]
        json.dump(instances_content, f, indent=2)
    
    print(f"\n=== Summary ===")
    print(f"Processed {len(instances_list)} SQL Server instance(s)")
    print(f"Created sql_instances.json with instance list")
    
    return instances_list

def main():
    """Main function to process all db_inventory files"""
    
    # Look for db_inventory facts files
    fact_files = glob.glob("db_inventory*.json") + glob.glob("db_inventory*.facts")
    
    if not fact_files:
        print("Error: No db_inventory files found")
        print("Looking for: db_inventory*.json or db_inventory*.facts")
        return 1
    
    try:
        for fact_file in fact_files:
            print(f"\n{'='*60}")
            print(f"Processing file: {fact_file}")
            print(f"{'='*60}")
            
            with open(fact_file, 'r') as f:
                json_data = json.load(f)
            
            instances = process_db_inventory(json_data)
            
            if instances:
                print(f"\n✓ Successfully processed {len(instances)} instance(s)")
            
    except json.JSONDecodeError as e:
        print(f"Error: Invalid JSON in file - {e}")
        return 1
    except FileNotFoundError as e:
        print(f"Error: File not found - {e}")
        return 1
    except Exception as e:
        print(f"Error: {e}")
        return 1
    
    return 0

if __name__ == "__main__":
    sys.exit(main())