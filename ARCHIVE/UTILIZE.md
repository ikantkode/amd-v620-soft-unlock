# V620 Utilization Guide - Running LLM Workloads

**Critical Concept:** Your V620 GPU is **NOT available on the host system**. It's passed through to the **guest VM**. All GPU workloads must run inside the VM.

---

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│ HOST (Ubuntu 22.04)                                     │
│ - ASPEED GPU (display only)                            │
│ - V620 is bound to vfio-pci (NOT accessible here)       │
│ - Runs libvirt/QEMU                                     │
└────────────────┬───────────────────────────────────────┘
                 │ PCI Passthrough
┌────────────────▼───────────────────────────────────────┐
│ GUEST VM (Ubuntu 24.04 @ 192.168.122.54)              │
│ - V620 GPU (05:00.0) ← THIS IS YOUR GPU                │
│ - amdgpu driver loaded                                 │
│ - 170W power cap unlocked                              │
│ - Run Docker/vLLM/workloads HERE                       │
└───────────────────────────────────────────────────────┘
```

---

## Quick Answer: Can I Use docker-compose on Host?

**NO.** You must SSH into the guest VM and run Docker/vLLM there.

**Wrong:**
```bash
# ON HOST - This won't work!
docker run --gpus all vllm/vllm
# Error: no GPUs found
```

**Right:**
```bash
# SSH into guest first
ssh ubuntu@192.168.122.54
# Then run Docker
docker run --gpus all vllm/vllm
```

---

## Phase 1: Access Your GPU VM

### 1.1 SSH into Guest VM

```bash
# From host
ssh -i /tmp/vm-key ubuntu@192.168.122.54

# Or if using password auth
ssh ubuntu@192.168.122.54
```

### 1.2 Verify GPU Access

```bash
# Check GPU is present
lspci | grep -i amd
# Output: Navi 21 [Radeon Pro V620]

# Check driver
lsmod | grep amdgpu
# Output: amdgpu (should show size)

# Check power cap
cat /sys/class/drm/card0/device/hwmon/hwmon*/power1_cap
# Output: 170000000 (170W set)
```

---

## Phase 2: Install Docker in Guest VM

### 2.1 Install Docker

```bash
# Inside guest VM
sudo apt update
sudo apt install -y docker.io docker-compose

# Enable and start Docker
sudo systemctl enable --now docker

# Add your user to docker group
sudo usermod -aG docker ubuntu

# Log out and back in for group changes
exit
ssh ubuntu@192.168.122.54
```

### 2.2 Install NVIDIA Container Toolkit (for ROCm)

**Note:** For AMD GPUs, we use ROCm, not CUDA. Docker GPU passthrough works differently.

```bash
# Install ROCm dependencies
sudo apt install -y \
    linux-headers-generic \
    build-essential \
    git \
    wget

# Verify ROCm is available
dpkg -l | grep rocm
```

---

## Phase 3: Run vLLM with V620

### 3.1 Understanding AMD GPU with Docker

**For AMD GPUs, Docker doesn't need `--gpus all`** (that's NVIDIA). Instead:

```bash
# AMD GPU Docker method - pass through devices
docker run --device=/dev/kfd --device=/dev/dri \
    -v /dev/dri:/dev/dri \
    your-container
```

### 3.2 Pull vLLM Image

```bash
# vLLM with ROCm support
docker pull vllm/vllm-openai:latest
# OR build from source for AMD
```

### 3.3 Run vLLM Server

```bash
# Inside guest VM, run vLLM with V620
docker run -d --name vllm-server \
    --device=/dev/kfd \
    --device=/dev/dri \
    -v /dev/dri:/dev/dri \
    -p 8000:8000 \
    -e HIP_VISIBLE_DEVICES=0 \
    vllm/vllm-openai:latest \
    --model meta-llama/Llama-3.1-8B \
    --tensor-parallel-size 1 \
    --gpu-memory-utilization 0.9 \
    --max-model-len 4096
```

**Note:** You may need to build vLLM from source for ROCm support. See Phase 6.

---

## Phase 4: Access vLLM from Host

### 4.1 Port Forwarding Setup

Your guest VM is on NAT network (192.168.122.0/24). Access from host:

```bash
# From host, test access
curl http://192.168.122.54:8000/v1/models

# Or forward port from host
# Add to VM config or use SSH tunnel
ssh -L 8000:localhost:8000 ubuntu@192.168.122.54
```

### 4.2 External Access (Optional)

**Option A: SSH Tunnel (Recommended)**
```bash
# From your local machine
ssh -L 8000:192.168.122.54:8000 user@host-ip
# Access at http://localhost:8000
```

**Option B: Libvirt Port Forward**
```bash
# Edit network config
sudo virsh net-edit default

# Add forward inside <network>:
```
```xml
<forward mode='nat'>
  <nat>
    <port start='8000' end='8000'/>
  </nat>
</forward>
```

---

## Phase 5: Alternative - Direct Docker on Guest

### 5.1 Install Docker Compose in Guest

```bash
sudo apt install -y docker-compose-plugin
```

### 5.2 Create docker-compose.yml in Guest

```yaml
# ~/docker-compose.yml - Create inside guest VM
services:
  vllm:
    image: vllm/vllm-openai:latest
    container_name: vllm-server
    devices:
      - /dev/kfd
      - /dev/dri
    volumes:
      - /dev/dri:/dev/dri
    environment:
      - HIP_VISIBLE_DEVICES=0
    ports:
      - "8000:8000"
    command: >
      --model meta-llama/Llama-3.1-8B
      --tensor-parallel-size 1
      --gpu-memory-utilization 0.9
```

### 5.3 Run Compose

```bash
# Inside guest VM
docker compose up -d
```

---

## Phase 6: Build vLLM for ROCm (If Needed)

### 6.1 Install Build Dependencies

```bash
# Inside guest VM
sudo apt install -y \
    git \
    cmake \
    python3-venv \
    python3-dev \
    libopenblas-dev \
    librocblas-dev \
    miopen-hip \
    hip-dev

# Install ROCm (if not present)
sudo apt install -y rocm-libs rocm-dev
```

### 6.2 Build vLLM from Source

```bash
# Clone vLLM
git clone https://github.com/vllm-project/vllm.git
cd vllm

# Create venv
python3 -m venv .venv
source .venv/bin/activate

# Install with ROCm support
pip install -e .
# OR for explicit ROCm:
pip install -e . --extra-index-url https://download.pytorch.org/whl/rocm6.0
```

### 6.3 Run vLLM Natively

```bash
# Inside guest VM, with venv activated
source .venv/bin/activate

python -m vllm.entrypoints.openai.api_server \
    --model meta-llama/Llama-3.1-8B \
    --tensor-parallel-size 1 \
    --gpu-memory-utilization 0.9
```

---

## Phase 7: Verify GPU Utilization

### 7.1 Check GPU Usage in Guest

```bash
# Inside guest VM

# Check power usage
watch -n 1 'cat /sys/class/drm/card0/device/hwmon/hwmon*/power1_average'

# Check temperatures
watch -n 1 'cat /sys/class/drm/card0/device/hwmon/hwmon*/temp1_input'

# Check clock speeds (shows 0 but GPU is working)
cat /sys/class/drm/card0/device/pp_od_clk_voltage

# Use ROCm tools for real stats
rocminfo | grep -A20 "GPU 0"
rocm-smi
```

### 7.2 Monitor from Host

```bash
# From host, check VM is using GPU
virsh dumpxml v620-vm | grep hostdev

# Check VM resource usage
virsh dominfo v620-vm
virsh dommemstat v620-vm
```

---

## Phase 8: Common Workflows

### 8.1 Start GPU VM

```bash
# From host
sudo virsh start v620-vm

# Wait for boot
sleep 30

# SSH in
ssh ubuntu@192.168.122.54
```

### 8.2 Start Your Workload

```bash
# Inside guest VM
cd ~/my-llm-project
docker compose up -d
# OR
python my_vllm_app.py
```

### 8.3 Stop Gracefully

```bash
# Inside guest VM
docker compose down
# OR
docker stop vllm-server

# From host
sudo virsh shutdown v620-vm
```

---

## Phase 9: Performance Tuning

### 9.1 Optimize Power Settings

```bash
# Inside guest VM - For inference, maximize performance

# Set higher power cap if needed (up to 187W)
echo 180000000 | sudo tee /sys/class/drm/card0/device/hwmon/hwmon*/power1_cap

# Set max clocks
d=/sys/class/drm/card0/device
echo "s 1 2650" > $d/pp_od_clk_voltage  # Max core
echo "m 1 1075" > $d/pp_od_clk_voltage  # Max VRAM  
echo "c" > $d/pp_od_clk_voltage         # Commit
```

### 9.2 Monitor Under Load

```bash
# Inside guest VM - Watch while running inference
watch -n 1 '
echo "Power: $(cat /sys/class/drm/card0/device/hwmon/hwmon*/power1_average | awk "{print \$1/1000000}" )W"
echo "Temp: $(cat /sys/class/drm/card0/device/hwmon/hwmon*/temp1_input | awk "{print \$1/1000}" )°C"
'
```

---

## Phase 10: Troubleshooting

### 10.1 Docker Can't Access GPU

**Problem:** `docker run` fails with GPU errors

**Solution:** Use AMD device passthrough syntax
```bash
# Wrong (NVIDIA syntax):
docker run --gpus all ...

# Right (AMD syntax):
docker run --device=/dev/kfd --device=/dev/dri -v /dev/dri:/dev/dri ...
```

### 10.2 Can't Access vLLM from Host

**Problem:** `curl localhost:8000` fails from host

**Solution:** Use guest IP or SSH tunnel
```bash
# Use guest IP
curl http://192.168.122.54:8000

# Or SSH tunnel
ssh -L 8000:localhost:8000 ubuntu@192.168.122.54
```

### 10.3 VM Won't Start (GPU Wedged)

**Problem:** VM fails to start, GPU shows `rev ff`

**Solution:** SMU wedge - host reboot required
```bash
# From host
sudo reboot
```

### 10.4 Performance Seems Slow

**Problem:** Inference slower than expected

**Check:**
```bash
# Inside guest VM
# 1. Verify 170W power cap is set
cat /sys/class/drm/card0/device/hwmon/hwmon*/power1_cap

# 2. Check for throttling
cat /sys/class/drm/card0/device/hwmon/hwmon*/temp1_input

# 3. Verify clocks
cat /sys/class/drm/card0/device/pp_od_clk_voltage

# 4. Check GPU is actually being used
rocm-smi
```

---

## Quick Reference Commands

### Host Side

```bash
# Start VM
sudo virsh start v620-vm

# Stop VM
sudo virsh shutdown v620-vm

# VM status
sudo virsh list

# Find VM IP
ip neigh | grep "52:54"

# SSH to VM
ssh ubuntu@192.168.122.54
```

### Guest Side

```bash
# Check GPU
lspci | grep amd
lsmod | grep amdgpu

# Check power
cat /sys/class/drm/card0/device/hwmon/hwmon*/power1_cap

# Docker with AMD GPU
docker run --device=/dev/kfd --device=/dev/dri -v /dev/dri:/dev/dri ...

# Monitor GPU
watch -n 1 'cat /sys/class/drm/card0/device/hwmon/hwmon*/{temp1_input,power1_average}'
```

---

## Recommended Workflow

### Daily Usage

1. **Boot VM**
   ```bash
   sudo virsh start v620-vm
   ```

2. **SSH In**
   ```bash
   ssh ubuntu@192.168.122.54
   ```

3. **Start Workloads**
   ```bash
   cd ~/my-inference-app
   docker compose up -d
   ```

4. **Work from Host**
   ```bash
   # Use SSH tunnel for API access
   ssh -L 8000:localhost:8000 ubuntu@192.168.122.54
   # Now http://localhost:8000 works
   ```

5. **Shutdown When Done**
   ```bash
   # In guest: stop services
   docker compose down
   
   # From host: stop VM
   sudo virsh shutdown v620-vm
   ```

---

## Why This Architecture?

**Q:** Why not just run Docker on host with the V620?

**A:** The V620 needs special treatment:
- **No FLR reset** - can't be shared between host and guest
- **SMU wedge risk** - host driver operations can crash the card
- **VBIOS unlock** - requires VM passthrough to apply safely
- **Clean isolation** - VM gives dedicated GPU environment

**Q:** Can I run GPU workloads on host?

**A:** No practical way. The V620 is bound to vfio-pci for passthrough. The host only has ASPEED graphics. All GPU work must happen in the guest.

**Q:** Is the VM network fast enough?

**A:** Yes. The virtual bridge (virbr0) operates at near-native speeds. For external access, use SSH tunnels or port forwarding.

---

## Advanced: GPU Passthrough Explained

### What Actually Happens

1. **Host boots** → V620 bound to vfio-pci (not amdgpu)
2. **VM starts** → QEMU claims V620 PCI device
3. **Guest boots** → Guest sees V620 as physical GPU at 05:00.0
4. **Guest driver** → amdgpu driver loads in guest (not host)
5. **VBIOS patch** → Guest reads patched ROM from QEMU
6. **GPU works** → Guest uses V620, host has no access

### Why This Is Safe

- **Host isolation** → Host can't touch GPU, can't wedge SMU
- **Guest crash** → VM restarts, GPU stays healthy
- **Clean shutdown** → VM properly releases GPU
- **Wedge recovery** → Host reboot only if SMU actually wedges

---

## File Locations

### On Host
- VM config: `/etc/libvirt/qemu/v620-vm.xml`
- ROM files: `/usr/share/qemu/v620-170w-final.rom`
- Disk images: `/var/lib/libvirt/images/v620-vm.qcow2`

### In Guest
- Your workloads: `/home/ubuntu/`
- Docker containers: Running in guest
- GPU access: `/sys/class/drm/card0/`

---

## Next Steps

1. **Set up SSH key auth** for seamless VM access
2. **Install LLM stack** in guest (vLLM, transformers, etc.)
3. **Configure port forwarding** for external API access
4. **Monitor performance** under load
5. **Tune power/clocks** for optimal inference speed

Your V620 is ready for LLM inference at 170W! 🚀
