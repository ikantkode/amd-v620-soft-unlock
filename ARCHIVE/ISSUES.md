# Issues & Status

## Project Goal

Reduce AMD Radeon Pro V620 power cap from stock 250W to 170W via VBIOS patching, following the method from [Tamalero/amd-v620-soft-unlock](https://github.com/Tamalero/amd-v620-soft-unlock).

**Target:** 170W power cap for better power efficiency in VM passthrough scenario.

## Hardware

- **Host:** ASUS ESC4000 G3, Ubuntu 22.04.5 LTS (Kernel 5.15.0-186-generic)
- **CPU:** Dual Intel Xeon E5-2650 v4 (48 threads) - VT-x enabled
- **RAM:** 126 GB
- **GPU 1:** AMD Radeon Pro V620 @ 83:00.0 (PCI ID 1002:73a1) - passthrough target
- **GPU 2:** ASPEED Graphics @ 07:00.0 - host display

## Completed Steps

### 1. System Configuration
- ✓ KVM verified working (`kvm-ok` returns success)
- ✓ IOMMU enabled (`intel_iommu=on iommu=pt` in kernel cmdline)
- ✓ V620 IOMMU group identified: group 92
- ✓ Kernel cmdline updated: `intel_iommu=on iommu=pt amdgpu.ppfeaturemask=0xffffffff`

### 2. VFIO Configuration
- ✓ Configured `/etc/modprobe.d/vfio.conf` with V620 PCI ID
- ✓ Added vfio modules to `/etc/modules`
- ✓ Created `/etc/modprobe.d/amdgpu-ignore.conf` to prevent amdgpu rebinding at boot

### 3. Tools
- ✓ Acquired `make_odcaps_rom.py` VBIOS patcher from unlock repo

## Remaining Steps

### Phase 1: Basic Passthrough (Current Focus)
1. **Verify V620 health** - Ensure GPU is not wedged (no `rev ff`, no SMU errors in dmesg)
2. **Bind V620 to vfio-pci** - Unbind from amdgpu, bind to vfio-pci driver
3. **Create minimal headless VM** - No ROM attached yet, just test basic passthrough
4. **Boot VM successfully** - Verify GPU is visible and functional inside guest

### Phase 2: VBIOS Unlock
5. **Dump VBIOS from guest** - `cat /sys/kernel/debug/dri/0/amdgpu_vbios > v620_vbios.rom`
6. **Patch VBIOS** - Run `python3 make_odcaps_rom.py v620_vbios.rom` → `v620-odcaps.rom`
7. **Attach ROM to VM** - Add `romfile=` option to libvirt VM config
8. **Verify OD table** - Check `/sys/class/drm/card0/device/pp_od_clk_voltage` exists

### Phase 3: Power Limit Tuning
9. **Unlock PowerPlay table** - Current script only enables OD table (232-275W range)
10. **Achieve 170W target** - Requires additional PowerPlay table patching beyond stock script

## Known Issues/Risks

### SMU Wedge Risk (Critical)
The V620 has **no Function Level Reset (FLR)**. If SMU firmware wedges:
- Only a host reboot recovers it
- VM restarts will crash QEMU
- Bus resets will not help

**Symptoms of wedged SMU:**
- dmesg: `amdgpu: trn=2 ACK should not assert! wait again !`
- lspci shows device with `rev ff`

**Never write to:**
- `pp_features` in sysfs
- `pp_table` file in sysfs

### Hardware Beeping
Chassis alarm was beeping - recently resolved. May have been related to power delivery or GPU state changes.

## Files

- `make_odcaps_rom.py` - VBIOS patcher (Step 3 of unlock process)
- `.claude/settings.local.json` - Contains sudo password for operations
- `/etc/modprobe.d/vfio.conf` - VFIO configuration
- `/etc/modprobe.d/amdgpu-ignore.conf` - Prevents amdgpu rebinding

## Useful Commands

```bash
# Check V620 driver binding
lspci -nnk -s 83:00.0

# Check KVM
kvm-ok

# Bind V620 to vfio-pci
echo '0000:83:00.0' > /sys/bus/pci/devices/0000:83:00.0/driver/unbind
echo 'vfio-pci' > /sys/bus/pci/devices/0000:83:00.0/driver_override
echo '0000:83:00.0' > /sys/bus/pci/drivers_probe

# Check VMs
virsh list --all

# Find VM IP from MAC
ip neigh | grep "52:54:00:XX:XX:XX"
```

## Status

**Current Phase:** Phase 1 - Basic Passthrough Verification

**Last Action:** Hardware beeping issue resolved

**Next Action:** Verify V620 is in good state and bind to vfio-pci
