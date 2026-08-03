# AMD V620 GPU Passthrough & Power Cap Unlock

Complete project documentation for AMD Radeon Pro V620 GPU passthrough with 170W power limit protection on Ubuntu 22.04 LTS.

## Quick Navigation

📖 **[Project Overview](AMD_V620_POWER_LIMIT/README.md)** - Complete findings and test results

🚀 **[System Setup](AMD_V620_POWER_LIMIT/SETUP.md)** - Fresh Ubuntu installation and virtualization setup

🎮 **[GPU Passthrough](AMD_V620_POWER_LIMIT/GPU_PASSTHROUGH.md)** - Complete VM creation and GPU passthrough guide

🔧 **[VBIOS Unlock](V620_POWER_CAP_UNLOCK/README.md)** - Power cap unlock tools and patched ROMs

📊 **[Test Scripts](TEST_SCRIPTS/README.md)** - Power monitoring and validation tools

## Project Structure

```
amdtests/
├── AMD_V620_POWER_LIMIT/           # Main documentation
│   ├── SETUP.md                     # System setup guide
│   ├── GPU_PASSTHROUGH.md          # Passthrough instructions
│   └── README.md                   # Project overview & findings
├── V620_POWER_CAP_UNLOCK/          # VBIOS modification
│   ├── README.md                    # Unlock guide
│   ├── make_odcaps_rom.py          # VBIOS patcher
│   ├── v620_vbios.rom              # Original VBIOS
│   ├── v620-odcaps.rom             # Patched VBIOS (OD enabled)
│   ├── v620-vm-config.xml          # Working VM config
│   └── v620-170w-*.rom             # Experimental 170W ROMs
├── TEST_SCRIPTS/                   # Monitoring tools
│   ├── README.md                    # Test documentation
│   ├── HOST_TESTS/                 # Host monitoring
│   │   ├── monitor_wattage.sh      # System power monitor
│   │   └── concurrent_wattage_test.sh  # Stress test
│   └── VM_TESTS/                   # VM monitoring
│       ├── monitor_gpu_vm.sh       # GPU power monitor
│       └── install_vm_monitor.sh   # Transfer script
└── CLAUDE.md                       # Claude Code project context
```

## Hardware

**System:** ASUS ESC4000 G3
- **GPU:** AMD Radeon Pro V620 @ 83:00.0 (PCI ID 1002:73a1)
- **CPU:** Dual Intel Xeon E5-2650 v4 (48 threads)
- **RAM:** 126 GB
- **Power:** 110V AC

## Key Findings

✅ **GPU passthrough working** - V620 successfully passed through to Ubuntu 24.04 VM
✅ **Power unlock confirmed** - OverDrive tables enabled via patched VBIOS
✅ **170W limit achievable** - Set via sysfs `power1_cap` control
✅ **Monitoring validated** - Power tracking confirmed under concurrent load

### Test Results (5 Concurrent Workloads)

| Metric | Value | Status |
|--------|-------|--------|
| Baseline system power | ~144W | ✓ OK |
| Peak system power | 232W | ✓ OK (system can exceed 170W) |
| Peak GPU estimate | ~132W | ✓ OK (under 170W limit) |
| Critical alerts | 0 | ✓ Passed |

## Quick Start

### 1. Setup Host System
```bash
# Follow complete setup guide
cat AMD_V620_POWER_LIMIT/SETUP.md
```

### 2. Create VM with GPU Passthrough
```bash
# Follow passthrough guide
cat AMD_V620_POWER_LIMIT/GPU_PASSTHROUGH.md
```

### 3. Monitor Power (Optional)
```bash
# Host monitoring
sudo ./TEST_SCRIPTS/HOST_TESTS/monitor_wattage.sh

# VM monitoring (after VM setup)
sudo ./TEST_SCRIPTS/VM_TESTS/install_vm_monitor.sh v620-vm ubuntu
```

## Critical Warnings

⚠️ **SMU Wedge Risk:** V620 has no Function Level Reset. If SMU wedges, only host reboot recovers.

⚠️ **Never write to:** `pp_features` or `pp_table` in sysfs

⚠️ **170W is GPU limit:** Total system power can and will exceed 170W

## Safety Status

- **PDB Protection:** 170W GPU limit prevents Power Distribution Board damage
- **Circuit Safety:** 110V outlet ~2.5A at 270W total (within 15A circuit capacity)
- **Monitoring:** Real-time alerts via test scripts

## Credits

- VBIOS unlocking: [Tamalero/amd-v620-soft-unlock](https://github.com/Tamalero/amd-v620-soft-unlock)
- GPU passthrough reference: [passthroughpo.st](https://passthroughpo.st/)

---

**Last Updated:** 2025-08-03
**Status:** Working (GPU passthrough functional, power control confirmed)
