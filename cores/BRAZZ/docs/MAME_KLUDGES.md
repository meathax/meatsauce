# MAME behavior retained or requiring a decision

Pinned baseline: MAME 0.289, matching staged source files.

- `init_crysking`: eight protection halfword substitutions; exact offsets/values in `HARDWARE_NOTES.md`.
- `patchreset`: compatibility code at `44414f4c` for the test-menu reset-vector issue; distinct from real board RAM and cartridge protection.
- Flash driver implements a small first-word command/ID interface, not the entire Intel flash command set.
- Physical SRAM notes say 32 KiB while software map exposes 64 KiB; preserve source map until better evidence establishes mirroring.
- CPU interpreter cycle accounting is abstract; actual core throughput must be measured.
- SoC source carries dynamic PLL/VCLK TODOs; video carries dither/async flip/front drawing/display-start TODOs and a palette transparency collision workaround.
- Sound divider/source and parts of effects are uncertain in the reference. Start from the pinned functional model; hardware sound/timing judgment is in the final phase.

Add actual implementation decisions and evidence as work lands. No claim of original-PCB cycle accuracy is made by preparation.

## Upstream MAME issues audit (2026-10-06, vs MAME master)

Method: diffed the pinned 0.289 files against current MAME master (`raw.githubusercontent.com/mamedev/mame/master`, staged under `docs/reference/mame_master/`), read the in-source TODO/NOTE lists, the VRender0 SoC PR [mamedev/mame#14116](https://github.com/mamedev/mame/pull/14116) and the Arcade Database entry for crysking. No mametesters.org bug is filed against crysking; MAME marks it working (master now flags `MACHINE_UNEMULATED_PROTECTION` because the PIC is undumped).

Fixed in this core (master behavior, RTL + tests updated):
1. **Video flip with a zero flip count** (master `execute_flipping`, evidence trivrus/MT08891, crospuzl, topbladv): vblank now does nothing while `flip_count==0` (fence stays held, draw/display targets unchanged). `vr0_gpu.sv`; `sim/video/gpu.cpp` covers it.
2. **CRTC status register** (master `crtc_r`): bits 13/14/15 per master (blank only inside the display area, new HSYNC-status bit 15, upper bits masked). `vr0_crtc.sv`; oracle now extracted from master bodies.
3. **Light-pen registers** (0x038..0x044 read 0, writes ignored; LIGHTC 0x048 stays a 2-bit register). `vr0_crtc.sv`.
4. **DMA terminal count** is 24 bits (`DMATCx`). `vr0_dma.sv`.
5. **PIO bit 29** reads the PIC data line pull-up (inverse of the CPU-driven bit 29, default 1). `vr0_gpio.sv`.
6. **Sound end-of-sample IRQ** is raised only when the pending bit newly sets (`old_pend != m_int_pend`); no duplicate IRQ events. `vr0_spu.sv`.

Reviewed and deliberately unchanged:
- SE3208 charges 3 cycles/instruction in master (`m_icount -= 3`): MAME's abstract timing; this core's CPU timing is its real bus timing. Game speed must be judged from measured frames, not this constant.
- DMA stepping in master is timed per element (4 clocks) with live src/dst/count updates: MAME TODO ("sketchy details"); the core already uses real bus transfers. Live register update not adopted (no hardware evidence).
- Still-open MAME TODOs, no verified hardware behavior to implement: raster dither, true asynchronous flip/load, front-buffer drawing, dynamic PLL/VCLK select, sound envelope/interrupt verification, reverb, ping-pong/reversed loop, sample-rate divider, CRTC border/TCOL overlay colour, "proper PIO emulation", PIC protection (still patched by the eight exact halfwords).
- crysking coin-2 insertion "fuzzy" (BTANB note) and officeye/urachamu P2 start issues do not apply to crysking P1/P2 play.

## crysking usage of MAME video limitations (2026-10-06, measured in MAME 0.289)

Tool: `scripts/mame_video_usage.py` / `.lua` (9000 frames, seeded input). Details and table in `VRENDER0_GPU.md`.
- Dither: game writes render_control `0x06` once = field 2 = "1x: disable" per the MAME header comment (00 2x2, 01 4x4). Truncating conversion is correct; nothing to implement.
- Async flip / draw_select / front drawing: never used (8752 sync flips, 0 async; only 3 quads drew into the displayed buffer, both banks at reset value before the first flip).
- Display start / blank / CRTC: all 36 CRTC writes happen at frame 31; blank bit never set; STAD1 `0x4001` never changed after init.
- Palette collision workaround: used heavily (40% of 224,404 palette loads, one entry each: opaque `0x010101` colour vs transparent `0x000000`, `0x00fe02fe` vs magenta key). Kept as in MAME; true hardware compare point is undocumented (datasheet not found).
- Pipeline rate (1100 objects/s timer) is a MAME abstraction; measured load max 262 packets/106 quads/437,831 px-area per frame.

### Palette collision hack: not used by the shipped core (2026-10-06)
`vr0_gpu` defaults to `MAME_PALETTE_HACK=0` (plain RGB565 palette + per-entry opaque flag, no 0xecda sentinel); `=1` is MAME-exact and used by the MAME-oracle benches (`sim.py gpu`, `gpu_game`). Evidence, rationale and revert in `HACKS.md`; directed tests in `sim.py gpu_hw`.

## Sound audit addendum (2026-10-06)

- "Sound: Imperfect" and the reviewer's "no sound in the intro": measured with `scripts/mame_sound_usage.lua`. The silence is the game's own **Demo Sound = WITHOUT** factory default on blank NVRAM (crysking ships no NVRAM dump in MAME; urachamu's ROM comment says the same default is "no demo sound"). With Demo Sound = WITH the attract/story music plays from frame 640. Not an emulation gap. Details and tables: `docs/VRENDER0_AUDIO.md`, `docs/mame_sound_usage.json`.
- The game never programs LOOP/SUSTAIN/ENVELOPE/PINGPONG, reverb regs, CTRL bits other than RS, or channel interrupts in 53,000+ recorded frames (stage 1, attract), so MAME's unimplemented sound features do not affect the exercised game paths. RTL keeps its unsupported-mode traps. No datasheet exists publicly for the VRender0 sound engine ([MAME source](https://github.com/mamedev/mame/blob/mame0289/src/devices/sound/vrender0.cpp) is the only reference).
- MAME `status_r`/`noteon_r`/`intmask_r`/`intpend_r` return the high half as `>> 4` while the register comments say channels 16-31; unresolved, see VRENDER0_AUDIO.md.

## Per-item audit of reported crysking MAME inaccuracies (2026-10-06, vs MAME master `vrender0.cpp` / `crystal.cpp`)

Master sound source re-fetched and compared with `rtl/audio/*`. Rule applied: evidence rank PCB/chip docs > MAME; no public VRender0 datasheet exists, so behavior MAME itself marks unverified is not invented. No RTL change resulted.

| # | Reported item | Core status | Action |
|---|---|---|---|
| 1 | Reverb missing | `unsupported_reverb` trap on CTRL.RE; BufferSAddr/BufferSize/RevFactor regs stored. Game writes only boot zeros (docs/mame_sound_usage.json). | No hardware semantics exist to implement; trap kept. |
| 2/3 | Ping-pong / reverse loop | Master documents only the LD bit (reg 06 bit 12; polarity and ping-pong interaction undocumented). Core stores/reads LD exactly like master (reset 1); voice flags mode bits 1/3 as unsupported. Game: 0 uses in 53k frames. | Direction rules would be guesses; not implemented. |
| 4 | Envelope unverified | Bit-exact copy of master arithmetic (rate*div>>16, target compare, stage shift). Game: envelope never enabled. | Matches reference; no hardware data. |
| 5 | Interrupt incomplete | Core already has master's `old_pend != int_pend` edge rule and `int_mask != all-ones` gate. Game never enables channel IRQs. | Done earlier (item 6 above). |
| 6 | Sample rate unverified | 1944 system clocks/sample (= sound clock/972). | Kept; no alternative evidence. |
| 7 | Channel divider `(30<<16\|0x8000)/(clknum+1)` | Identical; game uses clknum 29 only. | Kept. |
| 8 | Missing global regs (CW/AW/MW waits, RE) | Writable/readable, no behavior; game never sets them. | Nothing to implement. |
| 9/10 | PIC protection patched, no timing | Eight-halfword overlay + PIO bit29 pull-up (master). PIC undumped (master marks `MACHINE_UNEMULATED_PROTECTION`). | Cannot emulate unknown firmware. |
| 11 | PLL fixed | Fixed clocks, no PLL model. | No evidence; kept. |
| 12 | Reset patch RAM at 44414f4c | Kept as MAME-compat kludge, separate from protection. | Kept. |
| 13 | BGFX white-as-black | Frontend alpha bug, not core behavior. Core palette uses `MAME_PALETTE_HACK=0` (plain RGB565 + opaque flag). | N/A. |

Open deviation (deliberate): high-bank status/noteon/mask/pending reads use `>>16` (register comments) while MAME shifts by 4; see VRENDER0_AUDIO.md.
