# AMD Radeon Pro V620 soft unlock — clock & power control in passthrough VMs

Working core-clock, VRAM-clock and power-limit control on the Radeon Pro V620
under Linux — **no VBIOS flash, no compute units lost, fully reversible**.

The V620 is a 32 GB Navi 21 cloud-gaming card that turns up cheap on the used
market, but its firmware locks all clock and power controls when the card is
passed through to a VM: no OverDrive, a fixed ~1825 MHz core pstate, and a
hard-locked 250 W power cap. LACT, CoreCtrl and raw sysfs all come up empty.

This repo unlocks it by patching **4 bytes** in a dump of the card's own VBIOS
and handing the patched image to QEMU as a virtual ROM (`romfile=`). Nothing is
written to the physical card.

**Measured result** (PyTorch fp16 4096³ matmul, ROCm):

| OD core clock cap | Throughput |
|-------------------|------------|
| 900 MHz           | 13.8 TFLOPS |
| 1500 MHz          | 22.6 TFLOPS |
| 2650 MHz          | 32.1 TFLOPS |

Plus: power limit adjustable 232–275 W (previously locked at 250), VRAM
overclockable to 1075 MHz, and LACT works normally.

## Why not the W6800 cross-flash?

The known community route is flashing the (signed, flashable) W6800 VBIOS onto
the V620. That works, but the W6800 image is configured for **60 compute
units — you lose 12 of the V620's 72 CUs**, and a flash is never zero-risk.

It also turns out to be unnecessary: the V620's own PowerPlay table already
contains a complete, sane OverDrive section (500–2650 MHz core, 674–1075 MHz
VRAM, ±10 % power) — AMD just shipped it with all 32 OverDrive **capability
flags zeroed**. Flip four of them and the driver exposes everything.

## Why the weird delivery mechanism?

You can't just fix those bytes in place:

- **Flashing a modified image is impossible** — RDNA2 VBIOSes are signed and
  verified by the card's PSP.
- **Runtime writes hard-wedge the SMU.** Both `pp_features` (force-enabling the
  DPM feature) and the sysfs `pp_table` override (which triggers an SMU reset)
  lock the firmware up ("`SMU: I'm not done with your previous command`"). The
  V620 has **no FLR reset**, so a wedged SMU survives VM restarts (QEMU dies
  with a `pci_irq_handler` assertion) and bus resets — only a full **host**
  reboot recovers the card. Ask us how we know.

But in a passthrough VM there's a clean third path: QEMU's `romfile=` option
replaces the ROM BAR content the guest sees. The guest driver reads the VBIOS —
patched PowerPlay table included — during its normal boot init and hands it to
the SMU at the one moment the firmware accepts it. No flash, no runtime reset.
Delete `romfile=` and everything reverts.

## Requirements

- V620 passed through to a Linux VM. Tested on Proxmox 9.1 with an Ubuntu
  24.04 guest (amdgpu DKMS 6.10.5 / ROCm 6.3, kernel 6.8, SMU firmware 58.90);
  plain QEMU/libvirt works the same way.
- Root on host and guest.
- The GPU already working in the guest (amdgpu bound, ROCm/Vulkan functional).

## Step 1 — enable OverDrive in the guest kernel

The romfile patch makes the firmware *accept* OverDrive; this flag makes the
driver *expose* it. You need both. In the **guest**:

```bash
# /etc/default/grub
GRUB_CMDLINE_LINUX_DEFAULT="... amdgpu.ppfeaturemask=0xffffffff"
sudo update-grub
```

Don't reboot yet.

## Step 2 — dump the VBIOS from the guest

```bash
sudo cat /sys/kernel/debug/dri/0/amdgpu_vbios > v620_vbios.rom
```

If you have several GPUs, pick the right DRI index (`ls /sys/kernel/debug/dri/`).
The dump is ~26 KB — that's normal; it's the ATOM image the driver uses, not a
full flash dump.

> VBIOS images are AMD's copyrighted firmware, so this repo ships **no ROMs** —
> you patch your own card's dump, which also guarantees a match with your exact
> VBIOS revision.

## Step 3 — patch it

```bash
python3 make_odcaps_rom.py v620_vbios.rom
# -> writes v620-odcaps.rom
```

[`make_odcaps_rom.py`](make_odcaps_rom.py) locates the smu11 PowerPlay table by
signature, sets `overdrive_table.cap[0..3]` (GFXCLK_LIMITS, GFXCLK_CURVE,
UCLK_LIMITS, POWER_LIMIT) to 1, and fixes the ATOM 8-bit checksum. It asserts
at every step and refuses inputs it doesn't recognize.

Optional sanity check with [upp](https://github.com/sibradzic/upp):
`pip install upp && upp -p v620-odcaps.rom dump | grep -A8 "cap:"` — caps 0–3
should read `1`.

## Step 4 — attach the ROM to the VM

Proxmox:

```bash
cp v620-odcaps.rom /usr/share/kvm/
qm set <VMID> -hostpci0 0000:XX:00,pcie=1,romfile=v620-odcaps.rom
qm shutdown <VMID> && qm start <VMID>
```

Keep your existing hostpci options; only `romfile=` is new. On libvirt use
`<rom file="/path/v620-odcaps.rom"/>` inside the `<hostdev>`; on raw QEMU append
`romfile=` to the `-device vfio-pci` arguments.

## Step 5 — verify

```bash
cat /sys/class/drm/card0/device/pp_od_clk_voltage
```

Expected:

```
OD_SCLK:  0: 500Mhz   1: 2364Mhz
OD_MCLK:  0: 97Mhz    1: 1000MHz
OD_RANGE: SCLK: 500Mhz 2650Mhz
          MCLK: 674Mhz 1075Mhz
```

Power cap range should now read 232–275 W:

```bash
cat /sys/class/drm/card0/device/hwmon/hwmon*/power1_cap_{min,max}
```

Set clocks the standard AMD way:

```bash
d=/sys/class/drm/card0/device
echo "s 1 2650" > $d/pp_od_clk_voltage   # core soft max (MHz)
echo "m 1 1075" > $d/pp_od_clk_voltage   # VRAM max (MHz)
echo "c"        > $d/pp_od_clk_voltage   # commit
```

`echo r > pp_od_clk_voltage && echo c > pp_od_clk_voltage` restores stock.

**The core-clock sensor still reads 0 MHz** — the firmware's DPM telemetry
feature stays off even though clock control works. Verify with a benchmark
([`tools/odbench.sh`](tools/odbench.sh) runs the matmul test from the table
above via a ROCm PyTorch container), or watch power draw under load.

[`tools/v620`](tools/v620) is a small helper wrapping all of this:
`v620 core 2650`, `v620 vram 1075`, `v620 power 275`, `v620 status`,
`v620 watch`, `v620 mem 96` (DPM-level VRAM forcing), `v620 profile compute`.

## LACT

Once the OD table exists, [LACT](https://github.com/ilya-zlobintsev/LACT) works
normally. For a headless VM install the `lact-headless` package from its
releases page, then:

```bash
systemctl enable --now lactd
```

To control it from a desktop GUI on your LAN, add to the `daemon:` section of
`/etc/lact/config.yaml` in the VM:

```yaml
  tcp_listen_address: 0.0.0.0:12853
```

restart `lactd`, and use *Connect to remote daemon* in the GUI. `lactd`
re-applies saved settings at boot, making tuning persistent. Only expose the
port on a trusted LAN — the daemon has no authentication.

## ⚠️ Warnings

1. **Never write `pp_features` or the sysfs `pp_table` file on this card.**
   Instant SMU wedge; only a hypervisor **host reboot** recovers it (no FLR —
   VM restarts crash QEMU, GPU resets fail, bus resets don't help).
2. `romfile=` is **per-VM config**. Move the card to another VM and the unlock
   silently disappears until you add it there too.
3. Re-dump and re-patch after any card firmware update. The script locates the
   table by signature, so it normally adapts to revisions on its own.
4. Stock max is 2364 MHz; the table allows 2650 MHz / 275 W. The V620 is a
   **passive** server card — don't raise limits without real airflow. Junction
   and VRAM temperatures report correctly; watch them.
5. You're running the silicon outside AMD's shipped configuration, at your own
   risk. Nothing here modifies the card permanently, but overheating hardware
   doesn't care why it's hot.

## Repo contents

| File | Purpose |
|------|---------|
| `make_odcaps_rom.py` | The 4-byte + checksum VBIOS patcher |
| `tools/v620` | sysfs helper CLI for the unlocked card (guest) |
| `tools/odbench.sh` | TFLOPS-vs-clock-cap verification benchmark (guest) |

## Provenance

Worked out 2026-07-14 on a Proxmox 9.1 host (V620 → Ubuntu 24.04 VM). Two SMU
wedges and two host reboots were consumed so you don't have to.
