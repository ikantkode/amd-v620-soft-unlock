# V620 Power Cap Unlock - VBIOS Modification

VBIOS patches and tools for AMD Radeon Pro V620 power cap unlock.

## Files

### Core Files

- **`make_odcaps_rom.py`** - VBIOS patcher script (from [Tamalero/amd-v620-soft-unlock](https://github.com/Tamalero/amd-v620-soft-unlock))
- **`v620_vbios.rom`** - Original VBIOS dump from V620 GPU
- **`v620-odcaps.rom`** - Patched VBIOS with OverDrive tables enabled
- **`v620-vm-config.xml`** - Working libvirt VM configuration with GPU passthrough

### Experimental Files

- **`v620-170w.rom`** - Early 170W limit attempt (experimental)
- **`v620-170w-test.rom`** - Test ROM for 170W validation
- **`v620-170w-final.rom`** - Final 170W attempt (requires additional PowerPlay table patching)

## Usage

### Step 1: Dump VBIOS from GPU

From host with amdgpu driver bound:

```bash
# Bind V620 to amdgpu temporarily
echo '0000:83:00.0' | sudo tee /sys/bus/pci/devices/0000:83:00.0/driver/unbind
echo 'amdgpu' | sudo tee /sys/bus/pci/devices/0000:83:00.0/driver_override
echo '0000:83:00.0' | sudo tee /sys/bus/pci/drivers_probe

# Dump VBIOS
sudo cat /sys/kernel/debug/dri/0/amdgpu_vbios > v620_vbios.rom

# Rebind to vfio-pci for passthrough
echo '0000:83:00.0' | sudo tee /sys/bus/pci/devices/0000:83:00.0/driver/unbind
echo 'vfio-pci' | sudo tee /sys/bus/pci/devices/0000:83:00.0/driver_override
echo '0000:83:00.0' | sudo tee /sys/bus/pci/drivers_probe
```

### Step 2: Patch VBIOS

```bash
python3 make_odcaps_rom.py v620_vbios.rom
```

Output: `v620-odcaps.rom`

This enables OverDrive tables, allowing power limit adjustment from 232W to 275W.

### Step 3: Load Patched ROM in VM

Copy ROM to system location:

```bash
sudo mkdir -p /usr/share/qemu/
sudo cp v620-odcaps.rom /usr/share/qemu/v620-odcaps.rom
sudo chmod 644 /usr/share/qemu/v620-odcaps.rom
```

Add to VM config (`virsh edit v620-vm`):

```xml
<hostdev mode='subsystem' type='pci' managed='no'>
  <driver name='vfio'/>
  <source>
    <address domain='0x0000' bus='0x83' slot='0x00' function='0x0'/>
  </source>
  <address type='pci' domain='0x0000' bus='0x06' slot='0x00' function='0x0'/>
  <rom file='/usr/share/qemu/v620-odcaps.rom'/>
</hostdev>
```

### Step 4: Verify OD Unlock

In VM after boot:

```bash
# Check if OD table exists
cat /sys/class/drm/card0/device/pp_od_clk_voltage
```

If this file exists and shows clock/voltage tables, the unlock worked!

## Power Limit Control

### Check Power Limits

```bash
# Current power cap
cat /sys/class/drm/card0/device/hwmon/hwmon*/power1_cap

# Max power cap
cat /sys/class/drm/card0/device/hwmon/hwmon*/power1_cap_max

# Min power cap
cat /sys/class/drm/card0/device/hwmon/hwmon*/power1_cap_min
```

After OD unlock, expect:
- Min: ~232W
- Max: ~275W

### Set 170W Limit

```bash
# Set 170W (170000000 microwatts)
echo 170000000 | sudo tee /sys/class/drm/card0/device/hwmon/hwmon*/power1_cap
```

Note: This works if the PowerPlay table allows it. The standard script only enables OD tables - full 170W requires additional patching.

## VM Configuration

See `v620-vm-config.xml` for complete working VM configuration.

Key features:
- KVM with host-passthrough CPU
- 16GB RAM, 16 vCPUs
- UEFI boot with OVMF
- V620 GPU passthrough with ROM file
- Serial console for headless operation

Define VM from XML:

```bash
sudo virsh define v620-vm-config.xml
sudo virsh start v620-vm
sudo virsh console v620-vm
```

## Important Notes

### SMU Wedge Risk

The V620 has no Function Level Reset (FLR). Improper operations can permanently wedge the SMU until host reboot.

**Never do:**
- Write to `/sys/class/drm/card0/device/pp_features`
- Write to `/sys/class/drm/card0/device/pp_table`
- Force reboot VM without proper shutdown

**If SMU wedges:**
- dmesg shows: `amdgpu: trn=2 ACK should not assert!`
- lspci shows `rev ff` for GPU
- Solution: Host reboot (no other recovery)

### Power Limit Requirements

Standard `make_odcaps_rom.py` enables 232-275W range. For true 170W limit, you need additional PowerPlay table patching beyond the 4-byte change.

## Troubleshooting

### ROM Not Loading

Check QEMU log:

```bash
sudo journalctl -u libvirtd | grep -i rom
```

Verify ROM file:

```bash
sudo ls -la /usr/share/qemu/v620-odcaps.rom
md5sum v620-odcaps.rom
```

### No OD Table After Flash

1. Verify ROM is being loaded (check QEMU log)
2. Check amdgpu ppfeaturemask: `cat /proc/cmdline | grep ppfeaturemask`
3. Should show `0xffffffff`

## Credits

VBIOS patching methodology from:
[Tamalero/amd-v620-soft-unlock](https://github.com/Tamalero/amd-v620-soft-unlock)
