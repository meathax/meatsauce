# Zero Team USA board facts

Prepared 2026-10-04. Primary evidence is the staged local MAME 0.289 source,
not a similarly named Zero Team variant. Exact file SHA-256 hashes and the
full binary identity are in `reference/mame/manifest.json`.

## Target and reference limitations

- Set: `zeroteam`, **Zero Team USA (US)**, Seibu Kaihatsu (Fabtek license),
  1993, horizontal orientation (`ROT0`).
- Driver: `reference/mame/raiden2.cpp`; US ROM definition at line 2719;
  PCB notes at lines 2628–2714; machine declaration at line 3282.
- CPU map: `zeroteam_mem`, line 662. Sound map: `zeroteam_sound_map`, line
  745. Machine: `zeroteam_base`, line 1163. Initialization: `init_zeroteam`,
  line 3194. Game-derived blending table is in the same driver.
- `MACHINE_NOT_WORKING` and the leading sprite-sort TODO are present in
  MAME 0.289. The XML reports preliminary emulation. Use MAME as the first
  register/ROM reference, and distinguish its known shortcomings from
  verified hardware behavior when addressing protection and priorities.
- `nzeroteam` / `zerotm2k` belong to the V33/updated board family. They are
  references only and cannot replace the US V30 target.

## Clocks and display

| Function | Board/MAME value | Implementation plan |
| --- | --- | --- |
| Main CPU | NEC V30, 32 MHz / 2 = 16 MHz | Integrated donor V30 `ucore`; retain its CE/bus contract |
| Sound CPU | Z8400A / Z80, 28.636363 MHz / 8 | T80; average CE = 3.579545375 MHz |
| FM | YM3812 OPL2, same sound clock | JTOPL2, not the Raiden II YM2151 |
| ADPCM | One MSM6295, 28.636363 MHz / 28, pin 7 high | JT6295; approximately 1.02272725 MHz input clock |
| Pixel | 32 MHz / 4 = 8 MHz | Fixed integer divider; no fractional pixel CE |
| Raster | 512 total pixels × 282 lines | 320 × 256 visible, horizontal |
| Refresh | 8,000,000 / (512 × 282) = 55.407801 Hz | Match MAME timing first; PCB notes report slightly different measured refresh |
| Display aspect | CRT presentation | 4:3; raw pixel aspect is not display aspect |

Keep the primary donor's 96 MHz core/pixel architecture initially: 12
core clocks per pixel, 6144 per line, V30 CE nominally every six clocks.
Read actual PLL outputs and CPU enables before wiring; CPU microsteps are
not additional emulated CPUs. This higher-than-48 MHz choice preserves the
selected donor's implemented mixer and CPU path rather than redesigning it.

## Physical PCB coverage

| Part | Function / evidence | FPGA treatment |
| --- | --- | --- |
| SEI1000 SB01-001 | Main protection / COP | Donor COP command interpreter, math, collisions, DMA and sorting; adapt from US command uploads |
| COPX-D2 ROM | 256 KiB protection/math data | Staged exact ROM; use where hardware-derived COP behavior requires it |
| SIE150 | Z80 interface | Main/sound latches, pending flags, banking, IM0 vectors and coin handling |
| SEI251 SB03-012 | Sprites and decryption, battery backed | SEI252-family scanline renderer adapted for Zero Team layout and cipher |
| SEI0200 TC110G21AF | Tile/background graphics and CRTC family | Four-layer donor engines and CRTC with Zero Team banks and DMA destinations |
| Approx. 15 × 74xx logic | Mixer/glue replacing Raiden II's SEI360 | Priority, blend, palette and bus RTL; SEI360 is a behavioral donor, not a chip on this PCB |
| Four PALs | V3C001, V3C002, V3C003, V3C004X; two stacked | All `NO_DUMP`; derive observable decode, enable and handshake behavior |
| LH52258 | Four 32 KiB × 8 SRAMs in PCB notes | CPU-visible RAM plus private video/DMA storage as required by the address map |
| CXK5863 | 8 KiB × 8 SRAMs | BRAM/SDRAM functional memory equivalents |
| LH5116 / 6116 | 2 KiB × 8 SRAMs | Sound/private memory equivalents; preserve access latency |
| Program / character / tile / sprite / voice EPROMs and mask ROMs | Driver's exact socket and lane ordering | Local region images and future MRA/loader mapping |
| YM3014 | Mono DAC for OPL2 | JTOPL sample output into signed MiSTer PCM; no need to recreate the serial DAC electrically |
| HB-45A / LA4460 / volume / passives | Audio DAC/output and amplification | Digital gain, mix and supported filter; original analog power stage is outside FPGA |
| HB-2 | Coin counter module | Coin edges/lockout/counter behavior when observable; physical coil driver is outside FPGA |
| RC220 | Input resistor networks | Active-low inputs, DIP bits and sensible debounce/pulses |
| 3.6 V battery | SEI251 key retention | Correct persistent default key state/reset behavior; no physical battery dependency |
| Oscillators / reset / JAMMA / DIP arrays | Board timing and controls | PLL + CEs, synchronized reset, four-player inputs and MRA DIP settings |

Three physical DIP banks are shown in the PCB notes; MAME's target input
definition is the observed baseline. Record any unmodeled third-bank
function rather than inventing a DIP. Board electrical components do not
each need a standalone CPU-like donor; their observable functions belong
in the matching bus, input, clock, mixer or audio block.

## ROM and RAM facts

There are 13 dumped ROM files; all are verified by CRC32, size and SHA-1.
Four PAL entries are undumped. `reference/rom_layout.json` records actual
assembly including `ROM_CONTINUE`, `ROM_COPY`, hole fill and lane order.

- Program: four 256 KiB files, `ROM_LOAD32_BYTE`, byte lanes 0/2/1/3 in
  source order. CPU bus remains 16-bit; do not confuse the file packing
  with a 32-bit main CPU.
- Sound: one 64 KiB file split between 0x00000 and 0x10000, then its first
  32 KiB copied to 0x18000, in a 128 KiB region erased to 0xff.
- Chars: two 64 KiB files interleaved into 128 KiB.
- Tiles: 1 MiB + 512 KiB physically populated in a 4 MiB region.
- Sprites: two 2 MiB files interleaved as 32-bit words into the first
  4 MiB of an 8 MiB 0xff-erased region. Only those first 4 MiB are decrypted
  by MAME's `init_zeroteam`; decryption lives in `r2crypt.cpp`.
- Voice: 256 KiB populated in a 1 MiB region. Address mirrors/banks must
  follow the sound map, not the larger Raiden II sample-ROM assumptions.

CPU work RAM is 0x00000–0x003ff and 0x00800–0x1ffff, interrupted by mapped
registers. Tile/palette/sprite source areas are 0xb800, 0xc000, 0xc800,
0xd000, 0xe000 and 0xf000. COP DMA populates private video storage; direct
CPU writes to those source areas must not automatically mutate a tile
renderer without the corresponding DMA. Program banking is 0x20000–0x3ffff;
0x40000–0xfffff is fixed ROM. Reset selects bank entry 1.

Default resource target: DE10-Nano, 32 MiB SDRAM plus built-in DDR3. All
logical ROM regions fit within 32 MiB. Retain the primary donor's SDRAM
CPU/tile path and DDR sprite/sample paths initially to minimize rewiring.
Runtime DDR use is justified by preserving the selected integrated donor;
switching everything to SDRAM is an optional measured optimization, not a
precondition for gameplay. Budget line-renderer latency against shared
memory contention, not ideal zero-latency reads.
