# Test Scripts - Power Monitoring Tools

Real-time power monitoring tools for AMD V620 GPU passthrough with 170W safety limit.

## Overview

These scripts monitor GPU and system power consumption to ensure the V620 stays within the 170W PDB safety limit during operation.

**Important:** The 170W limit applies to GPU power only, not total system power. System power can and will exceed 170W during combined CPU+GPU loads.

## Folder Structure

```
TEST_SCRIPTS/
├── HOST_TESTS/              # Host-side monitoring
│   ├── monitor_wattage.sh              # Real-time system power monitor
│   └── concurrent_wattage_test.sh     # Concurrent load test (5 workloads)
└── VM_TESTS/                # VM-side monitoring
    ├── monitor_gpu_vm.sh               # Direct GPU power monitor (in VM)
    └── install_vm_monitor.sh           # Transfer script to VM
```

## Host Tests

### monitor_wattage.sh

Real-time system power monitoring with GPU power estimation.

**Features:**
- Reads from Intel Node Manager power meter
- Estimates GPU power (system - 100W baseline)
- Color-coded status: OK (green), WARNING (yellow), CRITICAL (red)
- Session min/max tracking
- Audible alert on GPU > 170W
- Logs to `/var/tmp/gpu_power_alerts.log`

**Usage:**
```bash
cd TEST_SCRIPTS/HOST_TESTS
sudo ./monitor_wattage.sh
```

**Output:**
```
Timestamp            | System Power    | GPU Estimate    | Min GPU         | Max GPU         | Status
----------------------------------------------------------------------------------------------------
19:03:12             | 240W            | 140W            | 140W            | 140W            | ✓ OK
```

**Safety Thresholds:**
- OK: < 150W GPU
- WARNING: 150-169W GPU
- CRITICAL: ≥ 170W GPU (PDB damage risk)

### concurrent_wattage_test.sh

Stress test with 5 concurrent workloads to validate power limits.

**Usage:**
```bash
cd TEST_SCRIPTS/HOST_TESTS
sudo ./concurrent_wattage_test.sh
```

**Test Duration:** 30 seconds

**Workload:** 5 concurrent CPU-intensive processes (openssl, sha256sum)

## VM Tests

### monitor_gpu_vm.sh

Direct GPU power monitoring from inside the passthrough VM.

**Features:**
- GPU-specific power readings via rocm-smi or sysfs
- Temperature, GPU clock, VRAM clock
- Session min/max tracking
- Over-threshold event counter
- Same color-coded status as host monitor
- Logs to `/tmp/gpu_power_alerts.log`

**Installation:**
```bash
cd TEST_SCRIPTS/VM_TESTS
sudo ./install_vm_monitor.sh v620-vm ubuntu
```

**Usage (in VM):**
```bash
sudo ~/monitor_gpu_vm.sh
```

**Output:**
```
Timestamp            | GPU Power       | Temp            | Clock           | VRAM            | Status
------------------------------------------------------------------------------------------
19:15:30             | 145W            | 65°C            | 1800MHz         | 1600MHz         | ✓ OK
```

### install_vm_monitor.sh

Helper script to transfer `monitor_gpu_vm.sh` to the VM.

**Usage:**
```bash
cd TEST_SCRIPTS/VM_TESTS
sudo ./install_vm_monitor.sh <vm_name> [vm_user]

# Example:
sudo ./install_vm_monitor.sh v620-vm ubuntu
```

The script:
1. Finds VM IP from MAC address
2. Copies `monitor_gpu_vm.sh` to VM
3. Makes it executable

## Test Results

### Concurrent Load Test (Host)

| Metric | Value | Status |
|--------|-------|--------|
| Baseline power | ~144W | ✓ OK |
| Peak system power | 232W | ✓ OK (system can exceed) |
| Peak GPU estimate | ~132W | ✓ OK (under 170W) |
| Duration | 30 seconds | ✓ Complete |
| Critical alerts | 0 (GPU) | ✓ Passed |

**Conclusion:** GPU stayed within safe limits during concurrent CPU load.

## Requirements

### Host Requirements

- Intel Node Manager power meter at `/sys/class/hwmon/hwmon1/device/power1_average`
- sudo access for hardware monitoring

### VM Requirements

- AMD GPU with amdgpu driver
- rocm-smi (optional, provides more data)
- sudo access for sysfs/hwmon

## Troubleshooting

### Host Monitor Shows "NO DATA"

**Check power meter:**
```bash
ls /sys/class/hwmon/hwmon1/device/power1_average
```

If missing, check available hwmon devices:
```bash
ls /sys/class/hwmon/
for i in /sys/class/hwmon/hwmon*/device/name; do echo "$i: $(cat $i)"; done
```

### VM Monitor Can't Find GPU

**Verify GPU passthrough:**
```bash
lspci | grep -i amd
```

**Check amdgpu driver:**
```bash
lsmod | grep amdgpu
ls /sys/class/drm/card0/device/
```

### rocm-smi Not Working

**Install ROCm in VM:**
```bash
wget -q -O - https://repo.radeon.com/rocm/rocm.gpg.key | sudo apt-key add -
echo 'deb [arch=amd64] https://repo.radeon.com/rocm/ubuntu/22.04 jammy main' | sudo tee /etc/apt/sources.list.d/rocm.list
sudo apt update
sudo apt install -y rocm-smi
```

Note: Script falls back to sysfs hwmon automatically.

## Alert Logs

- **Host:** `/var/tmp/gpu_power_alerts.log`
- **VM:** `/tmp/gpu_power_alerts.log`

## Safety Reminders

1. **170W limit is for GPU only** - System power will be higher
2. **Run with sudo** - Required for hardware access
3. **Critical alerts include beep** - Audio feedback for immediate awareness
4. **Test before production** - Validate limits under real workloads

## Quick Start

### Host Monitoring (Run Now)
```bash
cd /home/beefyboi/amdtests/TEST_SCRIPTS/HOST_TESTS
sudo ./monitor_wattage.sh
```

### VM Monitoring (After VM Setup)
```bash
# From host:
cd /home/beefyboi/amdtests/TEST_SCRIPTS/VM_TESTS
sudo ./install_vm_monitor.sh v620-vm ubuntu

# Then in VM:
sudo ~/monitor_gpu_vm.sh
```

## References

- Host power monitoring: Intel Node Manager documentation
- GPU power monitoring: amdgpu sysfs interface
- ROCm tools: [ROCm Documentation](https://rocm.docs.amd.com/)
