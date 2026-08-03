# V620 VM Autostart & Service Management

**Recommendation:** YES - Set up autostart for dedicated LLM inference server

## Why Autostart Makes Sense

- ✓ GPU always available after host boot
- ✓ No manual intervention needed
- ✓ Docker/vLLM services can auto-start inside VM
- ✓ Consistent environment for inference
- ✓ Acts like a dedicated inference appliance

## Architecture Overview

```
Host Boot
    ↓
libvirt autostart v620-vm
    ↓
VM boots → 170W GPU available
    ↓
Systemd starts docker-compose
    ↓
vLLM server ready at 192.168.122.54:8000
    ↓
Ready for inference requests
```

---

## Phase 1: Enable VM Autostart

### 1.1 Set VM to Autostart

```bash
# From host
sudo virsh autostart v620-vm

# Verify it's set
sudo virsh list --all --autostart
```

**Expected output:**
```
 Id    Name             State
------------------------------------
 -     v620-vm          shut off (autostart)
```

### 1.2 Test Autostart

```bash
# Reboot host
sudo reboot

# After reboot, wait 1-2 minutes and check
sudo virsh list
# Should show v620-vm running
```

---

## Phase 2: Auto-Start Services Inside VM

### 2.1 Create Systemd Service for Docker Compose

**SSH into VM:**
```bash
ssh ubuntu@192.168.122.54
```

**Create systemd service:**
```bash
sudo vim /etc/systemd/system/vllm.service
```

**Add this configuration:**
```ini
[Unit]
Description=vLLM Inference Server
Requires=docker.service
After=docker.service network.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/home/ubuntu/vllm
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down
TimeoutStartSec=300
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
```

### 2.2 Enable Service

```bash
# Reload systemd
sudo systemctl daemon-reload

# Enable service
sudo systemctl enable vllm.service

# Start service manually (to test)
sudo systemctl start vllm.service

# Check status
sudo systemctl status vllm.service
```

---

## Phase 3: Create Docker Compose Configuration

### 3.1 Setup Directory Structure

```bash
# In VM
mkdir -p ~/vllm
cd ~/vllm
```

### 3.2 Create docker-compose.yml

**File:** `~/vllm/docker-compose.yml`

```yaml
services:
  vllm:
    image: vllm/vllm-openai:latest
    container_name: vllm-inference
    restart: unless-stopped
    devices:
      - /dev/kfd
      - /dev/dri
    volumes:
      - /dev/dri:/dev/dri
      - ./models:/models:ro  # Read-only model cache
    environment:
      - HIP_VISIBLE_DEVICES=0
      - VLLM_WORKER_MULTIPROC_METHOD=spawn
    ports:
      - "8000:8000"
    command: >
      --model meta-llama/Llama-3.1-8B-Instruct
      --tensor-parallel-size 1
      --gpu-memory-utilization 0.9
      --max-model-len 8192
      --dtype auto
      --enable-prefix-caching
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8000/health"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 60s
```

### 3.3 Test Manually First

```bash
cd ~/vllm

# Test docker compose
docker compose up -d

# Check logs
docker compose logs -f

# Test API
curl http://192.168.122.54:8000/v1/models

# If working, stop and let systemd manage it
docker compose down
```

---

## Phase 4: Safety & Monitoring

### 4.1 Add Boot Delay (Optional but Recommended)

**Why:** Prevents VM from starting too early during host boot

**Edit VM config:**
```bash
# From host
sudo virsh edit v620-vm
```

**Add to `<devices>` section:**
```xml
<pm>
  <suspend-to-mem enabled='no'/>
  <suspend-to-disk enabled='no'/>
</pm>
```

**Or add boot delay in metadata:**
```bash
sudo virsh metadata v620-vm --set --metadata "boot_delay=30"
```

### 4.2 Create Monitoring Script

**In VM, create health check:**
```bash
vim ~/health-check.sh
```

```bash
#!/bin/bash
# V620 Health Check Script

echo "=== V620 VM Health Check ==="
echo "Time: $(date)"

# GPU presence
if lspci | grep -q "V620"; then
    echo "✓ V620 GPU present"
else
    echo "✗ V620 GPU missing!"
    exit 1
fi

# Driver loaded
if lsmod | grep -q amdgpu; then
    echo "✓ amdgpu driver loaded"
else
    echo "✗ amdgpu driver not loaded!"
    exit 1
fi

# Power cap set
POWER_CAP=$(cat /sys/class/drm/card0/device/hwmon/hwmon*/power1_cap)
if [ "$POWER_CAP" -eq 170000000 ]; then
    echo "✓ Power cap set to 170W"
else
    echo "⚠ Power cap at $(($POWER_CAP / 1000000))W (expected 170W)"
fi

# vLLM running
if curl -s http://localhost:8000/health > /dev/null; then
    echo "✓ vLLM server responding"
else
    echo "✗ vLLM server not responding!"
fi

# GPU temp
TEMP=$(cat /sys/class/drm/card0/device/hwmon/hwmon*/temp1_input)
echo "GPU Temp: $(($TEMP / 1000))°C"

# Power usage
POWER=$(cat /sys/class/drm/card0/device/hwmon/hwmon*/power1_average)
echo "Power Usage: $(($POWER / 1000000))W"

echo "=== Health Check Complete ==="
```

**Make executable:**
```bash
chmod +x ~/health-check.sh

# Test it
./health-check.sh
```

### 4.3 Add to Crontab (In VM)

```bash
# Run health check every 5 minutes
crontab -e

# Add:
*/5 * * * * /home/ubuntu/health-check.sh >> /var/log/v620-health.log 2>&1
```

---

## Phase 5: Power Management (Optional)

### 5.1 Idle Power Reduction

**Consider:** Reduce power when not in use (saves power, extends GPU life)

**Create idle-power.service:**
```bash
sudo vim /etc/systemd/system/idle-power.service
```

```ini
[Unit]
Description=Reduce GPU power when idle
After=vllm.service

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo 120000000 > /sys/class/drm/card0/device/hwmon/hwmon*/power1_cap'
[Install]
WantedBy=multi-user.target
```

**Create full-power.service:**
```bash
sudo vim /etc/systemd/system/full-power.service
```

```ini
[Unit]
Description=Restore full GPU power
After=vllm.service

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo 170000000 > /sys/class/drm/card0/device/hwmon/hwmon*/power1_cap'
[Install]
WantedBy=multi-user.target
```

### 5.2 Power Schedule (Optional)

**In VM crontab:**
```bash
# Reduce power at night (2AM - 8AM)
0 2 * * * sudo systemctl start idle-power.service
0 8 * * * sudo systemctl start full-power.service
```

---

## Phase 6: Troubleshooting Autostart

### 6.1 VM Not Starting on Boot

**Check autostart status:**
```bash
# From host
sudo virsh list --autostart

# If not autostart:
sudo virsh autostart v620-vm
```

**Check libvirtd started:**
```bash
sudo systemctl status libvirtd
sudo systemctl enable libvirtd
```

### 6.2 VM Starts But Services Don't

**In VM, check service logs:**
```bash
sudo systemctl status vllm.service
sudo journalctl -u vllm.service -f
```

**Common fixes:**
```bash
# Docker not ready
# Edit service, add longer timeout:
TimeoutStartSec=60

# Network not ready
# Add dependency:
After=network-online.target
Wants=network-online.target
```

### 6.3 GPU Wedged After Reboot

**Check VM GPU status:**
```bash
# From host
virsh dumpxml v620-vm | grep hostdev

# In VM
lspci | grep V620
# If missing or shows rev ff, host reboot needed
```

---

## Phase 7: Recommended Setup

### Minimal Autostart (Recommended)

**Host side:**
```bash
sudo virsh autostart v620-vm
```

**VM side:**
```bash
# Enable vLLM service
sudo systemctl enable vllm.service

# Add health monitoring
crontab -e
# Add: */5 * * * * /home/ubuntu/health-check.sh
```

**Result:** 
- Host boots → VM starts → vLLM ready ~2-3 minutes later
- Full automation with health monitoring
- Easy to manage: stop service in VM when needed

### Full Automation (Advanced)

Add:
- Power scheduling for off-hours
- Automatic model updates
- Monitoring alerts
- Auto-recovery on failures

---

## Phase 8: Quick Start Guide

### First Time Setup

```bash
# 1. On host - Enable VM autostart
sudo virsh autostart v620-vm

# 2. SSH into VM
ssh ubuntu@192.168.122.54

# 3. Setup vLLM directory
mkdir -p ~/vllm && cd ~/vllm

# 4. Create docker-compose.yml (see Phase 3.2)
vim docker-compose.yml

# 5. Enable systemd service (see Phase 2.1)
sudo vim /etc/systemd/system/vllm.service
sudo systemctl enable vllm.service

# 6. Reboot host to test
sudo reboot
```

### Daily Usage

```bash
# After host boot (2-3 minutes)
# vLLM is automatically available at:
# http://192.168.122.54:8000

# Check status
ssh ubuntu@192.168.122.54 "./health-check.sh"

# Stop/start services manually
ssh ubuntu@192.168.122.54 "sudo systemctl stop vllm.service"
ssh ubuntu@192.168.122.54 "sudo systemctl start vllm.service"
```

---

## Benefits of This Setup

### Operational Benefits
- **Zero-touch startup** - Everything ready after host boot
- **Consistent environment** - Same config every time
- **Easy monitoring** - Single health check script
- **Simple management** - Systemd controls everything

### Safety Benefits
- **Clean shutdown** - Systemd handles graceful stops
- **Health monitoring** - Catch issues early
- **Power control** - Manage 170W target
- **Isolation** - VM issues don't affect host

### Development Benefits
- **Easy updates** - Just update docker-compose.yml
- **Model swapping** - Change models in compose file
- **Scaling** - Add more services as needed
- **Testing** - Stop/start services without reboot

---

## Comparison: Autostart vs Manual

| Aspect | Manual | Autostart |
|--------|--------|-----------|
| Startup time | 5 min manual work | 2-3 min automatic |
| Availability | Human dependent | Always on after boot |
| Monitoring | Manual checks | Automated health checks |
| Updates | Requires manual restart | Systemd handles restarts |
| Troubleshooting | Need to start services | Can check current state |
| Power usage | Can control manually | Always on (can schedule) |

---

## Final Recommendation

**YES, set up autostart with systemd management.**

**Configuration:**
1. VM autostart: `sudo virsh autostart v620-vm`
2. vLLM service in VM: systemd with docker-compose
3. Health monitoring: crontab with health check script

**Result:** Dedicated LLM inference appliance that's always ready after host boot.

Your V620 will be ready for inference within 2-3 minutes of host startup! 🚀
