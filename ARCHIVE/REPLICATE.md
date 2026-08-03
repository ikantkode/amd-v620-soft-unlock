# V620 170W Unlock - Complete Replication Guide

**Target:** AMD Radeon Pro V620 power reduction from 250W to 170W for LLM inference
**Time:** ~2-3 hours
**Difficulty:** Intermediate (requires Linux system administration)

---

## Prerequisites

### Hardware
- AMD Radeon Pro V620 GPU
- Server with Ubuntu 22.04/24.04 headless server
- CPU with VT-d/AMD-Vi support
- Secondary GPU or IPMI for host display (optional but recommended)

### Software
- Ubuntu 22.04.5 LTS or 24.04 LTS (headless server)
- SSH access
- sudo privileges

---

## Phase 1: Initial System Setup

### 1.1 Update System

```bash
sudo apt update && sudo apt upgrade -y
sudo apt install -y git vim curl wget
```

### 1.2 Verify Hardware

```bash
# Check CPU virtualization support
lscpu | grep -E "vt-d|amd-vi"

# Check V620 is present
lspci | grep -i "amd.*v620"
# Should show: "Advanced Micro Devices, Inc. [AMD/ATI] Navi 21 [Radeon Pro V620]"

# Note the PCI address (example: 83:00.0)
lspci | grep "VGA\|Display"
```

**Expected output:**
```
83:00.0 VGA compatible controller: Advanced Micro Devices, Inc. [AMD/ATI] Navi 21 [Radeon Pro V620]
```

### 1.3 Check KVM Support

```bash
sudo apt install -y cpu-checker
kvm-ok
```

**Expected output:** `KVM acceleration can be used`

---

## Phase 2: IOMMU and Kernel Configuration

### 2.1 Enable IOMMU in Kernel Command Line

```bash
# Edit kernel cmdline
sudo vim /etc/default/grub
```

**Find this line:**
```bash
GRUB_CMDLINE_LINUX_DEFAULT=""
```

**Change to:**
```bash
GRUB_CMDLINE_LINUX_DEFAULT="intel_iommu=on iommu=pt amdgpu.ppfeaturemask=0xffffffff"
```

**For AMD CPUs, use:**
```bash
GRUB_CMDLINE_LINUX_DEFAULT="amd_iommu=on iommu=pt amdgpu.ppfeaturemask=0xffffffff"
```

### 2.2 Update GRUB and Reboot

```bash
sudo update-grub
sudo reboot
```

### 2.3 Verify IOMMU After Reboot

```bash
# Check IOMMU groups
dmesg | grep -E "IOMMU|iommu" | head -20
find /sys/kernel/iommu_groups/ -type l -name "devices/*" | wc -l
```

---

## Phase 3: VFIO Configuration

### 3.1 Install VFIO Packages

```bash
sudo apt install -y qemu-kvm libvirt-daemon-system virt-manager ovmf
```

### 3.2 Configure VFIO for V620

**Find your V620 PCI ID:**
```bash
lspci -nn | grep "V620"
# Output format: XX:XX.X VGA ... [1002:73a1]
# The ID in brackets is the PCI ID (1002:73a1)
```

**Create VFIO configuration:**
```bash
sudo vim /etc/modprobe.d/vfio.conf
```

**Add this line (replace with your PCI ID):**
```bash
options vfio-pci ids=1002:73a1 disable_vga=1
```

### 3.3 Prevent AMDGPU Rebinding

```bash
sudo vim /etc/modprobe.d/amdgpu-ignore.conf
```

**Add:**
```bash
blacklist amdgpu
options amdgpu ppfeaturemask=0xffffffff
```

### 3.4 Ensure VFIO Modules Load

```bash
sudo vim /etc/modules
```

**Add these lines:**
```bash
vfio
vfio_pci
vfio_iommu_type1
```

### 3.5 Update Initramfs and Reboot

```bash
sudo update-initramfs -u
sudo reboot
```

---

## Phase 4: VM Infrastructure Setup

### 4.1 Start Libvirt

```bash
sudo systemctl enable --now libvirtd
sudo systemctl status libvirtd
```

**Expected:** `Active: active (running)`

### 4.2 Verify Storage Pool

```bash
sudo ls -la /var/lib/libvirt/images/
```

**If missing:**
```bash
sudo mkdir -p /var/lib/libvirt/images/
sudo virsh pool-create-as default target=/var/lib/libvirt/images
```

### 4.3 Verify OVMF Firmware

```bash
sudo ls -la /usr/share/OVMF/OVMF_CODE.fd
```

**If missing:**
```bash
sudo apt install -y ovmf
```

---

## Phase 5: V620 VFIO Binding

### 5.1 Check Current Driver Binding

```bash
lspci -nnk -s 83:00.0 | grep "Kernel driver"
```

**If shows amdgpu, proceed to unbind. If shows vfio-pci, skip to Phase 6.**

### 5.2 Unbind V620 from Current Driver

```bash
echo 'YOUR_PASSWORD' | sudo -S sh -c 'echo "0000:83:00.0" > /sys/bus/pci/devices/0000:83:00.0/driver/unbind'
```

### 5.3 Bind to VFIO-PCI

```bash
echo 'YOUR_PASSWORD' | sudo -S sh -c 'echo "vfio-pci" > /sys/bus/pci/devices/0000:83:00.0/driver_override'
echo 'YOUR_PASSWORD' | sudo -S sh -c 'echo "0000:83:00.0" > /sys/bus/pci/drivers_probe'
```

### 5.4 Verify Binding

```bash
lspci -nnk -s 83:00.0 | grep "Kernel driver"
```

**Expected:** `Kernel driver in use: vfio-pci`

---

## Phase 6: Create Ubuntu 24.04 VM

### 6.1 Download Cloud Image

```bash
cd /tmp
wget https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-amd64.img
```

### 6.2 Create VM Disk (500GB for LLM workloads)

```bash
# Create expanded disk
sudo qemu-img create -f qcow2 /var/lib/libvirt/images/v620-vm.qcow2 500G

# If LVM space is limited, expand root LV first:
# sudo lvextend -L +400G /dev/ubuntu-vg/ubuntu-lv
# sudo resize2fs /dev/ubuntu-vg/ubuntu-lv
```

### 6.3 Create Cloud-Init Config

```bash
sudo mkdir -p /var/lib/libvirt/images/cloud-init
```

**Create meta-data:**
```bash
sudo vim /var/lib/libvirt/images/cloud-init/meta-data
```

**Add:**
```yaml
instance-id: v620-vm
local-hostname: v620-vm
```

**Create user-data:**
```bash
sudo vim /var/lib/libvirt/images/cloud-init/user-data
```

**Add:**
```yaml
#cloud-config
users:
  - name: ubuntu
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys:
      - YOUR_SSH_PUBLIC_KEY
packages:
  - linux-modules-extra
  - linux-firmware
  - python3
  - python3-pip
runcmd:
  - [ systemctl, daemon-reload ]
  - [ systemctl, restart, ssh ]
final_message: "Cloud-init complete"
```

**Generate cloud-init ISO:**
```bash
cd /var/lib/libvirt/images/cloud-init
sudo cloud-localds v620-vm-seed.iso meta-data user-data
```

### 6.4 Create VM Definition

```bash
cat > /tmp/v620-vm.xml << 'EOF'
<domain type='kvm'>
  <name>v620-vm</name>
  <memory unit='GiB'>32</memory>
  <vcpu>8</vcpu>
  <os>
    <type arch='x86_64' machine='q35'>hvm</type>
    <loader readonly='yes' type='pflash'>/usr/share/OVMF/OVMF_CODE.fd</loader>
    <nvram>/var/lib/libvirt/images/v620-vm_VARS.fd</nvram>
    <boot dev='hd'/>
  </os>
  <features>
    <acpi/>
    <apic/>
  </features>
  <cpu mode='host-passthrough'/>
  <clock offset='utc'/>
  <on_poweroff>destroy</on_poweroff>
  <on_reboot>restart</on_reboot>
  <on_crash>destroy</on_crash>
  <devices>
    <emulator>/usr/bin/qemu-system-x86_64</emulator>
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2'/>
      <source file='/var/lib/libvirt/images/v620-vm.qcow2'/>
      <target dev='vda' bus='virtio'/>
    </disk>
    <disk type='file' device='cdrom'>
      <driver name='qemu' type='raw'/>
      <source file='/var/lib/libvirt/images/cloud-init/v620-vm-seed.iso'/>
      <target dev='sda' bus='sata'/>
      <readonly/>
    </disk>
    <interface type='network'>
      <source network='default'/>
      <model type='virtio'/>
    </interface>
    <hostdev mode='subsystem' type='pci' managed='yes'>
      <driver name='vfio'/>
      <source>
        <address domain='0x0000' bus='0x83' slot='0x00' function='0x0'/>
      </source>
      <rom file='/usr/share/qemu/v620-odcaps.rom'/>
    </hostdev>
    <serial type='pty'/>
    <console type='pty'/>
  </devices>
</domain>
EOF
```

**Replace bus address (83:00.0) with your V620's location if different.**

### 6.5 Define and Start VM

```bash
sudo virsh define /tmp/v620-vm.xml
sudo virsh start v620-vm
```

---

## Phase 7: Verify Passthrough

### 7.1 Wait for VM Boot

```bash
# Wait 2-3 minutes for boot
sleep 180

# Find VM IP
ip neigh | grep "52:54"
# Should show: 192.168.122.XX dev virbr0 lladdr 52:54:XX:XX:XX:XX REACHABLE
```

### 7.2 SSH into VM

```bash
ssh -i YOUR_PRIVATE_KEY ubuntu@192.168.122.XX
```

### 7.3 Verify V620 in Guest

```bash
# Check GPU is visible
lspci | grep -i amd
# Should show: "Navi 21 [Radeon Pro V620]"

# Check driver
lspci -nnk -s 05:00.0 | grep "Kernel driver"
# Should show: "Kernel driver in use: amdgpu"

# Verify amdgpu loaded
sudo dmesg | grep -i amdgpu | tail -10
# Should show: "SMU is initialized successfully!"
```

---

## Phase 8: VBIOS Unlock - Basic

### 8.1 Enable OverDrive in Guest

```bash
# Add kernel flag
sudo sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"/GRUB_CMDLINE_LINUX_DEFAULT="\1 amdgpu.ppfeaturemask=0xffffffff"/' /etc/default/grub.d/50-cloudimg-settings.cfg

# Update grub
sudo update-grub

# Reboot guest
sudo reboot
```

### 8.2 Dump VBIOS from Guest

```bash
# After reboot, SSH back in
ssh -i YOUR_PRIVATE_KEY ubuntu@192.168.122.XX

# Mount debugfs
sudo mount -t debugfs none /sys/kernel/debug

# Dump VBIOS
sudo cat /sys/kernel/debug/dri/0/amdgpu_vbios > ~/v620_vbios.rom

# Copy to host
exit
scp -i YOUR_PRIVATE_KEY ubuntu@192.168.122.XX:~/v620_vbios.rom .
```

### 8.3 Clone Unlock Repo and Patch

```bash
# On host
cd ~
git clone https://github.com/Tamalero/amd-v620-soft-unlock.git
cd amd-v620-soft-unlock

# Patch VBIOS
python3 make_odcaps_rom.py ~/v620_vbios.rom
# Creates: v620-odcaps.rom

# Copy to QEMU directory
sudo cp v620-odcaps.rom /usr/share/qemu/
```

### 8.4 Attach ROM to VM

```bash
# Update VM config
sudo virsh edit v620-vm
```

**Find the `<hostdev>` section and add:**
```xml
<rom file='/usr/share/qemu/v620-odcaps.rom'/>
```

**Or replace entire hostdev section:**
```xml
<hostdev mode='subsystem' type='pci' managed='yes'>
  <driver name='vfio'/>
  <source>
    <address domain='0x0000' bus='0x83' slot='0x00' function='0x0'/>
  </source>
  <rom file='/usr/share/qemu/v620-odcaps.rom'/>
</hostdev>
```

### 8.5 Restart VM and Verify Basic Unlock

```bash
sudo virsh shutdown v620-vm
sleep 10
sudo virsh start v620-vm

# SSH back in after boot
ssh -i YOUR_PRIVATE_KEY ubuntu@192.168.122.XX

# Check OD table exists
cat /sys/class/drm/card0/device/pp_od_clk_voltage
```

**Expected output:**
```
OD_SCLK: 500-2650 MHz
OD_MCLK: 674-1075 MHz
OD_RANGE: SCLK 500-2650, MCLK 674-1075
```

**Check power range:**
```bash
cat /sys/class/drm/card0/device/hwmon/hwmon*/power1_cap_{min,max}
```

**Expected:** 232-275W (basic unlock complete)

---

## Phase 9: Advanced 170W Power Tuning

### 9.1 Understand PowerPlay Table Structure

The V620 PowerPlay table contains OD power limits at specific offsets:
- **PP offset 0x032e:** OD minimum power limit
- **PP offset 0x033e:** OD maximum power limit

### 9.2 Create 170W Patch Script

```bash
cd ~
cat > make_170w_rom.py << 'EOF'
#!/usr/bin/env python3
"""
Patch V620 VBIOS for 170W power target.
Modifies OD power limits in PowerPlay table.
"""
import sys

# Constants
PPTABLE_HEADER = bytes.fromhex("a6090f00")  # smu11 PP table signature
CHECKSUM_OFFSET = 0x21

# PowerPlay table offsets (relative to PP table base)
OD_POWER_MIN_OFFSET = 0x032e
OD_POWER_MAX_OFFSET = 0x033e

# Target power limits
MIN_POWER_W = 170  # Results in ~158W min after ±10% applied
MAX_POWER_W = 200  # Results in ~187W max after ±10% applied

def patch_vbios(input_rom, output_rom):
    with open(input_rom, "rb") as f:
        rom = bytearray(f.read())
    
    # Validate checksum
    if sum(rom) % 256 != 0:
        print("ERROR: Input ROM checksum invalid")
        return False
    
    # Find PowerPlay table
    base = rom.find(PPTABLE_HEADER)
    if base == -1:
        print("ERROR: PowerPlay table not found")
        return False
    
    print(f"PowerPlay table found at offset: {base:#x}")
    
    # Patch power limits (16-bit little endian)
    min_offset = base + OD_POWER_MIN_OFFSET
    max_offset = base + OD_POWER_MAX_OFFSET
    
    print(f"Patching min power at PP offset {OD_POWER_MIN_OFFSET:#x}")
    rom[min_offset:min_offset+2] = MIN_POWER_W.to_bytes(2, 'little')
    
    print(f"Patching max power at PP offset {OD_POWER_MAX_OFFSET:#x}")
    rom[max_offset:max_offset+2] = MAX_POWER_W.to_bytes(2, 'little')
    
    # Fix checksum
    rom[CHECKSUM_OFFSET] = (rom[CHECKSUM_OFFSET] - (sum(rom) % 256)) % 256
    
    # Verify checksum
    if sum(rom) % 256 != 0:
        print("ERROR: Checksum fix failed")
        return False
    
    # Write output
    with open(output_rom, "wb") as f:
        f.write(bytes(rom))
    
    print(f"Created {output_rom} with {MIN_POWER_W}W target")
    return True

if __name__ == "__main__":
    if len(sys.argv) < 3:
        print(f"Usage: {sys.argv[0]} <input.rom> <output.rom>")
        sys.exit(1)
    
    input_rom = sys.argv[1]
    output_rom = sys.argv[2]
    
    if patch_vbios(input_rom, output_rom):
        print("SUCCESS: ROM patched for 170W target")
        sys.exit(0)
    else:
        print("FAILED: ROM patching failed")
        sys.exit(1)
EOF

chmod +x make_170w_rom.py
```

### 9.3 Patch VBIOS for 170W

```bash
# Patch the basic unlocked ROM
python3 make_170w_rom.py v620-odcaps.rom v620-170w-final.rom

# Copy to QEMU directory
sudo cp v620-170w-final.rom /usr/share/qemu/
```

### 9.4 Update VM to Use 170W ROM

```bash
sudo virsh edit v620-vm
```

**Change ROM path:**
```xml
<rom file='/usr/share/qemu/v620-170w-final.rom'/>
```

### 9.5 Restart VM and Verify 170W Unlock

```bash
sudo virsh shutdown v620-vm
sleep 10
sudo virsh start v620-vm

# SSH in after boot
ssh -i YOUR_PRIVATE_KEY ubuntu@192.168.122.XX
```

**Verify new power range:**
```bash
cat /sys/class/drm/card0/device/hwmon/hwmon*/power1_cap_{min,max}
```

**Expected:** 158000000 187000000 (158-187W range)

**Set 170W target:**
```bash
echo 170000000 | sudo tee /sys/class/drm/card0/device/hwmon/hwmon*/power1_cap

# Verify
cat /sys/class/drm/card0/device/hwmon/hwmon*/power1_cap
```

**Expected:** 170000000

**Verify OD table still active:**
```bash
cat /sys/class/drm/card0/device/pp_od_clk_voltage
```

---

## Phase 10: Verification and Testing

### 10.1 Check GPU Status

```bash
# Temperatures
cat /sys/class/drm/card0/device/hwmon/hwmon*/temp1_input
cat /sys/class/drm/card0/device/hwmon/hwmon*/temp2_input
cat /sys/class/drm/card0/device/hwmon/hwmon*/temp3_input

# Idle power
cat /sys/class/drm/card0/device/hwmon/hwmon*/power1_average
```

**Expected:** Temps 35-45°C, idle power ~8W

### 10.2 Test Under Load

```bash
# Install stress tool
sudo apt install -y stress

# Run CPU load
stress --cpu 4 --timeout 60s &

# Monitor GPU
watch -n 1 'cat /sys/class/drm/card0/device/hwmon/hwmon*/{temp1_input,power1_average}'
```

### 10.3 Optional: Install LACT for GUI Control

```bash
# Install LACT (in guest)
wget https://github.com/ilya-zlobintsev/LACT/releases/download/v0.5.8/lact_0.5.8_amd64.deb
sudo dpkg -i lact_0.5.8_amd64.deb

# Enable daemon
sudo systemctl enable --now lactd
```

---

## Troubleshooting

### SMU Wedge (Device Rev FF)

**Symptoms:**
- lspci shows `rev ff`
- VM crashes on start
- dmesg: "ACK should not assert"

**Solution:** Host reboot required. Always verify V620 health before VM operations.

### OD Table Not Visible

**Check:**
1. `amdgpu.ppfeaturemask=0xffffffff` in guest kernel cmdline
2. ROM file attached to VM
3. Guest amdgpu driver loaded

### Power Limits Wrong

**Verify:**
1. Correct ROM file attached to VM
2. VM fully restarted after ROM change
3. Check dmesg for ROM loading: `dmesg | grep -i vbios`

### GPU Not Visible in Guest

**Check:**
1. V620 bound to vfio-pci on host: `lspci -nnk -s 83:00.0`
2. IOMMU enabled: `dmesg | grep -IOMMU`
3. VM config has correct PCI address

---

## Quick Reference

### Host Commands

```bash
# Check V620 driver
lspci -nnk -s 83:00.0

# Bind to VFIO
echo '0000:83:00.0' | sudo tee /sys/bus/pci/devices/0000:83:00.0/driver/unbind
echo 'vfio-pci' | sudo tee /sys/bus/pci/devices/0000:83:00.0/driver_override
echo '0000:83:00.0' | sudo tee /sys/bus/pci/drivers_probe

# VM status
virsh list --all
virsh dumpxml v620-vm | grep rom

# Find VM IP
ip neigh | grep "52:54"
```

### Guest Commands

```bash
# Check power limits
cat /sys/class/drm/card0/device/hwmon/hwmon*/power1_cap_{min,max}

# Set power target
echo 170000000 | sudo tee /sys/class/drm/card0/device/hwmon/hwmon*/power1_cap

# Check clocks
cat /sys/class/drm/card0/device/pp_od_clk_voltage

# Set max clocks
echo "s 1 2650" | sudo tee /sys/class/drm/card0/device/pp_od_clk_voltage
echo "m 1 1075" | sudo tee /sys/class/drm/card0/device/pp_od_clk_voltage
echo "c" | sudo tee /sys/class/drm/card0/device/pp_od_clk_voltage

# Check status
cat /sys/class/drm/card0/device/hwmon/hwmon*/temp1_input
cat /sys/class/drm/card0/device/hwmon/hwmon*/power1_average
```

---

## Performance Expectations

- **Power Range:** 158-187W (170W ±10%)
- **Idle Power:** ~8W at 170W cap
- **Idle Temp:** 35-45°C
- **Core Clock Range:** 500-2650 MHz
- **VRAM Clock Range:** 674-1075 MHz
- **Clock Sensor:** Reads 0 MHz (known limitation - use benchmarks to verify)

---

## Safety Notes

1. **Never write to pp_features or pp_table sysfs** - will wedge SMU
2. **Always verify V620 health before VM operations** - check for `rev ff`
3. **Monitor temperatures under load** - passive card needs airflow
4. **ROM changes require VM restart** - not hot-pluggable
5. **Host reboot required for SMU wedge** - no other recovery

---

## Completion Checklist

- [ ] IOMMU enabled and verified
- [ ] VFIO configured and V620 bound
- [ ] VM created and booting
- [ ] V620 visible in guest
- [ ] amdgpu driver loaded in guest
- [ ] Basic OD unlock working (232-275W range)
- [ ] 170W ROM applied
- [ ] Power range 158-187W verified
- [ ] 170W target successfully set
- [ ] GPU temperatures normal
- [ ] Clock controls functional

---

**Next Steps:** Install LLM inference stack (ROCm, vLLM, etc.) and begin inference workloads at optimized 170W power target.
