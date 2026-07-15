#!/bin/bash
# Verify V620 core-clock control by measuring fp16 matmul TFLOPS at several
# OverDrive caps. The clock *sensor* always reads 0 on this card, so scaling
# throughput is the proof that the caps apply.
#
# Usage:
#   ./odbench.sh                 # python3 with torch+ROCm on the VM itself
#   ./odbench.sh <container>     # run benchmark inside a docker container
set -u
d=/sys/class/drm/card0/device
CONTAINER="${1:-}"

cat > /tmp/bench.py <<'EOF'
import torch, time
a = torch.randn(4096, 4096, dtype=torch.float16, device="cuda")
b = torch.randn_like(a)
for _ in range(10):
    c = a @ b
torch.cuda.synchronize()
t = time.time()
for _ in range(200):
    c = a @ b
torch.cuda.synchronize()
el = time.time() - t
print(f"TFLOPS: {200*2*4096**3/el/1e12:.2f}")
EOF

if [ -n "$CONTAINER" ]; then
    docker cp /tmp/bench.py "$CONTAINER":/tmp/bench.py >/dev/null
    bench() { docker exec "$CONTAINER" python3 /tmp/bench.py; }
else
    bench() { python3 /tmp/bench.py; }
fi

run_at () {
    echo "== core soft max $1 MHz =="
    echo "s 1 $1" > "$d/pp_od_clk_voltage" && echo c > "$d/pp_od_clk_voltage"
    sleep 1
    bench
}

run_at 900
run_at 1500
run_at 2650
# restore stock clocks
echo r > "$d/pp_od_clk_voltage" && echo c > "$d/pp_od_clk_voltage"
echo "restored stock clocks"
echo "SMU wedge count (must be 0): $(dmesg | grep -c 'not done with')"
