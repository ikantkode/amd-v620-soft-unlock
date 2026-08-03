#!/bin/bash
# GPU Wattage Monitor - VM Guest Script
# Monitors AMD GPU power consumption from inside the VM
# Run this inside the passthrough VM for direct GPU power readings

# Configuration
WARNING_THRESHOLD=150     # Yellow alert threshold (Watts)
CRITICAL_THRESHOLD=170    # Red alert threshold (Watts) - PDB safety limit
UPDATE_INTERVAL=0.5       # Seconds between updates

# Colors
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Find GPU card number
find_gpu_card() {
    for i in /sys/class/drm/card*/device/; do
        if [[ -d "$i/hwmon" ]] || grep -q "amdgpu" "${i}uevent" 2>/dev/null; then
            echo "$(basename $(dirname "$i"))"
            return 0
        fi
    done
    return 1
}

GPU_CARD=$(find_gpu_card)

if [[ -z "$GPU_CARD" ]]; then
    echo -e "${RED}ERROR: No AMD GPU found. Make sure amdgpu driver is loaded.${NC}"
    echo "This script must run inside the VM with GPU passthrough."
    exit 1
fi

# Try rocm-smi first (more accurate), fall back to sysfs
USE_ROCM_SMI=false
if command -v rocm-smi &> /dev/null; then
    if rocm-smi -d 0 --showpower &> /dev/null; then
        USE_ROCM_SMI=true
    fi
fi

# Find hwmon path for sysfs fallback
if [[ "$USE_ROCM_SMI" == "false" ]]; then
    HWMON_PATH=$(find /sys/class/drm/${GPU_CARD}/device/hwmon/ -name "power1_average" -dirname 2>/dev/null | head -1)
    if [[ -z "$HWMON_PATH" ]]; then
        echo -e "${RED}ERROR: Cannot find GPU power monitoring interface.${NC}"
        echo "rocm-smi unavailable and sysfs hwmon not found."
        exit 1
    fi
fi

# Get GPU info
GPU_NAME=$(cat /sys/class/drm/${GPU_CARD}/device/product_name 2>/dev/null || echo "AMD GPU")
GPU_ID=$(cat /sys/class/drm/${GPU_CARD}/device/unique_id 2>/dev/null | tr -d ' ' || echo "Unknown")

# Display header
clear
cat << "EOF"
╔═══════════════════════════════════════════════════════════════╗
║         GPU WATTAGE MONITOR - VM GUEST                       ║
║         Direct GPU Power Monitoring                          ║
║         170W PDB Safety Limit                                ║
╚═══════════════════════════════════════════════════════════════╝
EOF

echo -e "${CYAN}GPU:${NC} $GPU_NAME"
echo -e "${CYAN}ID:${NC} $GPU_ID"
echo -e "${CYAN}Card:${NC} $GPU_CARD"
echo -e "${CYAN}Method:${NC} $([ "$USE_ROCM_SMI" == "true" ] && echo "rocm-smi" || echo "sysfs hwmon")"
echo -e "${CYAN}Safety Limits:${NC} Warning at ${WARNING_THRESHOLD}W, Critical at ${CRITICAL_THRESHOLD}W"
echo ""
echo "Press Ctrl+C to exit"
echo ""

# Print table header
printf "${BOLD}%-20s | %-12s | %-12s | %-12s | %-12s | %-10s${NC}\n" \
    "Timestamp" "GPU Power" "Temp" "Clock" "VRAM" "Status"
echo "------------------------------------------------------------------------------------------"

# Initialize variables
min_power=999999
max_power=0
alert_triggered=false
over_threshold_count=0

# Monitoring loop
while true; do
    timestamp=$(date +"%H:%M:%S")

    if [[ "$USE_ROCM_SMI" == "true" ]]; then
        # Use rocm-smi for comprehensive data
        smi_output=$(rocm-smi -d 0 --showpower --showtemp --showclocks 2>/dev/null | grep -E "GPU|Average Power|Temperature|sclk|mclk" | tr -d '\r')

        # Parse rocm-smi output
        gpu_power=$(echo "$smi_output" | grep -i "Average Power" | grep -oE "[0-9]+\.[0-9]+" | head -1)
        temp=$(echo "$smi_output" | grep -i "Temperature (Edge)" | grep -oE "[0-9]+" | head -1)
        sclk=$(echo "$smi_output" | grep -i "sclk:" | grep -oE "[0-9]+" | head -1)
        mclk=$(echo "$smi_output" | grep -i "mclk:" | grep -oE "[0-9]+" | head -1)

        # rocm-smi reports in watts, might need conversion
        if [[ -n "$gpu_power" ]]; then
            power_int=$(echo "$gpu_power" | cut -d'.' -f1)
        else
            power_int=""
        fi
    else
        # Use sysfs hwmon
        power_uw=$(cat "${HWMON_PATH}/power1_average" 2>/dev/null)
        temp=$(cat "${HWMON_PATH}/temp1_input" 2>/dev/null)
        temp=$((temp / 1000))  # Convert to Celsius

        if [[ -n "$power_uw" ]] && [[ "$power_uw" != "0" ]]; then
            power_int=$((power_uw / 1000000))
        else
            power_int=""
        fi

        # Clock speeds via sysfs (might not be available)
        sclk=$(cat /sys/class/drm/${GPU_CARD}/device/gt_cur_freq_mhz 2>/dev/null || echo "N/A")
        mclk=$(cat /sys/class/drm/${GPU_CARD}/device/mem_cur_freq_mhz 2>/dev/null || echo "N/A")
    fi

    # Process power reading
    if [[ -z "$power_int" ]] || [[ -z "${power_int//0/}" ]]; then
        power_display="N/A"
        temp_display=${temp:-"N/A"}
        sclk_display=${sclk:-"N/A"}
        mclk_display=${mclk:-"N/A"}
        status="${YELLOW}NO DATA${NC}"
        color="$YELLOW"
    else
        power_display="${power_int}W"
        temp_display="${temp}°C"
        sclk_display="${sclk}MHz"
        mclk_display="${mclk}MHz"

        # Track min/max
        if [[ $power_int -lt $min_power ]]; then
            min_power=$power_int
        fi
        if [[ $power_int -gt $max_power ]]; then
            max_power=$power_int
        fi

        # Determine status
        if [[ $power_int -ge $CRITICAL_THRESHOLD ]]; then
            status="${RED}⚠ CRITICAL${NC}"
            color="$RED"
            over_threshold_count=$((over_threshold_count + 1))
            if [[ "$alert_triggered" == "false" ]]; then
                alert_triggered=true
                # System beep
                echo -e "\a" 2>/dev/null
                # Log critical event
                echo "$(date): CRITICAL GPU POWER: ${power_int}W exceeds ${CRITICAL_THRESHOLD}W" >> /tmp/gpu_power_alerts.log
            fi
        elif [[ $power_int -ge $WARNING_THRESHOLD ]]; then
            status="${YELLOW}⚠ WARNING${NC}"
            color="$YELLOW"
            alert_triggered=false
        else
            status="${GREEN}✓ OK${NC}"
            color="$GREEN"
            alert_triggered=false
        fi
    fi

    # Display reading
    printf "${color}%-20s | %-12s | %-12s | %-12s | %-12s | %-10s${NC}\n" \
        "$timestamp" "$power_display" "$temp_display" "$sclk_display" "$mclk_display" "$status"

    # Show min/max periodically
    if [[ $(( ($(date +%s) % 10) )) == 0 ]]; then
        printf "${CYAN}%-20s   Session Min: %dW | Max: %dW | Over-threshold events: %d${NC}\n" \
            "" "$min_power" "$max_power" "$over_threshold_count"
    fi

    sleep $UPDATE_INTERVAL
done
