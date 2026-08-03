#!/bin/bash
# GPU Wattage Monitor - Host System Script
# Monitors total system power consumption with GPU passthrough context
# Designed for AMD V620 passthrough with 170W safety limit

# Configuration
WARNING_THRESHOLD=150     # Yellow alert threshold (Watts)
CRITICAL_THRESHOLD=170    # Red alert threshold (Watts) - PDB safety limit
UPDATE_INTERVAL=1         # Seconds between updates
HWMON_PATH="/sys/class/hwmon/hwmon1/device"

# Colors
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Check if running as root for best results
if [[ $EUID -ne 0 ]]; then
    echo -e "${YELLOW}Warning: Not running as root. Some readings may be limited.${NC}"
    echo "Run with sudo for full monitoring capabilities."
    echo ""
fi

# Check power meter availability
if [[ ! -f "${HWMON_PATH}/power1_average" ]]; then
    echo -e "${RED}ERROR: Power meter not found at ${HWMON_PATH}${NC}"
    echo "Available hwmon devices:"
    ls -la /sys/class/hwmon/hwmon*/device/name 2>/dev/null | while read line; do
        path=$(echo "$line" | cut -d':' -f1 | cut -d' ' -f9-)
        name=$(cat "${line%%:*}" 2>/dev/null)
        echo "  - $name"
    done
    exit 1
fi

# Get power meter info
POWER_MODEL=$(cat "${HWMON_PATH}/power1_model_number" 2>/dev/null || echo "Unknown")
POWER_SERIAL=$(cat "${HWMON_PATH}/power1_serial_number" 2>/dev/null || echo "Unknown")

# Display header
clear
cat << "EOF"
╔═══════════════════════════════════════════════════════════════╗
║         GPU WATTAGE MONITOR - HOST SYSTEM                    ║
║         AMD V620 Passthrough - 170W Safety Limit            ║
╚═══════════════════════════════════════════════════════════════╝
EOF

echo -e "${CYAN}Power Meter:${NC} $POWER_MODEL (S/N: $POWER_SERIAL)"
echo -e "${CYAN}GPU Safety Limit:${NC} Warning at ${WARNING_THRESHOLD}W, Critical at ${CRITICAL_THRESHOLD}W"
echo -e "${CYAN}Outlet:${NC} 110V AC"
echo -e "${CYAN}Note:${NC} 170W limit is for GPU only (system can exceed)"
echo ""
echo "Press Ctrl+C to exit"
echo ""
printf "${BOLD}%-20s | %-15s | %-15s | %-15s | %-15s | %-10s${NC}\n" "Timestamp" "System Power" "GPU Estimate" "Min GPU" "Max GPU" "Status"
echo "----------------------------------------------------------------------------------------------------"

# Initialize variables
min_power=999999
max_power=0
min_gpu=999999
max_gpu=0
alert_triggered=false
SYSTEM_BASELINE=100  # Baseline system power without GPU load

# Monitoring loop
while true; do
    # Read current power (in microwatts)
    power_uw=$(cat "${HWMON_PATH}/power1_average" 2>/dev/null)

    if [[ -z "$power_uw" ]] || [[ "$power_uw" == "0" ]]; then
        power_w="N/A"
        gpu_estimate="N/A"
        status="${YELLOW}NO DATA${NC}"
        color="$YELLOW"
    else
        # Convert to watts
        power_w=$((power_uw / 1000000))

        # Track system min/max
        if [[ $power_w -lt $min_power ]]; then
            min_power=$power_w
        fi
        if [[ $power_w -gt $max_power ]]; then
            max_power=$power_w
        fi

        # Calculate GPU contribution estimate (baseline subtracted)
        gpu_estimate=$((power_w - SYSTEM_BASELINE))
        if [[ $gpu_estimate -lt 0 ]]; then
            gpu_estimate=0
        fi

        # Track GPU min/max
        if [[ $gpu_estimate -lt $min_gpu ]]; then
            min_gpu=$gpu_estimate
        fi
        if [[ $gpu_estimate -gt $max_gpu ]]; then
            max_gpu=$gpu_estimate
        fi

        # Determine status based on GPU power (not system power)
        if [[ $gpu_estimate -ge $CRITICAL_THRESHOLD ]]; then
            status="${RED}⚠ CRITICAL${NC}"
            color="$RED"
            if [[ "$alert_triggered" == "false" ]]; then
                alert_triggered=true
                # System beep
                echo -e "\a" 2>/dev/null
                # Log critical event
                echo "$(date): CRITICAL GPU POWER: ${gpu_estimate}W exceeds ${CRITICAL_THRESHOLD}W" >> /var/tmp/gpu_power_alerts.log
            fi
        elif [[ $gpu_estimate -ge $WARNING_THRESHOLD ]]; then
            status="${YELLOW}⚠ WARNING${NC}"
            color="$YELLOW"
            alert_triggered=false
        else
            status="${GREEN}✓ OK${NC}"
            color="$GREEN"
            alert_triggered=false
        fi
    fi

    # Display current reading
    timestamp=$(date +"%H:%M:%S")
    printf "${color}%-20s | %-15s | %-15s | %-15s | %-15s | %-10s${NC}\n" \
        "$timestamp" "${power_w}W" "${gpu_estimate}W" "${min_gpu}W" "${max_gpu}W" "$status"

    sleep $UPDATE_INTERVAL
done
