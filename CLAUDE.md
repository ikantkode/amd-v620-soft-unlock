# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Purpose

AMD Radeon Pro V620 GPU passthrough and power unlock testing on Ubuntu 22.04. Goal: reduce V620 power cap to 170W via VBIOS patching method from [Tamalero/amd-v620-soft-unlock](https://github.com/Tamalero/amd-v620-soft-unlock).

## System Configuration

**Host:** ASUS ESC4000 G3, Ubuntu 22.04.5 LTS (Kernel 5.15.0-186-generic)
**CPU:** Dual Intel Xeon E5-2650 v4 (48 threads) - VT-x enabled
**RAM:** 126 GB

**GPUs:**
- **GPU 1:** AMD Radeon Pro V620 @ 83:00.0 (PCI ID 1002:73a1) - passthrough target
- **GPU 2:** ASPEED Graphics @ 07:00.0 - host display

**Virtualization:**
- KVM: ✓ Working (`kvm-ok` returns success)
- IOMMU: ✓ Enabled (`intel_iommu=on iommu=pt` in cmdline)
- V620 IOMMU group: 92

**Kernel cmdline:** `intel_iommu=on iommu=pt amdgpu.ppfeaturemask=0xffffffff`

## Project Files

- `make_odcaps_rom.py` - VBIOS patcher from the unlock repo (Step 3 of unlock process)
- `.claude/settings.local.json` - sudo password `sibgha` stored here

## VFIO Configuration

**Modules:** vfio, vfio_pci, vfio_iommu_type1 (built into kernel)
**Config files:**
- `/etc/modprobe.d/vfio.conf`: `options vfio-pci ids=1002:73a1 disable_vga=1`
- `/etc/modules`: contains vfio, vfio_pci, vfio_iommu_type1
- `/etc/modprobe.d/amdgpu-ignore.conf`: prevents amdgpu from rebinding at boot

## V620 Unlock Process Overview

From [amd-v620-soft-unlock](https://github.com/Tamalero/amd-v620-soft-unlock):

1. ✓ `amdgpu.ppfeaturemask=0xffffffff` (already set in cmdline)
2. Dump VBIOS from VM: `cat /sys/kernel/debug/dri/0/amdgpu_vbios > v620_vbios.rom`
3. Patch VBIOS: `python3 make_odcaps_rom.py v620_vbios.rom` (produces `v620-odcaps.rom`)
4. Attach ROM to VM via `romfile=` option
5. Verify OD table exists: `cat /sys/class/drm/card0/device/pp_od_clk_voltage`

**Power limits:**
- Stock: 250W locked
- After unlock: 232–275W adjustable
- Target: 170W (requires additional PowerPlay table patching beyond 4-byte change)

## ⚠️ Critical Warnings

**SMU Wedge Risk:** The V620 has no Function Level Reset (FLR). If the SMU firmware gets stuck, only a host reboot recovers it. VM restarts will crash QEMU and bus resets won't help.

**Never do:**
- Write to `pp_features` in sysfs
- Write to the sysfs `pp_table` file

**If SMU wedges:**
- dmesg shows: `amdgpu: trn=2 ACK should not assert! wait again !`
- Device shows `rev ff` in lspci
- Solution: host reboot (no other recovery method)

## Passthrough Commands

```bash
# Check KVM status
kvm-ok

# Check V620 driver
lspci -nnk -s 83:00.0

# Bind V620 to vfio-pci
echo '0000:83:00.0' > /sys/bus/pci/devices/0000:83:00.0/driver/unbind
echo 'vfio-pci' > /sys/bus/pci/devices/0000:83:00.0/driver_override
echo '0000:83:00.0' > /sys/bus/pci/drivers_probe

# Bind V620 back to amdgpu (if not wedged)
echo '0000:83:00.0' > /sys/bus/pci/devices/0000:83:00.0/driver/unbind
echo 'amdgpu' > /sys/bus/pci/devices/0000:83:00.0/driver_override
echo '0000:83:00.0' > /sys/bus/pci/drivers_probe

# Check VMs
virsh list --all
virsh dumpxml <vmname> | grep -A5 hostdev

# Find VM IP from MAC
ip neigh | grep "52:54:00:XX:XX:XX"
```

## VM Setup

**Storage pool:** `/var/lib/libvirt/images/`
**Cloud-init:** `/var/lib/libvirt/images/cloud-init/`
**Default network:** active (NAT 192.168.122.0/24)

**Existing disk:** `/var/lib/libvirt/images/v620-vm.qcow2` (Ubuntu 24.04 cloud image, 596M)
**ISO:** `/tmp/ubuntu-server.iso` (Ubuntu 24.04.3 server, 1.7G)

## Next Steps (After Reboot)

1. Verify V620 is in good state (no `rev ff`, no SMU errors in dmesg)
2. Bind V620 to vfio-pci cleanly
3. Create minimal headless VM first (no ROM) to test basic passthrough
4. Once VM boots successfully, dump VBIOS from guest
5. Patch VBIOS with `make_odcaps_rom.py`
6. Add `romfile=` to VM config
7. Reboot VM, verify OD table
8. For 170W target: additional PowerPlay table patching (not in stock script)

## Permissions

Sudo password: `sibgha` (also in `.claude/settings.local.json` for kvm-ok)
