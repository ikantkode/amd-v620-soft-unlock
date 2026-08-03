# V620 Passthrough & 170W Unlock - COMPLETE ✓

**Last updated:** 2026-08-03 02:35
**Status:** ✅ FULLY OPERATIONAL

## Goal: ACHIEVED ✓

Reduced AMD Radeon Pro V620 power cap from 250W to **170W** via passthrough VM and VBIOS patching.

**Final Results:**
- **Power Range:** 158-187W (±10% of 170W base)
- **Target Power:** 170W set and verified
- **Clock Unlocks:** SCLK 500-2650 MHz, MCLK 674-1075 MHz
- **Use Case:** Ready for LLM inference

## Hardware

- **Host:** ASUS ESC4000 G3, Ubuntu 22.04.5 LTS (Kernel 5.15.0-186-generic)
- **CPU:** Dual Intel Xeon E5-2650 v4 (48 threads)
- **RAM:** 126 GB (expanded from 100GB)
- **GPU 1:** AMD Radeon Pro V620 @ 83:00.0 (PCI ID 1002:73a1) - passthrough target
- **GPU 2:** ASPEED Graphics @ 07:00.0 - host display
- **V620 Count:** 1 (only one installed in chassis)
- **VM Disk:** 500GB (expanded from 2.4GB)

---

## All Phases Complete ✓

### Phase 1: Hardware Verification ✓
- V620 healthy, no wedge
- amdgpu driver bound
- No SMU errors in dmesg

### Phase 2: VM Infrastructure ✓
- libvirt 8.0.0 installed and running
- QEMU 6.2.0 operational
- Storage pool at /var/lib/libvirt/images/

### Phase 3: VFIO Binding ✓
- V620 successfully bound to vfio-pci
- Clean handoff from amdgpu with no errors

### Phase 4: VM Creation ✓
- 500GB disk created and expanded
- OVMF firmware verified
- VM configured with q35 chipset

### Phase 5: Passthrough Verification ✓
- VM boots successfully
- V620 visible in guest at 05:00.0
- amdgpu driver loaded in guest
- SMU initialized with no wedge

### Phase 6: Guest OS Setup ✓
- Ubuntu 24.04.4 guest running
- linux-modules-extra installed (AMDGPU firmware)
- 500GB filesystem expanded

### Phase 7: Basic VBIOS Unlock ✓
- VBIOS dumped from guest: `v620_vbios.rom`
- Patched with `make_odcaps_rom.py`: `v620-odcaps.rom`
- ROM attached to VM via romfile
- Guest kernel: `amdgpu.ppfeaturemask=0xffffffff`

### Phase 8: OD Table Verification ✓
- OverDrive table active in guest
- Clock ranges unlocked: SCLK 500-2650 MHz, MCLK 674-1075 MHz
- Stock power range: 232-275W (base 250W ±10%)

### Phase 9: 170W Power Target ✓✓✓
**ADVANCED TUNING COMPLETE**

**Modified PowerPlay Table Offsets:**
- PP offset 0x032e: 170W (OD min power limit)
- PP offset 0x033e: 200W (OD max power limit)

**Final ROM:** `v620-170w-final.rom` deployed at `/usr/share/qemu/v620-170w-final.rom`

**Verification:**
```
Power Range: 158-187W
Current Power: 170W set
GPU Temp: 41°C idle
Power Usage: 8W idle
```

---

## Unlock Method Summary

The V620 unlock required two stages:

1. **Basic Unlock** (Stock Script)
   - Enabled OD capability flags (caps 0-3)
   - Exposed clock controls
   - Result: 232-275W range from 250W base

2. **Advanced Tuning** (Custom)
   - Located OD power limit fields in PowerPlay table
   - Modified min/max power limits directly
   - Result: 158-187W range with 170W target

**Key Discovery:** The OD power limits are stored at PP table offsets 0x032e (min) and 0x033e (max), not in the base TGP field.

---

## Deployment Files

| File | Location | Purpose |
|------|----------|---------|
| `v620-170w-final.rom` | `/usr/share/qemu/` | Final 170W unlocked VBIOS |
| `v620-vm-config.xml` | `/home/beefyboi/amdtests/` | VM libvirt config |
| `v620_vbios.rom` | `/home/beefyboi/amdtests/` | Original VBIOS dump |
| `make_odcaps_rom.py` | `/home/beefyboi/amdtests/amd-v620-soft-unlock/` | Stock unlock script |

---

## VM Configuration

**VM:** v620-test
**Guest:** Ubuntu 24.04.4 (kernel 6.8.0-136-generic)
**Network:** 192.168.122.54 (virbr0)
**Access:** SSH with key at `/tmp/vm-key`

**Kernel Args:** `amdgpu.ppfeaturemask=0xffffffff` (via `/etc/default/grub.d/50-cloudimg-settings.cfg`)

**Passthrough:** V620 at 83:00.0 → guest 05:00.0 via vfio-pci with custom ROM

---

## Usage Commands

### Check Power Limits
```bash
cat /sys/class/drm/card0/device/hwmon/hwmon*/power1_cap_{min,max}
```

### Set Power Target
```bash
echo 170000000 | sudo tee /sys/class/drm/card0/device/hwmon/hwmon*/power1_cap
```

### Check Clocks
```bash
cat /sys/class/drm/card0/device/pp_od_clk_voltage
```

### Set Clocks (example max)
```bash
d=/sys/class/drm/card0/device
echo "s 1 2650" > $d/pp_od_clk_voltage  # Core max
echo "m 1 1075" > $d/pp_od_clk_voltage  # VRAM max
echo "c" > $d/pp_od_clk_voltage         # Commit
```

---

## Critical Warnings

### SMU Wedge Risk
V620 has **no Function Level Reset (FLR)**. If SMU wedges:
- Only host reboot recovers it
- VM restarts will crash QEMU
- Bus resets will not help

**Symptoms:**
- dmesg: `amdgpu: trn=2 ACK should not assert! wait again !`
- lspci shows `rev ff`

**Never write to:**
- `pp_features` in sysfs
- `pp_table` file in sysfs

**ROM file is per-VM:** Moving the GPU to another VM requires re-attaching the ROM.

---

## Performance Notes

- **Idle Power:** ~8W at 170W cap
- **Idle Temps:** 34-41°C
- **Cooling:** Passive card requires adequate airflow
- **Clock Sensor:** Reads 0 MHz (known limitation - use benchmark to verify)
- **Throttling:** Junction and VRAM temps report correctly

---

## Project Complete

The V620 is now fully unlocked for LLM inference workloads at the optimized 170W power target. All clock controls are available, power management is functional, and the system is stable.

**Next Steps for User:**
1. Install LLM inference stack (ROCm, vLLM, etc.)
2. Benchmark at 170W target
3. Tune clocks for optimal inference performance
4. Monitor temperatures under load

---

## Repository Reference

Based on methods from [Tamalero/amd-v620-soft-unlock](https://github.com/Tamalero/amd-v620-soft-unlock) with custom PowerPlay table modifications for 170W target.
