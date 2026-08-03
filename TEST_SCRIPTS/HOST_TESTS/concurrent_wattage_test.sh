#!/bin/bash
# Concurrent Load Test with Wattage Monitoring
# Runs 5 concurrent workloads while monitoring power consumption

PASSWORD="sibgha"
DURATION=30  # seconds
MONITOR_LOG="/tmp/wattage_test.log"

echo "=========================================="
echo "CONCURRENT WATTAGE TEST"
echo "Duration: ${DURATION}s"
echo "Concurrent jobs: 5"
echo "Safety limit: 170W"
echo "=========================================="
echo ""

# Start monitoring in background
echo "Starting wattage monitor..."
sudo -S pkill -9 monitor_wattage.sh 2>/dev/null
sleep 1

echo "$PASSWORD" | sudo -S bash /home/beefyboi/amdtests/monitor_wattage.sh > "$MONITOR_LOG" 2>&1 &
MONITOR_PID=$!

echo "Monitor started (PID: $MONITOR_PID)"
sleep 2

# Create 5 concurrent workloads (CPU-intensive)
echo "Starting 5 concurrent workloads..."
echo ""

# Workload function: compress/decompress data (CPU load)
workload() {
    local id=$1
    local end_time=$(($(date +%s) + DURATION))
    while [[ $(date +%s) -lt $end_time ]]; do
        # Mix of CPU operations
        openssl rand -base64 1000000 > /dev/null 2>&1
        sha256sum /dev/zero | head -c 100 > /dev/null
        cat /proc/interrupts > /dev/null
        sleep 0.1
    done
    echo "Workload $id completed"
}

# Launch 5 concurrent workloads
for i in {1..5}; do
    workload $i &
    PIDS[$i]=$!
    echo "Started workload $i (PID: ${PIDS[$i]})"
done

echo ""
echo "All workloads running. Monitoring power..."
echo "Will run for ${DURATION} seconds..."
echo ""

# Wait for workloads with progress indicator
start_time=$(date +%s)
while [[ $(($(date +%s) - start_time)) -lt $DURATION ]]; do
    elapsed=$(($(date +%s) - start_time))
    remaining=$((DURATION - elapsed))
    echo -ne "\rElapsed: ${elapsed}s / ${DURATION}s (${remaining}s remaining)    "
    sleep 1
done

echo ""
echo ""
echo "=========================================="
echo "TEST COMPLETE"
echo "=========================================="
echo ""
echo "Waiting for monitor logs..."
sleep 2

# Kill monitor
sudo -S kill $MONITOR_PID 2>/dev/null

# Analyze results
echo "=========================================="
echo "WATTAGE TEST RESULTS"
echo "=========================================="

if [[ -f "$MONITOR_LOG" ]]; then
    echo ""
    echo "Sample readings (last 10 lines):"
    echo "-----------------------------------"
    tail -10 "$MONITOR_LOG" | grep -E "\|[0-9]+W\|" || echo "No power readings captured"
    echo ""

    # Find max power
    max_power=$(grep -oE '[0-9]+W' "$MONITOR_LOG" | tr -d 'W' | sort -n | tail -1 2>/dev/null)
    if [[ -n "$max_power" ]]; then
        echo "Peak power observed: ${max_power}W"
        if [[ $max_power -ge 170 ]]; then
            echo "❌ EXCEEDED 170W LIMIT!"
        elif [[ $max_power -ge 150 ]]; then
            echo "⚠️  WARNING: Approached 170W limit"
        else
            echo "✅ Within safe operating range"
        fi
    fi

    # Check for critical alerts
    critical_count=$(grep -c "CRITICAL" "$MONITOR_LOG" 2>/dev/null || echo "0")
    if [[ $critical_count -gt 0 ]]; then
        echo ""
        echo "⚠️  CRITICAL alerts detected: $critical_count"
        echo "Check log: $MONITOR_LOG"
    else
        echo "✅ No critical alerts"
    fi
else
    echo "ERROR: Monitor log not found"
fi

echo ""
echo "Full monitor log: $MONITOR_LOG"
echo "=========================================="
