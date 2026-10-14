# Crystal System hardware notes

Authority: staged MAME 0.289 `src/mame/misc/crystal.cpp`, device files and `mame_listxml.txt`. Board/cart component table and feasibility/clock/bandwidth choices are in root `plan.md`; donor choices are in `DONOR_MAP.md`.

## CPU-visible map

| Range | Function |
|---|---|
| `00000000–0001ffff` | 128 KiB BIOS ROM; writes ignored |
| `01200000–01200003` | P1/P2 active-low inputs; low-byte writes drive coin counters |
| `01200004–01200007` | P3/P4 base-system inputs |
| `01200008–0120000b` | System/DIP read; `(SYSTEM << 16) | DSW | ff00ff00` |
| `01280000–01280003` | Flash bank write, `(data >> 1) & 7` |
| `01320000–01320003` | Lamps/output write; lane mask `00ff00ff` |
| `01400000–0140ffff` | 64 KiB NVRAM, default zero |
| `01800000–01ffffff` | VRender0 SoC registers |
| `01802004–01802007` | GPIO latched output / DS1302 CE/SCLK/data |
| `01802008–0180200b` | GPIO external input / RTC data at bit 28 |
| `02000000–027fffff` | 8 MiB main RAM, mirrored at `02800000–02ffffff` |
| `03000000–0300ffff` | VRender0 video register space |
| `03800000–03ffffff` | 8 MiB texture RAM, also packet/audio source |
| `04000000–047fffff` | 8 MiB framebuffer RAM, also audio source |
| `04800000–04800fff` | VRender0 sound registers |
| `05000000–05ffffff` | Selected 16 MiB cartridge flash window |
| `05000000–05000003` | Flash command/read-ID handler overrides first word |
| `44414f4c–44414f7f` | MAME test-menu reset compatibility RAM/code |

SoC register offsets relative to `01800000`: SYSID/CFGR at `0000/0004`; watchdog area `0010`; two DMA blocks `0800/0810`; IRQ vector/enable/status `0c04/0c08/0c0c`; UART blocks `1000/1020`; four timer pairs `1400–141f`; PWM area `1800`; GPIO `2000`; peripheral chip-select `2400`; SIO `2800`; CRTC `3400–37ff`; RAMDAC/PLL area `4000`. Several areas are source comments/unimplemented in MAME; do not invent behavior for unobserved registers.

Video register offsets relative to `03000000`: queue front `0080`, rear read `0082`, renderer control `008c`, display bank read `008e`, bank1 select `0090`, flip count `00a6`. `get_packet` reads texture-memory halfwords, not frame RAM. Queued state updates persist between packets. Actual packet stride/wrap and buffer addressing must follow the source functions.

Sound offsets relative to `04800000`: channel bank `000–3ff` (32 bytes/channel), status `404`, note-on `408`, reverb/buffer fields `410/412/420/422/440/442`, interrupt mask `480`, pending `500`, channel count `600`, control `602`. The source's channel accessors and update loop define widths/semantics; this table is an index, not a complete register specification.

## ROM inventory

| Image | Size | CRC32 | SHA1 from MAME |
|---|---:|---|---|
| `mx27l1000.u14` (default AMG0110B) | 131072 | beff39a9 | b6f6dda58d9c82273f9422c1bd623411e58982cb |
| `mx27l1000-alt.u14` (AMG0110D alternative) | 131072 | 1e8175c8 | f60c016be2ff11e47b2192acddb92676043af501 |
| `bcsv0004f01.u1` | 16777216 | 8feff120 | 2ea42fa893bff845b5b855e2556789f8354e9066 |
| `bcsv0004f02.u2` | 16777216 | 0e799845 | 419674ce043cb1efb18303f4cb7fdbbae642ee39 |
| `bcsv0004f03.u3` | 16777216 | 659e2d17 | 342c98f3f695ef4dea8b533612451c4d2fb58809 |

Three cartridge files concatenate at flash offsets `0000000`, `1000000`, `2000000`. Banks 3–7 are absent and return FF. Flash read command FF returns normal first word; command 90 returns `00180089` for present banks and FFFFFFFF for absent banks; other commands return zero in the current driver. `machine_reset` restores bank 0 and command FF. Full Intel program/erase logic is not automatically required for this read-only game; implement an additional command only if the actual reference/game contract requires it.

## Protection and reset compatibility

`init_crysking` writes these **little-endian 16-bit values at byte offsets in the first cartridge flash file**. Keep original archives untouched and implement a deterministic loader/read overlay:

| Byte offset | Halfword |
|---|---|
| `00007bb6` | df01 |
| `00007bb8` | 9c00 |
| `0000976a` | 901c |
| `0000976c` | 9001 |
| `00008096` | 90fc |
| `00008098` | 9001 |
| `00008a52` | 4000 |
| `00008a54` | 403c |

This is an explicit MAME-compatible protection approximation. There is no crysking PIC dump in the set. MAME's notes speculate about an 18-pin PIC and bit-banged PIO data/reset at bits 29/30 with 8-even-1 framing; they do not establish the MCU model, firmware or exact protocol. A PIC16C57-compatible donor is a research fallback only.

Separately, `patchreset` populates the special reset RAM at `44414f4c` with six little-endian 32-bit words: `40c0ea01 e906400a 40c02a20 e906400a a1d03a20 def4d4fa`. MAME explains this as a test-menu reset-vector workaround. Keep it in the kludge ledger, not confused with protection or a real PCB RAM chip.

## Known uncertainty

MAME XML marks the machine overall imperfect; SE3208 interpreter cycle count is abstract. SoC dynamic PLL/VCLK, video dither, async/front drawing/display-start behavior and sound source/divider/effects carry TODOs. Retain the pinned reference's behavior as the first working target and document fidelity limits. Initial source comparison found no local functional changes from official 0.289 in the seven key device files.

Physical board notes identify all three SDRAM chips, SRAM, BIOS, RTC, reset supervisor, PAL, audio DAC/amplifier, coin driver, switches/crystals/connectors and flash/decoder/protection MCU. They do not provide a complete schematic, PAL dump or component photo inventory. Main/project feasibility is addressed in `plan.md`; actual FPGA fit is only established in the final build phase.
