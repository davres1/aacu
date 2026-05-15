#!/bin/bash

# --- CONFIG ---
RRDTOOL_BIN="/opt/omd/sites/monitoring/bin/rrdtool"
# Legacy polling path. The live pipeline now is nagflux (see bootstrap.sh
# Phase 5b). Credentials match the chatbot.influxdb section of setup.yaml.
INFLUX_URL="http://localhost:8086/write?db=checkmk"
INFLUX_USER="checkmk"
INFLUX_PASS="checkmk"
RRD_BASE_DIR="/omd/sites/monitoring/var/pnp4nagios/perfdata"
FETCH_WINDOW="-1h"
LOG_FILE="/var/log/migrate_data.log"
MAX_PARALLEL_JOBS=16  # Adjust based on system resources
TEMP_DIR="/tmp/influx_sync_$$"
# ----------------

# Create temporary working directory
mkdir -p "$TEMP_DIR"
trap "rm -rf $TEMP_DIR" EXIT

echo "[$(date +'%Y-%m-%d %H:%M:%S')] Starting RRD to influx migration (parallel mode)" >> "$LOG_FILE"

total_points=0
processed_files=0
failed_files=0
job_count=0

# Function to process a single RRD file
process_rrd_file() {
    local rrd_file="$1"
    local host="$2"
    local service="$3"
    local temp_dir="$4"
    local rrdtool_bin="$5"
    local influx_url="$6"
    local influx_user="$7"
    local influx_pass="$8"
    local log_file="$9"
    
    tmpfile="$temp_dir/influx_sync_${host}_${service}.txt"
    
    # Fetch RRD data and convert to InfluxDB format
    "$rrdtool_bin" fetch "$rrd_file" AVERAGE -s "$FETCH_WINDOW" 2>/dev/null \
    | awk -v host="$host" -v service="$service" '
        NR > 2 && NF >= 2 && $1 ~ /^[0-9]+:$/ {
            val = $2
            
            # Check for nan string (case-insensitive, with trim)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
            if (tolower(val) == "nan" || val == "" || val == "-") next
            
            ts = substr($1, 1, length($1)-1)  # Remove trailing colon
            
            # Safely convert to number
            val_num = val + 0.0
            
            # Double-check: if string contains "nan", skip
            if (index(tolower(val), "nan") > 0) next
            
            ns_ts = ts "000000000"
            
            # Escape special characters in measurement name
            safe_service = service
            gsub(/[^a-zA-Z0-9._-]/, "_", safe_service)
            gsub(/^_+|_+$/, "", safe_service)
            
            # Output only if we have a valid number
            if (safe_service != "") {
                printf "%s,host=%s value=%f %s\n", safe_service, host, val_num, ns_ts
            }
        }
    ' > "$tmpfile"

    # Write to InfluxDB if file has data
    if [ -s "$tmpfile" ]; then
        response=$(curl -s -u "$influx_user:$influx_pass" -XPOST "$influx_url" --data-binary @"$tmpfile" -w "\n%{http_code}")
        http_code=$(echo "$response" | tail -1)
        points=$(wc -l < "$tmpfile")
        
        if [ "$http_code" = "204" ]; then
            echo "[$(date +'%Y-%m-%d %H:%M:%S')] OK: $points points from $service on $host" >> "$log_file"
            echo "$points"  # Return points count
        else
            echo "[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $service on $host HTTP $http_code" >> "$log_file"
            echo "0"
        fi
    else
        echo "0"
    fi
    
    rm -f "$tmpfile"
}

export -f process_rrd_file

# Collect all RRD files first
rrd_files=()
for host_dir in "$RRD_BASE_DIR"/*; do
    [ -d "$host_dir" ] || continue
    host=$(basename "$host_dir")

    for rrd_file in "$host_dir"/{ORA*,MSSQL*,SQL*}.rrd; do
        [ -f "$rrd_file" ] || continue
        service=$(basename "$rrd_file" .rrd)
        rrd_files+=("$rrd_file|$host|$service")
    done
done

total_files=${#rrd_files[@]}
echo "[$(date +'%Y-%m-%d %H:%M:%S')] Found $total_files RRD files to process" >> "$LOG_FILE"

# Process files in parallel using GNU parallel (if available) or xargs
if command -v parallel &> /dev/null; then
    # Use GNU parallel - best performance
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] Using GNU parallel ($MAX_PARALLEL_JOBS jobs)" >> "$LOG_FILE"
    
    printf '%s\n' "${rrd_files[@]}" | parallel -j "$MAX_PARALLEL_JOBS" --colsep '\|' \
        process_rrd_file {1} {2} {3} "$TEMP_DIR" "$RRDTOOL_BIN" "$INFLUX_URL" "$INFLUX_USER" "$INFLUX_PASS" "$LOG_FILE" | \
        awk '{total+=$1} END {print total}' > "$TEMP_DIR/total_points.txt"
    
    total_points=$(cat "$TEMP_DIR/total_points.txt" 2>/dev/null || echo "0")
    
elif command -v xargs &> /dev/null; then
    # Fallback to xargs with parallel processing
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] Using xargs ($MAX_PARALLEL_JOBS jobs)" >> "$LOG_FILE"
    
    printf '%s\n' "${rrd_files[@]}" | xargs -P "$MAX_PARALLEL_JOBS" -I {} bash -c 'IFS="|" read -r rrd host svc <<< "{}"; process_rrd_file "$rrd" "$host" "$svc" '"\"$TEMP_DIR\"" "\"$RRDTOOL_BIN\"" "\"$INFLUX_URL\"" "\"$INFLUX_USER\"" "\"$INFLUX_PASS\"" "\"$LOG_FILE\"" || echo "0"' | \
        awk '{total+=$1} END {print total}' > "$TEMP_DIR/total_points.txt"
    
    total_points=$(cat "$TEMP_DIR/total_points.txt" 2>/dev/null || echo "0")

else
    # Fallback to background jobs (slower but works everywhere)
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] Using background jobs ($MAX_PARALLEL_JOBS max)" >> "$LOG_FILE"
    
    for item in "${rrd_files[@]}"; do
        IFS='|' read -r rrd_file host service <<< "$item"
        
        # Wait if we've hit max parallel jobs
        while [ $(jobs -r | wc -l) -ge "$MAX_PARALLEL_JOBS" ]; do
            sleep 0.1
        done
        
        # Process in background
        (
            points=$(process_rrd_file "$rrd_file" "$host" "$service" "$TEMP_DIR" "$RRDTOOL_BIN" "$INFLUX_URL" "$INFLUX_USER" "$INFLUX_PASS" "$LOG_FILE")
            echo "$points" >> "$TEMP_DIR/points_results.txt"
        ) &
    done
    
    # Wait for all background jobs to complete
    wait
    
    # Sum up all points
    if [ -f "$TEMP_DIR/points_results.txt" ]; then
        total_points=$(awk '{sum+=$1} END {print sum}' "$TEMP_DIR/points_results.txt")
    else
        total_points=0
    fi
fi

processed_files=$total_files
end_time=$(date +'%Y-%m-%d %H:%M:%S')

echo "[${end_time}] Migration complete - processed $processed_files files, $total_points data points" >> "$LOG_FILE"
echo "[${end_time}] Estimated speedup: $(($total_files / $MAX_PARALLEL_JOBS))x faster with parallel processing" >> "$LOG_FILE"
