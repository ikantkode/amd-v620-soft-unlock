#!/usr/bin/env python3
"""Rebuild v620-odcaps.rom from a clean V620 VBIOS dump.

The VBIOS image is dumped in the guest from debugfs:
    cat /sys/kernel/debug/dri/0/amdgpu_vbios > v620_vbios.rom  (26624 bytes)

The 2470-byte smu11 PowerPlay table lives verbatim inside it. This script
enables the first four OverDrive capability flags in that table:
    cap 0 GFXCLK_LIMITS, cap 1 GFXCLK_CURVE, cap 2 UCLK_LIMITS, cap 3 POWER_LIMIT
then fixes the ATOM ROM 8-bit checksum (byte 0x21, whole image sums to 0 mod 256).

Deploy on the Proxmox host:
    cp v620-odcaps.rom /usr/share/kvm/
    qm set <VMID> -hostpci0 0000:XX:00,pcie=1,romfile=v620-odcaps.rom
    qm shutdown <VMID> && qm start <VMID>
"""
import sys

PPTABLE_HEADER = bytes.fromhex("a6090f00")  # structuresize=2470, fmt rev 15, content rev 0
OD_CAPS_OFFSET = 194                        # overdrive_table.cap[0..3] within the pptable
CHECKSUM_OFFSET = 0x21

rom = bytearray(open(sys.argv[1] if len(sys.argv) > 1 else "v620_vbios.rom", "rb").read())
assert sum(rom) % 256 == 0, "input ROM checksum invalid — bad dump?"

base = rom.find(PPTABLE_HEADER)
assert base != -1, "pptable not found"
print(f"pptable at {base:#x}")

for i in range(4):
    assert rom[base + OD_CAPS_OFFSET + i] in (0, 1)
    rom[base + OD_CAPS_OFFSET + i] = 1

rom[CHECKSUM_OFFSET] = (rom[CHECKSUM_OFFSET] - (sum(rom) % 256)) % 256
assert sum(rom) % 256 == 0

open("v620-odcaps.rom", "wb").write(bytes(rom))
print("wrote v620-odcaps.rom")
