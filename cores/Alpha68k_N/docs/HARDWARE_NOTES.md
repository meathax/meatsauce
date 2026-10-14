# Alpha68k N hardware and memory contract

Baseline: MAME 0.289 `src/mame/alpha/alpha68k_n.cpp`, shared definitions in `alpha68k.h` / `alpha68k.cpp`. The N configuration uses a PROM palette callback; the later `alpha68k_palette` device is background reference rather than this board's palette implementation. `research/source_manifest.json` contains exact copied source paths and hashes.

## Target profiles and clock evidence

| Property | Kyros / Japan | Super Stingray Japan |
|---|---|---|
| Set / init | `kyros`, `kyrosj`, both `init_kyros` | `sstingry`, `init_sstingry` |
| Main CPU | 68000, 6,000,000 Hz | 68000, 6,000,000 Hz |
| Sound CPU | Z80/NEC D780C-1, 4,000,000 Hz | Z80, 3,579,545 Hz in MAME |
| MCU | Alpha 8511, 68705U3/HD6805-compatible; 3 MHz pin clock measured; MAME HLE | Alpha 8511 modeled by I8748, 9,263,750 Hz uncertain oscillator |
| Audio | 1 x YM2203 + 2 x AY-3-8910 + software DAC | Same digital chip complement |
| Sound device clocks | 2,000,000 Hz each | 2,000,000 Hz each |
| Main interrupts | IRQ1 vblank; IRQ2 periodic 60 Hz in HLE model | IRQ1 vblank; IRQ2 from MCU |
| Sound interrupts | IRQ0 vblank; NMI 4000 Hz | Same |
| Video | Eight banks of 2048 8x8x3bpp tiles | Four banks of 1024 8x8x3bpp tiles |
| Sentinel / bank shift | `0x20` / `13` | `0x40` / `0`, special color extraction |
| Orientation | ROT90; 3:4 displayed | ROT90; 3:4 displayed |
| Controls | 2 players, 8-way, 2 actions each, two coins, start | Same, alternate play/cocktail behavior verified per profile |
| Known MAME flag | `MACHINE_SUPPORTS_SAVE` | Also `MACHINE_IMPERFECT_TIMING` |

The proposed game master is 48 MHz. Pixel clock 6 MHz, main CPU 6 MHz, Kyros Z80 4 MHz, PSG/FM clock 2 MHz and candidate 68705 pin clock 3 MHz divide exactly. FX68K phase enables must represent the intended full CPU cycle; do not feed both phases at the nominal CPU enable frequency without checking the donor's contract. The 60 Hz Kyros MCU-model tick is independent of the approximately 59.185606 Hz frame rate. Stingray CPU/MCU use rational enables; T48's factor 15 is applied once.

Current MAME raw raster: **6 MHz / 384 / 264**, visible **X 0..255, Y 16..239**, H frequency 15,625 Hz, frame rate approximately **59.185606 Hz**. Use the current `set_screen_raw_params` helper and its actual constants in P1. Early PCB notes say 60 Hz/15.20 kHz; this is a retained uncertainty for hardware qualification, not permission to change the simulation oracle silently.

Game logic uses one clock. SDRAM can use the phase-related output required by its controller; HPS/HDMI/DDR framework clocks remain explicit standard interfaces. Every crossing has a real synchronizer/FIFO/handshake or documented generated-clock relation. Never hide game paths with broad false paths.

## Main CPU map

| Byte address | Size | Meaning |
|---|---|---|
| `0x000000..0x01ffff` | 128 KiB | Program ROM, 16-bit bus, even/odd EPROM lanes |
| `0x020000..0x020fff` | 4 KiB | Shared/work RAM; MCU mutates low bytes at selected words |
| `0x040000..0x041fff` | 8 KiB | Strip/sprite RAM |
| `0x060000..0x060001` | 1 word | Background color low byte; watchdog high byte in notes |
| `0x080000..0x0801ff` | 256 words | MCU command/trigger window; Kyros callback vs Stingray low-byte interface |
| `0x0c0000..0x0c0001` | 1 word | Both players' formatted controls |
| `0x0e0000` | 1 byte | DIPs on read; sound command latch on write, high byte of 68000 word |

MAME address-map byte masks and offset units are authoritative. A 68000 address is not a byte-array index after A0 is omitted. IRQ autovector acknowledgements must complete; an IRQ line held forever is a bus/acknowledgement defect, not fixed with a new CPU clock.

Kyros sound map: ROM `0x0000..0xbfff`, RAM `0xc000..0xc7ff`, latch read `0xe000`, latch clear `0xe002`, DAC write `0xe004`, ignored board-I/O writes `0xe006..0xe00e`. Stingray: ROM `0x0000..0x7fff`, RAM `0x8000..0x87ff`, latch read at `0xc100`; extract the remaining clear/DAC addresses directly from `sstingray_state::sound_map` when implementing rather than borrowing Kyros addresses.

Common sound I/O: YM address/data writes at `0x10/0x11`; AY1 data/address `0x80/0x81`; AY2 data/address `0x90/0x91`. Register selections persist between writes and reset deterministically.

## Graphics contract

There is no independent conventional background tilemap in this N renderer. Three groups of vertical strips create the scene. Each group has **32 strips**, each carrying **32 8x8 tiles**. Read position words at `offs+c`, tile words at `offs+d+i`, with `offs=0..0x3e0` step `0x20`. Group order is `(c=2,d=0x0800)`, `(3,0x0c00)`, `(1,0x0400)`. Word offsets here are not byte addresses.

Start `mx` from the position low byte; `my=-(position>>8)&0xff`. Advance Y by 8 modulo 256, or subtract 8 when native flip is active. Native flip uses `my=249-my`, tile X flip and Y-flip XOR; it is not a license to replace all board geometry with a generic 180-degree framebuffer transform. Stingray adjusts `mx>0xf8` by subtracting 256.

For Kyros: `bank=(data>>10)&3`, then `bank += (data>>13)&4`; `tile=(data&0x3ff)+((data>>3)&0x400)`. The 8 KiB color PROM address is `(data>>1 & 0x1000) | (data & 0xffc) | (data>>14 & 3)`. All color values, including `0xff`, render; MAME's 32-color gfx bank reduces the color code modulo 32, so form the palette pen from `(color & 0x1f)*8 + pixel_pen`. Do not suppress `0xff` before this reduction. For Stingray: `color=(data>>7 & 0x18) | (data>>13 & 7)`, with its four layout banks. Pen zero is transparent. Preserve sentinel tile suppression separately.

Kyros GFXDECODE offsets are `0x00000,0x18000,0x30000,0x48000`, each with two layouts. Layout 1 planes are `{4,0x8000*8,0x8000*8+4}`; layout 2 `{0,0x10000*8,0x10000*8+4}`. Both use X offsets `{67,66,65,64,3,2,1,0}`, Y `0,8,...,56` and 128-bit character stride. Plane order and bit numbering must follow MAME's decoder, not native CPU endianness. Stingray has its own three plane layouts and four entries; use the pinned structures directly for the decoder reference.

Build a row decoder and a scanline pipeline, using small double line buffers. Determine sprite-RAM sampling from gameplay writes before deciding whether a vblank snapshot is valid. The MAME frame renderer is a graphics oracle, not evidence of physical frame-buffer RAM. At 48 MHz there are 3072 system cycles per 384-pixel line, minus controller/blanking overhead. Measure the worst active line after row prefetch; use demand/deadline counters before adding caches or raising clocks.

## ROM and memory placement

Audited logical region footprints: **Kyros 603,392 bytes** per set, **Stingray 592,128 bytes**. Both are well below a 32 MiB SDRAM module. Region allocation includes unused/fill addresses. File-level CRC/SHA1 and exact load/continuation addresses are in `research/rom_manifest.json`.

Start with main program (128 KiB) and sound image (64 KiB allocation) in M10K ROM/download RAM; work/sprite/sound RAM and small color/CLUT PROMs also use M10K. Place the 384 KiB graphics region in SDRAM. This removes CPU-versus-video SDRAM arbitration during play. Confirm final inferred widths/packing with the first fit. If the framework plus CPU/PROM allocation approaches the user's memory ceiling, move program ROM to SDRAM and add only the required registered request adapter; do not allocate all ROMs in BRAM by default.

Keep one downloadable address contract: profile header plus aligned main, audio, graphics and PROM ranges, each recorded in a generated `rom_layout.json`. MCU firmware remains a separate named range with verified variant identity. The clean raw Kyros bootleg MCU dump and the partial original dump are separate staged files because MAME's `mcu` region overlaps them. Padding/fill is deterministic and tagged with the MAME version. MRA and simulation consume the same constructed images.

Runtime DDR3 use is initially only the MiSTer framework's scaler/rotation. Normal ioctl download is enough to establish the sub-megabyte image; add DDR burst staging only if a measured load-time benefit justifies it. Restore a standard fast-loading path without adding a speculative general-purpose memory fabric.

## Physical inventory limits

Kyros PCB notes enumerate 68000, Alpha 8511, two INPUT84 modules, 2016/5814 SRAMs, program/graphics/PROM chips, 24 MHz crystal; sound board 60MC01 enumerates Z80, YM2203, two AYs, YM3014, two 2114s, 40174/4013, LM324s, UPC1181, pots and 16 MHz crystal. Empty DIP28 socket is not an emulated device. A complete per-reference-designator TTL BOM or Stingray schematic was not found in the reviewed primary sources. `donormap.md` covers the identified functions and labels custom/analog gaps; it does not invent chip labels or claim decap-level completeness.

### N graphics row bandwidth clarification (2026-10-09)

Every Kyros and Stingray GFXDECODE entry needs **two** physical row words under
the bit-0/bit-3 byte-address permutation. In Stingray layout 1, the second plane
is `0x10000*4` bits = `0x8000` bytes; the third plane is at the same byte offset
plus four bits. Layouts 2/3 likewise place planes 1/2 in the two nibbles of one
byte. Treating `0x10000*4` as a byte address would overestimate read traffic.
The renderer overlaps drawing with the next strip's metadata/SDRAM fetches.

MAME's N flip changes strip Y traversal and each tile's pixel flips; it does not
replace strip X with `248-X`. Kyros color `0xff` is reduced modulo 32; pen zero
and the full-word sentinel `0x20` are separate transparent conditions.
