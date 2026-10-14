# PROM dump-to-pin bridge

The conventional bridge is now supported by an independent manufacturer pinout and an explicit open-source reader: file bits 0–3 correspond to physical O1–O4, and ordinary integer address bit k drives Ak. No inversion or address permutation relative to those chip address labels is indicated. This establishes a source-qualified convention, while the historical Sheriff chip-read provenance remains unknown.

The [1978 Signetics manufacturer manual](https://frank.pocnet.net/other/sos/Philips_elcoma_Signetics_Bipolar%26MOSMemories_1978.pdf), printed page 122/PDF page 124, defines A0–A9 pins as `5,6,7,4,3,2,1,17,16,15`, O1–O4 as `14,13,12,11`, and active-low enables at 8 and 10. Its physical output level is positive: the conventional file needs no output inversion.

Stephen Henson's [reader database](https://gitlab.com/snhenson/mprom/-/blob/aea3aa03e83dffa7a7d05ddd5565fd0ae51a1092/roms.xml#L23), pinned at `aea3aa03e83dffa7a7d05ddd5565fd0ae51a1092`, lists pins `15,16,17,1,2,3,4,7,6,5` for the address and `11,12,13,14` for data. The [reader](https://gitlab.com/snhenson/mprom/-/blob/aea3aa03e83dffa7a7d05ddd5565fd0ae51a1092/mprom#L150) preserves list order, applies binary address digits most-significant first, and shifts each sampled output into the result most-significant first. It appends one byte for each ascending address and writes those bytes directly (lines 119–131). Thus pin14 is bit0/O1, pin13 bit1/O2, pin12 bit2/O3 and pin11 bit3/O4. Source lines 58–64,150–190,192–200 retain the complete ordering chain. This reader was inspected, not executed against hardware.

The connected related Bandido sheets 33/34 establish the actual board address wiring:

| Chip address | Physical pin | PIO net | PIO pin |
|---|---:|---|---:|
| A0 | 5 | H0 | 31 |
| A1 | 6 | H1 | 33 |
| A2 | 7 | H2 | 35 |
| A3 | 4 | H3 | 37 |
| A4 | 3 | H4 | 39 |
| A5 | 2 | V3 | 44 |
| A6 | 1 | V4 | 46 |
| A7 | 17 | V5 | 47 |
| A8 | 16 | V6 | 48 |
| A9 | 15 | V7 | 49 |

Therefore the chip's integer address is `{V7,V6,V5,V4,V3,H4,H3,H2,H1,H0}` using the actual post-XOR PIO nets. CS1(8) and CS2(10) are tied low. The retained left/right views have original pixel boxes `[4100,2160,5088,3100]` on sheet33 and `[0,2160,2200,2930]` on sheet34. Pin labels and connected connector lanes match the manufacturer's pinout.

This is distinct from claiming that current RTL raster counters and flip phase already reproduce those PIO nets. MAME's lookup `32*(y>>3)+(x>>3)` supports the familiar block-address interpretation functionally; the existing timing/source qualification must supply the counter and flip bridge. No phase shift is proposed here.

The user-staged MAME0.289 source declares `82s137.3l`, 1024 bytes, CRC32 `820f8cdd`, SHA1 `197eeb008c140558e7c1ab2b2bd0f6a27096877c` at lines1384–1385. That is an expected dump identity, not a measured record of the original programmer, adapter or preprocessing. Those historical details are unknown. No ROM bytes were copied or published.

`docs/evidence/sheriff_prom_dump_pin_bridge.json` retains the primary PDF, source/render/viewport hashes, immutable reader URLs, pin equations and source-only limits. `_checks/agent-prom-bridge-20261010/qualify_bridge.py` verifies the reader's pin arrays against the visually inspected primary pinout and checks immutable source equality and retained hashes; it does not repeat a behavioral truth table. Exact Sheriff revision and electrical propagation remain open. No production mapping correction is required by this evidence.
