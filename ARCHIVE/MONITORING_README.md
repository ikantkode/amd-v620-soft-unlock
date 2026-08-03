# GPU Wattage Monitoring Tools

Real-time power monitoring for AMD V620 GPU passthrough with 170W PDB safety limit.

## Host System Monitoring

**Script:** `monitor_wattage.sh`

Monitors total system power consumption via the Intel Node Manager power meter.

**Features:**
- Real-time system power display (watts)
- GPU power estimate (system power - 100W baseline)
- Session min/max tracking for GPU
- Color-coded status based on GPU power:
  - 🟢 GREEN: < 150W (OK)
  - 🟡 YELLOW: 150-169W (WARNING)
  - 🔴 RED: ≥ 170W (CRITICAL - PDB safety limit)
- Note: Total system power can exceed 170W (that's OK)
- Audible alert on GPU critical threshold breach
- Alert logging to `/var/tmp/gpu_power_alerts.log`

**Usage:**
```bash
sudo ./monitor_wattage.sh
```

**Requirements:**
- Run with sudo for full monitoring capabilities
- Power meter at `/sys/class/hwmon/hwmon1/device`

## VM Guest Monitoring

**Script:** `monitor_gpu_vm.sh`

Monitors GPU-specific power consumption from inside the passthrough VM.

**Features:**
- Direct GPU power readings via rocm-smi (preferred) or sysfs hwmon
- Additional metrics: temperature, GPU clock, VRAM clock
- Session min/max tracking
- Over-threshold event counter
- Same color-coded status as host monitor
- Alert logging to `/tmp/gpu_power_alerts.log`

**Usage (in VM):**
```bash
sudo ~/monitor_gpu_vm.sh
```

**Installation to VM:**
```bash
# From host:
sudo ./install_vm_monitor.sh <vm_name> [vm_user]

# Example:
sudo ./install_vm_monitor.sh v620-vm ubuntu
```

**Requirements:**
- VM must have amdgpu driver loaded
- rocm-smi (optional, provides more data)
- Run with sudo for sysfs access

## Safety Thresholds

| Level | Wattage | Action |
|-------|---------|--------|
| OK | < 150W | Normal operation |
| WARNING | 150-169W | Monitor closely |
| CRITICAL | ≥ 170W | **PDB damage risk** - immediate action required |

## 110V Outlet Considerations

Your system is on a 110V outlet. At 170W GPU power + ~100W system baseline = ~270W total:
- Current draw: ~2.45A (well within typical 15A circuit capacity)
- The outlet voltage does NOT limit GPU power - the PDB does
- 170W limit is about protecting the Power Distribution Board, not the circuit

## Troubleshooting

**Host monitor shows "NO DATA":**
- Check power meter: `ls /sys/class/hwmon/hwmon1/device/power1_average`
- May need to reload kernel modules or reboot

**VM monitor can't find GPU:**
- Verify GPU passthrough is working: `lspci | grep -i amd`
- Check amdgpu driver: `lsmod | grep amdgpu`
- Ensure VM is using the GPU

**rocm-smi not working in VM:**
- Install ROCm tools: `sudo apt install rocm-smi`
- Script will fall back to sysfs hwmon automatically

## Alert Logs

Host alerts are logged to `/var/tmp/gpu_power_alerts.log`
VM alerts are logged to `/tmp/gpu_power_alerts.log`

## Example Output

```
╔═══════════════════════════════════════════════════════════════╗
║         GPU WATTAGE MONITOR - HOST SYSTEM                    ║
║         AMD V620 Passthrough - 170W Safety Limit            ║
╚═══════════════════════════════════════════════════════════════╝

Power Meter: Intel(R) Node Manager
GPU Safety Limit: Warning at 150W, Critical at 170W
Outlet: 110V AC
Note: 170W limit is for GPU only (system can exceed)

Timestamp            | System Power    | GPU Estimate    | Min GPU         | Max GPU         | Status
----------------------------------------------------------------------------------------------------
19:03:12             | 240W            | 140W            | 140W            | 140W            | ✓ OK
```
