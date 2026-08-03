# AMD V620 Passthrough - System Setup Guide

Complete setup instructions for Ubuntu 22.04.5 LTS host system to enable AMD Radeon Pro V620 GPU passthrough with power cap unlock.

## System Specifications

**Hardware:**
- Host: ASUS ESC4000 G3
- CPU: Dual Intel Xeon E5-2650 v4 (48 threads, VT-x enabled)
- RAM: 126 GB
- GPU: AMD Radeon Pro V620 @ 83:00.0 (PCI ID 1002:73a1)
- GPU 2: ASPEED Graphics @ 07:00.0 (host display)

**Software:**
- OS: Ubuntu 22.04.5 LTS
- Kernel: 5.15.0-186-generic
- Hypervisor: KVM/QEMU with libvirt

## Step 1: Fresh Ubuntu Installation

### 1.1 Install Ubuntu Server 22.04.5 LTS

```bash
# Download Ubuntu Server 22.04.5 LTS
wget https://releases.ubuntu.com/22.04/ubuntu-22.04.5-live-server-amd64.iso

# Create bootable USB (on Linux)
sudo dd if=ubuntu-22.04.5-live-server-amd64.iso of=/dev/sdX bs=4M status=progress && sudo sync
```

### 1.2 Install Essential Build Tools

```bash
sudo apt update && sudo apt upgrade -y
sudo apt install -y build-essential git vim curl wget htop
sudo apt install -y linux-headers-$(uname -r)
```

## Step 2: Enable Virtualization

### 2.1 Verify Hardware Virtualization Support

```bash
# Check CPU virtualization support
lscpu | grep Virtualization

# Should show: VT-x (Intel) or AMD-V (AMD)
kvm-ok
```

Expected output: `KVM acceleration can be used`

### 2.2 Enable IOMMU in Kernel Command Line

Edit GRUB configuration:

```bash
sudo vim /etc/default/grub
```

Add to `GRUB_CMDLINE_LINUX_DEFAULT`:

```
intel_iommu=on iommu=pt amdgpu.ppfeaturemask=0xffffffff
```

Update GRUB and reboot:

```bash
sudo update-grub
sudo reboot
```

### 2.3 Verify IOMMU is Enabled

After reboot:

```bash
dmesg | grep -e IOMMU -e DMAR
```

Look for: `DMAR: IOMMU enabled`

### 2.4 Check V620 IOMMU Group

```bash
find /sys/kernel/iommu_groups/ -name "83:00.0"
```

Note the group number (should be 92 on this system).

## Step 3: Install KVM and Libvirt

### 3.1 Install Virtualization Packages

```bash
sudo apt install -y qemu-kvm libvirt-daemon-system libvirt-clients bridge-utils virtinst virt-manager
sudo apt install -y ovmf
```

### 3.2 Enable and Start libvirt

```bash
sudo systemctl enable libvirtd
sudo systemctl start libvirtd
sudo usermod -aG libvirt $USER
```

### 3.3 Verify Installation

```bash
virsh version
lsmod | grep kvm
```

## Step 4: Configure VFIO for GPU Passthrough

### 4.1 Verify VFIO Modules

VFIO is built into the kernel, not a module. Check:

```bash
ls /sys/module/vfio*
# Should show: vfio, vfio_pci, vfio_iommu_type1
```

### 4.2 Create VFIO Configuration

```bash
sudo vim /etc/modprobe.d/vfio.conf
```

Add:

```
options vfio-pci ids=1002:73a1 disable_vga=1
```

### 4.3 Prevent amdgpu from Rebinding

```bash
sudo vim /etc/modprobe.d/amdgpu-ignore.conf
```

Add:

```
options amdgpu tmz=1
```

### 4.4 Update initramfs

```bash
sudo update-initramfs -u
sudo reboot
```

### 4.5 Verify VFIO Configuration

After reboot, check V620 driver:

```bash
lspci -nnk -s 83:00.0
```

Should show: `Kernel driver in use: vfio-pci`

## Step 5: Configure Default libvirt Network

### 5.1 Start Default Network

```bash
sudo virsh net-start default
sudo virsh net-autostart default
```

### 5.2 Verify Network

```bash
sudo virsh net-list --all
```

Should show `default` network as `active`.

## Step 6: Prepare Storage and VM Images

### 6.1 Create Storage Directory

```bash
sudo mkdir -p /var/lib/libvirt/images
sudo mkdir -p /var/lib/libvirt/images/cloud-init
```

### 6.2 Download Ubuntu Cloud Image (for VM)

```bash
wget https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img -O /var/lib/libvirt/images/ubuntu-24.04.qcow2
```

## Step 7: Install ROCm Tools (Optional - for Host Debugging)

```bash
# Add AMD ROCm repository
wget -q -O - https://repo.radeon.com/rocm/rocm.gpg.key | sudo apt-key add -
echo 'deb [arch=amd64] https://repo.radeon.com/rocm/ubuntu/22.04 jammy main' | sudo tee /etc/apt/sources.list.d/rocm.list

sudo apt update
sudo apt install -y rocm-smi
```

## Step 8: Verify System Ready for Passthrough

### 8.1 Final Verification Checklist

```bash
# KVM working
kvm-ok
# Expected: KVM acceleration can be used

# IOMMU enabled
dmesg | grep -e IOMMU
# Expected: IOMMU enabled messages

# V620 bound to vfio-pci
lspci -nnk -s 83:00.0 | grep "Kernel driver"
# Expected: Kernel driver in use: vfio-pci

# libvirt running
sudo virsh list --all
# Expected: List of VMs (may be empty)

# Default network active
sudo virsh net-list
# Expected: default network active
```

### 8.2 Power Meter Verification

Check system power monitoring:

```bash
ls -la /sys/class/hwmon/hwmon1/device/power1_average
cat /sys/class/hwmon/hwmon1/device/name
# Expected: power_meter
```

## Kernel Parameters Summary

Final `/etc/default/grub` should include:

```
GRUB_CMDLINE_LINUX_DEFAULT="intel_iommu=on iommu=pt amdgpu.ppfeaturemask=0xffffffff"
```

## Installed Packages Summary

Essential packages installed:
- `qemu-kvm`, `libvirt-daemon-system`, `libvirt-clients`
- `virtinst`, `virt-manager`, `bridge-utils`
- `ovmf` (UEFI firmware)
- `build-essential`, `git`, `vim`, `curl`, `wget`
- `rocm-smi` (optional, for debugging)

## Next Steps

After completing setup:
1. See `GPU_PASSTHROUGH.md` for VM creation and GPU passthrough
2. See `V620_POWER_CAP_UNLOCK/` for VBIOS modification
3. See `TEST_SCRIPTS/` for power monitoring tools

## Troubleshooting

### V620 not binding to vfio-pci

```bash
# Unbind from current driver
echo '0000:83:00.0' | sudo tee /sys/bus/pci/devices/0000:83:00.0/driver/unbind

# Bind to vfio-pci
echo 'vfio-pci' | sudo tee /sys/bus/pci/devices/0000:83:00.0/driver_override
echo '0000:83:00.0' | sudo tee /sys/bus/pci/drivers_probe
```

### IOMMU not enabled

Check BIOS:
- Enable VT-x / Intel Virtualization Technology
- Enable VT-d / Intel IOMMU
- Disable Secure Boot (if causing issues)

### libvirt permission denied

```bash
sudo usermod -aG libvirt $USER
# Log out and back in
```

## References

- [KVM Documentation](https://www.linux-kvm.org/page/Documents)
- [libvirt Documentation](https://libvirt.org/docs.html)
- [AMD GPU Passthrough Guide](https://passthroughpo.st/simple-gpu-passthrough/)
