# vLLM Gemma 4 Service - Auto-Start Configuration

## Service Overview

**Model:** Gemma 4 4B (INT4 quantized, compressed-tensors)  
**GPU:** AMD Radeon Pro V620 @ 170W (32GB VRAM)  
**Context:** 32,768 tokens (32k)  
**KV Cache:** fp8

## Access Points

| From | URL |
|------|-----|
| **LAN** | `http://192.168.1.170:8000` |
| **Host** | `http://192.168.1.170:8000` or `http://192.168.122.54:8000` |
| **Inside VM** | `http://localhost:8000` |

## Auto-Start Components

### 1. VM Autostart (Host)
- **Service:** libvirt-autostart
- **VM:** v620-test
- **Status:** ✅ Enabled
- **Command:** `virsh autostart v620-test`

### 2. Port Forwarding (Host)
- **Service:** vllm-port-forward.service
- **Binary:** socat
- **Status:** ✅ Enabled and running
- **Commands:**
  ```bash
  sudo systemctl status vllm-port-forward
  sudo systemctl restart vllm-port-forward
  ```

### 3. vLLM Container (VM)
- **Container:** vllm-gemma
- **Restart Policy:** unless-stopped
- **Status:** ✅ Auto-restart enabled
- **Image:** blivioniag/vllm-rdna:v0.22.1

## Boot Sequence (Automatic on Reboot)

1. **Host boots** → libvirt starts
2. **v620-test VM starts** → with GPU passthrough (V620 @ 170W ROM)
3. **VM network ready** → 192.168.122.54
4. **Docker starts** → vllm-gemma container auto-starts
5. **vLLM loads model** → ~30-45 seconds
6. **Host port forward starts** → socat binds 192.168.1.170:8000
7. **Service ready** → accessible at http://192.168.1.170:8000

## Manual Control

### Check Status
```bash
# VM status
virsh list --all

# Port forward status
sudo systemctl status vllm-port-forward

# Container status (from host)
ssh ubuntu@192.168.122.54 "docker ps | grep vllm"

# Health check
curl http://192.168.1.170:8000/health
```

### Restart Services
```bash
# Restart VM (takes down container too)
virsh reboot v620-test

# Restart port forward only
sudo systemctl restart vllm-port-forward

# Restart container (from host)
ssh ubuntu@192.168.122.54 "docker restart vllm-gemma"
```

## API Usage

```bash
# Chat completion
curl http://192.168.1.170:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "/app/model",
    "messages": [{"role": "user", "content": "Hello!"}],
    "max_tokens": 100
  }'
```

## System Specs

| Component | Spec |
|-----------|------|
| **VM RAM** | 47 GiB |
| **GPU VRAM** | 32 GiB |
| **Host IP** | 192.168.1.170 |
| **VM IP** | 192.168.122.54 |
| **Power Cap** | 170W (unlocked V620) |

## Files

- **VM Config:** `/etc/libvirt/qemu/v620-test.xml`
- **Host Service:** `/etc/systemd/system/vllm-port-forward.service`
- **VM Model:** `~/gemma/gemma-4-E4B-it-AWQ-INT4/` (in VM)
- **ROM File:** `/usr/share/qemu/v620-170w-final.rom`

---
*Last updated: $(date +%Y-%m-%d)*
