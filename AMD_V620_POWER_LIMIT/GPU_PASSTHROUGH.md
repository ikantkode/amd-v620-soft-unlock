# AMD V620 GPU Passthrough Guide

Complete guide for creating a VM with AMD Radeon Pro V620 GPU passthrough and power cap unlock.

## Prerequisites

- Complete `SETUP.md` first
- V620 bound to vfio-pci: `lspci -nnk -s 83:00.0` should show `Kernel driver in use: vfio-pci`
- libvirt network active: `sudo virsh net-list` should show `default` as active

## Step 1: Create Base VM (Without GPU)

### 1.1 Download Ubuntu Server ISO

```bash
wget https://releases.ubuntu.com/24.04/ubuntu-24.04.3-live-server-amd64.iso -O /tmp/ubuntu-server.iso
```

### 1.2 Create Cloud-Init Configuration

```bash
sudo vim /var/lib/libvirt/images/cloud-init/meta-data
```

Add:

```yaml
instance-id: v620-vm
local-hostname: v620-vm
```

```bash
sudo vim /var/lib/libvirt/images/cloud-init/user-data
```

Add:

```yaml
#cloud-config
users:
  - name: ubuntu
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys:
      - YOUR_SSH_PUBLIC_KEY_HERE

chpasswd:
  list: |
    ubuntu:ubuntu
  expire: False

packages:
  - ubuntu-server
  - linux-image-generic

runcmd:
  - [ apt, update ]
  - [ apt, upgrade, -y ]
  - [ apt, install, -y, build-essential, git, vim, curl, wget ]
  - [ systemctl, enable, ssh ]
```

Generate cloud-init ISO:

```bash
sudo cloud-localds /var/lib/libvirt/images/cloud-init/v620-vm-seed.iso \
  /var/lib/libvirt/images/cloud-init/user-data \
  /var/lib/libvirt/images/cloud-init/meta-data
```

### 1.3 Create VM Disk

```bash
sudo qemu-img create -f qcow2 /var/lib/libvirt/images/v620-vm.qcow2 100G
```

### 1.4 Create Initial VM (Headless, No GPU)

```bash
sudo virt-install \
  --name v620-vm \
  --memory 16384 \
  --vcpus 16 \
  --cpu host-passthrough \
  --disk path=/var/lib/libvirt/images/v620-vm.qcow2,bus=virtio,cache=writeback \
  --cdrom /tmp/ubuntu-server.iso \
  --network network=default,model=virtio \
  --graphics none \
  --console pty,target_type=serial \
  --os-variant ubuntu24.04 \
  --boot uefi \
  --install no-exit
```

### 1.5 Verify VM Boots

```bash
sudo virsh console v620-vm
# Press Ctrl+] to exit console
```

## Step 2: Dump VBIOS from GPU

### 2.1 Install amdgpu Driver Temporarily in VM

```bash
# From VM console
sudo apt update
sudo apt install -y linux-headers-generic
sudo apt install -y amdgpu-dkms firmware-amd-graphics
```

### 2.2 Enable PP Feature Mask

On host, edit VM config to add kernel parameter:

```bash
sudo virsh edit v620-vm
```

Add to `<kernel>` or `<boot>` section:

```xml
<cmdline>amdgpu.ppfeaturemask=0xffffffff</cmdline>
```

Or in `<domain>` section:

```xml
<os>
  <type arch='x86_64' machine='pc-q35-6.2'>hvm</type>
  <boot dev='hd'/>
  <kernel>/boot/vmlinuz</kernel>
  <cmdline>root=/dev/vda1 ro amdgpu.ppfeaturemask=0xffffffff</cmdline>
</os>
```

### 2.3 Dump VBIOS

From inside VM after amdgpu driver loads:

```bash
# Find GPU card number
ls /sys/class/drm/

# Dump VBIOS
sudo cat /sys/kernel/debug/dri/0/amdgpu_vbios > ~/v620_vbios.rom

# Copy to host (from host machine)
# Use scp or shared directory
```

Alternative: Dump from host with amdgpu bound:

```bash
# Unbind V620 from vfio-pci temporarily
echo '0000:83:00.0' | sudo tee /sys/bus/pci/devices/0000:83:00.0/driver/unbind
echo 'amdgpu' | sudo tee /sys/bus/pci/devices/0000:83:00.0/driver_override
echo '0000:83:00.0' | sudo tee /sys/bus/pci/drivers_probe

# Dump VBIOS
sudo cat /sys/kernel/debug/dri/0/amdgpu_vbios > ~/v620_vbios.rom

# Rebind to vfio-pci for passthrough
echo '0000:83:00.0' | sudo tee /sys/bus/pci/devices/0000:83:00.0/driver/unbind
echo 'vfio-pci' | sudo tee /sys/bus/pci/devices/0000:83:00.0/driver_override
echo '0000:83:00.0' | sudo tee /sys/bus/pci/drivers_probe
```

Copy VBIOS to project directory:

```bash
cp ~/v620_vbios.rom /home/beefyboi/amdtests/V620_POWER_CAP_UNLOCK/
```

## Step 3: Patch VBIOS for Power Cap Unlock

### 3.1 Use VBIOS Patcher

```bash
cd /home/beefyboi/amdtests/V620_POWER_CAP_UNLOCK/
python3 make_odcaps_rom.py v620_vbios.rom
```

This creates `v620-odcaps.rom` with OverDrive tables enabled.

### 3.2 Set 170W Power Limit (Additional Patching)

**Note:** The standard script only enables OD tables (232-275W range). To achieve 170W limit requires additional PowerPlay table patching beyond the 4-byte change.

For full 170W unlock, you need to:
1. Enable OD tables (done by script)
2. Modify PowerPlay table for 170W limit (requires hex editing or additional script)

### 3.3 Copy ROM to Host Location

```bash
sudo mkdir -p /usr/share/qemu/
sudo cp v620-odcaps.rom /usr/share/qemu/v620-odcaps.rom
sudo chmod 644 /usr/share/qemu/v620-odcaps.rom
```

## Step 4: Create VM with GPU Passthrough

### 4.1 Get V620 PCI Info

```bash
lspci -nn -s 83:00.0
# Note: PCI ID 1002:73a1

virsh nodedev-list | grep 83_00_0
# Note: Device name like pci_0000_83_00_0
```

### 4.2 Get GPU IOMMU Group Devices

```bash
# Find all devices in V620 IOMMU group
virsh nodedev-dumpxml pci_0000_83_00_0 | awk -F\' '/iorGroup/ {print $2}'
# Example output: 92

# Find all devices in group 92
find /sys/kernel/iommu_groups/92/devices/
```

You may need to passthrough:
- GPU: `83:00.0` (VGA controller)
- Audio: `83:00.1` (HDMI audio - optional)

### 4.3 Detach V620 from Host

```bash
# Unbind V620 from vfio-pci
echo '0000:83:00.0' | sudo tee /sys/bus/pci/devices/0000:83:00.0/driver/unbind

# Verify detached
lspci -nnk -s 83:00.0
# Should show no driver
```

### 4.4 Create VM Config with GPU Passthrough

```bash
sudo virsh edit v620-vm
```

Add hostdev devices for GPU:

```xml
<domain type='kvm'>
  <!-- ... existing config ... -->

  <!-- Add after <devices> section -->
  <hostdev mode='subsystem' type='pci' managed='no'>
    <driver name='vfio'/>
    <source>
      <address domain='0x0000' bus='0x83' slot='0x00' function='0x0'/>
    </source>
    <address type='pci' domain='0x0000' bus='0x06' slot='0x00' function='0x0'/>
    <rom file='/usr/share/qemu/v620-odcaps.rom'/>
  </hostdev>

  <!-- Optional: Audio device -->
  <hostdev mode='subsystem' type='pci' managed='no'>
    <driver name='vfio'/>
    <source>
      <address domain='0x0000' bus='0x83' slot='0x00' function='0x1'/>
    </source>
    <address type='pci' domain='0x0000' bus='0x06' slot='0x00' function='0x1'/>
  </hostdev>
</domain>
```

Key parameters:
- `managed='no'`: We handle binding manually
- `<rom file='...'>`: Loads patched VBIOS

### 4.5 Alternative: Full VM Config Example

See `V620_POWER_CAP_UNLOCK/v620-vm-config.xml` for complete working configuration.

```bash
# Define VM from XML
sudo virsh define V620_POWER_CAP_UNLOCK/v620-vm-config.xml

# Start VM
sudo virsh start v620-vm

# Connect to console
sudo virsh console v620-vm
```

## Step 5: Install amdgpu in VM

### 5.1 Install AMD Drivers in VM

From VM console:

```bash
sudo apt update
sudo apt install -y linux-headers-generic
sudo apt install -y amdgpu-dkms firmware-amd-graphics
```

### 5.2 Verify GPU in VM

```bash
# Check GPU is visible
lspci | grep -i amd

# Check amdgpu driver
lsmod | grep amdgpu

# Check DRM devices
ls /sys/class/drm/
```

### 5.3 Enable PP Feature Mask in VM

Edit GRUB in VM:

```bash
sudo vim /etc/default/grub
```

Add to `GRUB_CMDLINE_LINUX_DEFAULT`:

```
amdgpu.ppfeaturemask=0xffffffff
```

```bash
sudo update-grub
sudo reboot
```

## Step 6: Verify Power Cap Unlock

### 6.1 Check OD Table Exists

After VM reboot:

```bash
# Check if OverDrive table exists
cat /sys/class/drm/card0/device/pp_od_clk_voltage

# Should show OD table with clock/voltage info
```

If this file exists, the VBIOS unlock worked!

### 6.2 Check Power Limits

```bash
# Check current power limits
cat /sys/class/drm/card0/device/hwmon/hwmon*/power1_cap
cat /sys/class/drm/card0/device/hwmon/hwmon*/power1_cap_max
cat /sys/class/drm/card0/device/hwmon/hwmon*/power1_cap_min
```

Expected after OD unlock:
- Min: ~232W
- Max: ~275W

### 6.3 Use rocm-smi in VM

```bash
# Install ROCm tools in VM
wget -q -O - https://repo.radeon.com/rocm/rocm.gpg.key | sudo apt-key add -
echo 'deb [arch=amd64] https://repo.radeon.com/rocm/ubuntu/22.04 jammy main' | sudo tee /etc/apt/sources.list.d/rocm.list
sudo apt update
sudo apt install -y rocm-smi

# Check power info
rocm-smi -d 0 --showpower
rocm-smi -d 0 --showod
```

## Step 7: Set Custom Power Limit (170W)

### 7.1 Set Power Limit via sysfs

```bash
# Set 170W limit (170000000 microwatts)
echo 170000000 | sudo tee /sys/class/drm/card0/device/hwmon/hwmon*/power1_cap
```

### 7.2 Verify Limit

```bash
# Read back current limit
cat /sys/class/drm/card0/device/hwmon/hwmon*/power1_cap
# Should show: 170000000
```

### 7.3 Make Permanent (udev rule)

Create udev rule in VM:

```bash
sudo vim /etc/udev/rules.d/99-amd-gpu-power.rules
```

Add:

```
ACTION=="add|change", SUBSYSTEM=="hwmon", ATTR{name}=="amdgpu", TEST{power1_cap}=="", ATTR{power1_cap}="170000000"
```

Reload rules:

```bash
sudo udevadm control --reload-rules
sudo udevadm trigger
```

## Step 8: Install Power Monitoring

### 8.1 Copy VM Monitor Script to Guest

From host:

```bash
cd /home/beefyboi/amdtests
sudo ./TEST_SCRIPTS/VM_TESTS/install_vm_monitor.sh v620-vm ubuntu
```

### 8.2 Run Monitor in VM

```bash
# From VM
sudo ~/monitor_gpu_vm.sh
```

### 8.3 Run Host Monitor (Optional)

From host:

```bash
sudo ./TEST_SCRIPTS/HOST_TESTS/monitor_wattage.sh
```

## Troubleshooting

### VM Won't Start with GPU

**Issue:** VM hangs or crashes when starting with GPU

**Solutions:**
1. Check GPU is bound to vfio-pci: `lspci -nnk -s 83:00.0`
2. Check IOMMU groups: V620 should be alone or with compatible devices
3. Try with `managed='yes'` first, then switch to `managed='no'`
4. Check dmesg for SMU errors

### SMU Wedged (No Recovery)

**Symptoms:**
- dmesg shows: `amdgpu: trn=2 ACK should not assert!`
- lspci shows `rev ff` for GPU
- VM won't start

**Solution:** Host reboot required (no other recovery)

**Prevention:**
- Never write to `/sys/class/drm/card0/device/pp_features`
- Never write to `/sys/class/drm/card0/device/pp_table`
- Use rocm-smi or sysfs `power1_cap` for power control only

### No OD Table After ROM Flash

**Check:**
1. ROM file path is correct in VM config
2. ROM file is readable: `sudo ls -la /usr/share/qemu/v620-odcaps.rom`
3. Verify ROM integrity: `md5sum v620-odcaps.rom`

**Debug:**
```bash
# Check QEMU log
sudo journalctl -u libvirtd | grep -i rom
```

### Power Limit Not Setting

**Check:**
1. PP feature mask: `cat /proc/cmdline | grep ppfeaturemask`
2. Should show `0xffffffff`

**Fix:**
```bash
sudo vim /etc/default/grub
# Add: amdgpu.ppfeaturemask=0xffffffff
sudo update-grub
sudo reboot
```

## Verification Checklist

- [ ] Host IOMMU enabled: `dmesg | grep IOMMU`
- [ ] V620 bound to vfio-pci: `lspci -nnk -s 83:00.0`
- [ ] VM boots without GPU
- [ ] VBIOS dumped and patched
- [ ] VM config has GPU hostdev entries
- [ ] VM boots with GPU passthrough
- [ ] amdgpu driver loads in VM
- [ ] OD table exists: `cat /sys/class/drm/card0/device/pp_od_clk_voltage`
- [ ] Power cap is adjustable: `cat /sys/class/drm/card0/device/hwmon/hwmon*/power1_cap`
- [ ] Power limit set to 170W
- [ ] Monitoring scripts working

## Complete Example Commands

### Quick Passthrough Test

```bash
# 1. Prepare GPU
echo '0000:83:00.0' | sudo tee /sys/bus/pci/devices/0000:83:00.0/driver/unbind

# 2. Start VM with GPU
sudo virsh start v620-vm

# 3. Connect to console
sudo virsh console v620-vm

# 4. In VM - install driver
sudo apt install -y amdgpu-dkms firmware-amd-graphics
sudo reboot

# 5. In VM - verify
cat /sys/class/drm/card0/device/pp_od_clk_voltage
```

### Rebind GPU to Host

```bash
# Stop VM first
sudo virsh destroy v620-vm

# Rebind to amdgpu
echo '0000:83:00.0' | sudo tee /sys/bus/pci/devices/0000:83:00.0/driver/unbind
echo 'amdgpu' | sudo tee /sys/bus/pci/devices/0000:83:00.0/driver_override
echo '0000:83:00.0' | sudo tee /sys/bus/pci/drivers_probe

# Verify
lspci -nnk -s 83:00.0
```

### Rebind GPU to Passthrough

```bash
# Unbind from current driver
echo '0000:83:00.0' | sudo tee /sys/bus/pci/devices/0000:83:00.0/driver/unbind

# Bind to vfio-pci
echo 'vfio-pci' | sudo tee /sys/bus/pci/devices/0000:83:00.0/driver_override
echo '0000:83:00.0' | sudo tee /sys/bus/pci/drivers_probe

# Verify
lspci -nnk -s 83:00.0
# Should show: Kernel driver in use: vfio-pci
```

## Next Steps

After successful passthrough:
1. Use `TEST_SCRIPTS/HOST_TESTS/monitor_wattage.sh` for system monitoring
2. Use `TEST_SCRIPTS/VM_TESTS/monitor_gpu_vm.sh` for GPU-specific monitoring
3. Reference `AMD_V620_POWER_LIMIT/README.md` for project findings
