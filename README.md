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

Not using a VM? The same delivery idea has a baremetal equivalent that feeds the
driver a patched image at boot without `romfile=` and without flashing — see
[Baremetal (no VM) variant](#baremetal-no-vm-variant--acpi-vfct-override) below.

## Requirements

- V620 passed through to a Linux VM. Tested on Proxmox 9.1 with an Ubuntu
  24.04 guest (amdgpu DKMS 6.10.5 / ROCm 6.3, kernel 6.8, SMU firmware 58.90);
  plain QEMU/libvirt works the same way.
- Root on host and guest.
- The GPU already working in the guest (amdgpu bound, ROCm/Vulkan functional).

# Passthrough VM — step by step

This is the tested path (Proxmox + Ubuntu guest). For a machine running amdgpu
directly on the metal, skip to [Baremetal (no VM)
variant](#baremetal-no-vm-variant--acpi-vfct-override).

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

# Baremetal (no VM) variant — ACPI VFCT override

> **Status: untested / experimental.** Unlike the passthrough flow above (which
> is battle-proven), this section is derived from the amdgpu source and the
> kernel's documented ACPI-override mechanism but has **not** been verified on
> real hardware here. Try it only with a known-good recovery boot ready, and
> please open an issue with results. The same **no-FLR wedge danger** applies —
> re-read the [Warnings](#-warnings) first.

Without a hypervisor there's no `romfile=` — but you don't need one. On a
**discrete** GPU, amdgpu looks for its VBIOS in a fixed order:

```
ATRM (ACPI)  →  VFCT (ACPI table)  →  VRAM BAR  →  ROM BAR  →  …
```

`VFCT` is an ACPI table that can carry the whole VBIOS image, and it is consulted
**before** the card's physical ROM BAR. amdgpu matches a VFCT image to a card by
PCI **vendor + device + slot + function**. So if you inject a VFCT whose embedded
image is your *patched* dump, the driver reads the patched PowerPlay table at
init and hands it to the SMU exactly as `romfile=` does in a VM — no flash, no
runtime `pp_table` write, nothing written to the card. The kernel lets you inject
an ACPI table from the initramfs via `CONFIG_ACPI_TABLE_UPGRADE`.

Why not just flash the patched image instead? You can't — RDNA2 VBIOSes are PSP
signed, so an unsigned modified image is rejected at flash time (only the signed
W6800 image flashes, and that costs 12 CUs). VFCT delivery works precisely
*because* it's a boot-time read, not a flash: the SMU accepts an unsigned
PowerPlay table at init, the same window the VM route uses.

### Step 1 — kernel flag (host)

Same as the VM's Step 1, but on the baremetal host's bootloader:

```bash
# /etc/default/grub  →  GRUB_CMDLINE_LINUX_DEFAULT="... amdgpu.ppfeaturemask=0xffffffff"
sudo update-grub   # (or grub-mkconfig; on systemd-boot edit the entry's options=)
```

GRUB's role stops here — it passes the flag and loads the initramfs. It cannot
inject a VBIOS itself; option-ROM shadowing happens in firmware before GRUB runs.

### Step 2 — dump and patch (host)

Exactly the VM's Steps 2–3, run on the metal:

```bash
sudo cat /sys/kernel/debug/dri/0/amdgpu_vbios > v620_vbios.rom   # pick the right dri index
python3 make_odcaps_rom.py v620_vbios.rom                        # -> v620-odcaps.rom
```

### Step 3 — wrap the patched ROM in a VFCT table

This is the fiddly part and the reason the section is experimental — there's no
turnkey tool. A VFCT is a standard ACPI table (`'VFCT'` signature + 36-byte ACPI
header) followed by a GOP image directory; each image entry has a header
carrying the target **PCI bus / device / function**, vendor/device IDs,
subsystem IDs, revision and image length, immediately followed by the raw VBIOS
bytes. To build one:

- one image entry per card (a single VFCT can hold **both** V620s — give each
  entry that card's bus/dev/fn and its own patched image);
- set each entry's vendor/device to `1002:73a1` and the bus/dev/fn to match
  `lspci`;
- append the patched ROM bytes as the image body and set `ImageLength`;
- fix the ACPI table checksum (whole table sums to 0 mod 256) and `Length`.

The kernel's `struct acpi_vfct` / image-header layout in
[`amdgpu_acpi_vfct_bios()`](https://github.com/torvalds/linux/blob/master/drivers/gpu/drm/amd/amdgpu/amdgpu_bios.c)
is the authoritative field reference. Save the result as `vfct.aml`.

### Step 4 — inject the table via initramfs

The kernel reads override tables from an **uncompressed** cpio prepended to the
initrd, at the fixed path `kernel/firmware/acpi/`:

```bash
mkdir -p kernel/firmware/acpi
cp vfct.aml kernel/firmware/acpi/
find kernel | cpio -H newc --create > acpi_override.cpio   # do NOT compress this cpio
```

Prepend it to your initramfs and boot with `CONFIG_ACPI_TABLE_UPGRADE` enabled
(and `ACPI_TABLE_UPGRADE_VIA_BUILTIN_INITRD` if the initrd is built into the
kernel). Distros differ on how the extra cpio is attached — some let you list it
as an early-microcode-style initrd, others want it concatenated ahead of the
real initramfs image. See the kernel doc
[*Upgrading ACPI tables via initrd*](https://docs.kernel.org/admin-guide/acpi/initrd_table_override.html).

### Step 5 — verify

After reboot, confirm the driver actually took the VFCT image and not the ROM
BAR:

```bash
sudo dmesg | grep -i vbios     # expect "Fetched VBIOS from VFCT" (not "from ROM BAR")
cat /sys/class/drm/card0/device/pp_od_clk_voltage   # same OD_RANGE as the VM route
```

From here everything is identical to the VM path — the same `pp_od_clk_voltage`
writes, the same `tools/v620` helper, the same LACT setup.

### Baremetal caveats

- **ATRM is tried first.** It exists mainly on switchable-graphics laptops; on
  desktop/server boards it's normally absent, so VFCT is reached. If `dmesg`
  shows the VBIOS came from ATRM, that path is winning and you'll need to disable
  it or fall back to a different board.
- **Recovery is a reboot, not a config edit.** There's no `romfile=` to delete —
  if a bad table hangs GPU init, drop the cpio override and reboot from a spare
  entry. The no-FLR wedge rule below still bites.
- If VFCT delivery proves impractical on your board, the remaining options are
  the **W6800 signed cross-flash** (permanent, −12 CUs) or a tiny **amdgpu
  source/DKMS patch** that forces `cap[0..3]` after the VBIOS parse (safe and
  clean, but a kernel-module build you carry across updates).

> **Disclaimer.** The baremetal steps above are a general outline, not a
> copy-paste recipe. VFCT layout, initramfs handling, bootloader syntax and
> kernel config vary by board, distro and card revision, so expect to adapt them
> to your setup — and understand each step before running it, since a wrong
> PowerPlay table can wedge the SMU (see the warnings below). If you get stuck
> adapting the details (building the `vfct.aml`, wiring the initramfs cpio,
> reading the amdgpu source), an LLM such as [Claude](https://claude.ai) is a
> good assistant for fitting these instructions to your specific hardware and
> distro. Verify its output against the linked kernel docs and source before you
> boot with it.

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
