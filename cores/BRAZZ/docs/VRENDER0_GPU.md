# VRender0 GPU implementation and acceptance boundary

The renderer is genuine synthesizable RTL in `rtl/video/vr0_gpu.sv`; texture and framebuffer accesses use the delayed board bus. It fetches each 64-byte packet from texture RAM and executes it in hardware. MAME supplies an independent test oracle, never the board renderer.

## Implemented behavior

- An 11-bit wrapping front/rear queue, start/reset controls, readable display bank, selectable 1 MiB/4 MiB second framebuffer base, 8-bit queued flip count, sync fence and asynchronous draw-bank selection.
- Persistent blend colors/modes, shade/transparency colors, texture/palette offsets, palette bank, format, dimensions and tiled mode. Packet flags update these fields. Texture origins and affine increments reset to the MAME defaults when their update flags are absent.
- Inclusive rectangle bounds, 32-bit affine accumulators with nine fractional bits, independent X/Y increments, texture wrapping or clamping, 8×8 tile addressing and empty-tile skip.
- 4-bit indexed pixels with the even texel in the high nibble, 8-bit indexed pixels, and both 16-bit format selectors. RGB888 palette entries convert to RGB565 with the reference's transparency-collision adjustment.
- A 256-entry palette cache, reload on changed palette base and invalidation at flip commands. Transparent pixels skip stores. Shade modulation, source/destination blend factor selection, inversion and saturation follow MAME's channel arithmetic.
- Byte/halfword register lanes, open-bus reads and ignored writes for the reference's unmapped video aperture, changed-pixel writes, visible memory-fault stop and variable-latency responses.

Mapped halfwords: front `0x80`, rear `0x82` (read-only), control `0x8c`, display bank `0x8e` (read-only), bank1 select `0x90`, and flip count `0xa6`. A 32-bit read can span two halfwords, with all ones returned for an unmapped half. Control reset writes wait until the current packet finishes; this serializes the reference's atomic packet execution. MMIO updates follow engine/vblank updates on the same clock.

## Evidence

`python -X utf8 scripts/sim.py gpu` passes 640 complete framebuffer comparisons against five unchanged drawing bodies extracted from the pinned BSD MAME video source. The matrix independently exercises format, tiled mode, alpha, shade, transparency and clamp, with common identity draws, affine/wrapped coordinates, partial state updates and reversed bounds. Queue wrap, MMIO lanes, sync/async flips, reset priority over a job starting on the same clock and a delayed bus fault also pass: 55,778 requests / 6,580 stores / 443,460 system clocks. See `docs/gpu_reference.json` and `docs/simulation_gpu.json`.

The CPU/DMA/GPU integration uses three memory clients and the production-default CPU. With the PCB inputs connected, the real BIOS reaches 1,594,793 differential retirements before the pending GPIO/RTC register `0x01802004`. See `docs/simulation_boot_probe.json`. This result establishes the next dependency; it does not establish an RTL game frame.

## Remaining work

1. Replay captured real game packets and memory fixtures; compare actual integrated framebuffer output and scanout against the MAME route.
2. Implement programmable CRTC, scanout and its interrupts. The boot probe currently supplies a diagnostic vblank pulse using the documented 455×262 raster and divide-by-12 pixel cadence.
3. Measure actual game queue completion and memory bandwidth. This initial scalar renderer makes separate accesses for each pixel; sustained real-time rendering is not established. Add burst/cache/pipeline optimizations where the measured game deadline requires them.
4. Resolve physical behavior not covered by MAME: dither modes are stored/read back but not rendered, front-buffer drawing and asynchronous flipping inherit the reference's stated uncertainty. The reference also documents its palette/shadow approximation. No physical cycle-accuracy or Quartus timing claim is made.
5. Complete integrated cold boot, attract mode, sound and normal P1/P2 gameplay before wrapper completion, the simulation gate and the final hardware phase.

### 2026-10-05 — First coherent native game draw replay

Added `scripts/sim.py gpu_game` and `scripts/gpu_game_fixture.py`. The staging step verifies hashes/sizes of the original native first-active submission metadata, 8MiB texture RAM, 8MiB framebuffer RAM and packet trace, and checks that the first active CSV packet at frame154/index0 is exactly the packet stored in captured RAM (flags1110, queue0→1). Raw memories and packet data remain private/ignored. The real `vr0_gpu` executes the captured queue submission through the existing delayed board-bus bench; a separately instantiated MAME renderer uses five unchanged original drawing bodies with optional test-only pixel-store recording. No production renderer changes or substituted software renderer.

`python -X utf8 scripts/sim.py gpu_game` **PASS**: 1 genuine game packet completed, all 481 physical halfword pixel stores match MAME in exact address/data/order, the full 8MiB framebuffer matches, and packet/texture RAM remains intact. 77,858 bus requests, 726,095 clocks with 0–6-cycle delayed replies and randomized request-ready stalls. Both resulting framebuffers are identical and saved privately; result/hash/provenance are in `docs/gpu_game_replay_results.json`. Exact store checking matters because a framebuffer comparison alone could miss writes of values already present in RAM.

Limits: only this first submission has an available coherent RAM snapshot; subsequent packet data is not replayed against stale assets. Earlier active render packets were absent from the capture, so this first submission uses reset renderer state. This does not prove scanout/presentation, original-game CPU boot, attract/gameplay or worst-game shared-memory deadlines. The next rendering step needs coherent subsequent texture/frame CPU/DMA writes and queue/flip state, followed by real scanout and contention. Original game cold boot remains at 020820c4/fc65, and no bypass was added. No RBF build/hardware run.

### 2026-10-05 — RGB565 bus scanout and five-client board

Added genuine synthesizable `vr0_scanout`: two synchronous 32-bit line buffers (4KiB total), full-word board-bus reads, primary MAME framebuffer addressing (1024-pixel stride, y&511, x&1023, GPU-selected base and 8MiB wrap), RGB565 expansion, and pixel/sync/DE/blank outputs delayed together by one clock. Raster timing never waits for RAM. Initial prefetch displays black until a complete first-line/frame boundary; explicit CRTC mode changes invalidate/rearm, with late old replies discarded. RAM errors, unsupported geometry and missed steady-state deadlines are exposed. MAME's ignored CRT Display Start registers remain unresolved rather than silently claimed.

Integrated scanout as memory client4 behind CPU/DMA/GPU/SPU clients0/1/2/3. Board request owner is now 3 bits for five clients; board outputs expose the real pixel stream and video fault counters. Added an explicit CRTC timing-change signal without changing its timing interpretation. Added the new module to files.qip; actual MiSTer frontend pixel wiring still remains.

Changed-path PASS: `scripts/sim.py scanout` compares 1,468,644 presented pixels against the unchanged MAME screen_update body (six original renderer/scanout bodies now retained by the oracle generator), including 1x3, odd-width319x17, 320x240, 1024x515, framebuffer wrap, vblank bank1MiB→4MiB, and the prior real RTL game-draw framebuffer. It checks pixel/sync/DE latency, a delayed old reply across mode restart, RAM fault/reset/geometry, and deliberate bandwidth starvation reporting underrun with an unstretched raster. 1,134,546 reads / 36,188,384 clocks. `scripts/sim.py arbiter5` passes 320 contended transactions, 64/client. `scripts/sim.py bios_sound` passes 2,854 independent CPU comparisons, 26 sound MMIO, 8 SPU reads, 1,712 scanout reads/words, all 24 sound outputs and two IRQ2 entries/returns; no audio or video deadline/error.

Original-ROM `scripts/sim.py boot_probe` still exits **1** at 020820c4/fc65 after exactly 8,233,974 matched instructions, now 162,099,793 clocks with live scanout. CPU registers match the prior fault state; 83,384 silent audio samples and no video fault/underrun. This is preserved partial boot, not attract/gameplay. The latest small diagnostic has not reached an armed full video frame, so its traffic proof is separate from the complete scanout component pixel proof.

Remaining: original SE3208 control-instruction semantics, coherent later game render replay, a real SDRAM/DDR backend with refresh/turnaround and worst captured mixed-client deadlines, and the frontend's real pixel connection. No RBF build or hardware execution. Main evidence: docs/scanout_results.json and the three passing simulation result files; the original boot result remains failing.

### 2026-10-06 — Which MAME video limitations does crysking actually use?

Instrumented real MAME 0.289 (`scripts/mame_video_usage.py` + `scripts/mame_video_usage.lua`, headless, 9000 frames: attract x2, coin, start, warrior select, story, P1 then P2 fights with a seeded input script). Write taps log every video-block/CRTC write; each submitted 64-byte packet is copied and replayed through a Lua mirror of `process_packet` at frame end (no pixels). Private outputs: `sim/obj_dir/mame_video_usage/20261006_124106/` (`events.csv`, `perframe.csv`, `combos.csv`, `summary.json`). Limits: palette RAM is sampled at frame end; bank bookkeeping is frame-granular; pixel counts are rectangle areas (upper bound, no per-texel transparency/clamp).

| Item | Result (9000 frames) |
|---|---|
| render_control (0x8c) writes | exactly 2, both frames 11-12: `0x0008` (reset), `0x0006` (start, **dither field = 2**, draw_select 0). Never rewritten. |
| Dither | field 2. MAME's header defines `00: 2x2, 01: 4x4, 1x: disable` (`vrender0.h`, `m_dither_mode`), so the game runs with dithering **disabled**; MAME's truncating RGB888->565 is the matching behavior. No dither RTL needed. |
| Async flip (packet bit 7) | 0. Sync flips (bit 0): 8752 (one per frame, 8751 display-bank toggles; 94 frames after 200 have none). `draw_select` (bit 7) never set. |
| Flip count | 8753 writes (value 1 each) + one 0; bank1_select = `0x8000` once (frame 11) -> second buffer at 0x400000. |
| Drawing into displayed buffer | only 3 quads, frames 155-156, before the first flip (reset state draw_dest=display_dest=0, both MAME and RTL). Steady state always draws to the back buffer. |
| CRTC (0x01803400-37ff) | 36 writes, all at frame 31 (640 interlace setup then 320x240); none afterwards. CRTMOD (reg 0) written 0 -> blank bit 9 never set. STAD0/STAD1 written only in that init burst (final STAD1 `0x4001`), never during play. |
| Palette collision workaround | 224,404 palette loads; **90,296 (40%) hit it, exactly 1 entry each**: index 255 `0x010101` (66,904), 254 (8,341), 253 (7,335), 194 (7,360) all `0x010101` with trans `0x000000` (565 value 0 == transparent); index 240 `0x00fe02fe` (319) and 2 `0x030302` (37). The game deliberately stores near-black `0x010101` as an opaque colour. |
| Texture formats | fmt1 (8bpp indexed) 99.9%; fmt2 (RGB565) 223 quads (no transparency); fmt0 (4bpp) and fmt3 never. Linear and tiled both used; sizes 8..512; clamp never; ROZ (non-identity increments) used (~88k quads); origin update used by all textured quads. |
| Blend | alpha src/dst modes only `02/21` (31,822) and `02/22` (34,438) (+ alpha with shade 597); shade used on 1,121 textured quads + the full-screen fade fills; fill quads 8,752 (one clear per frame, 77,361 px). |
| Load | 345,140 quads in 9000 frames; gameplay (frame >1200) mean 43.8, p99 76, max 106 quads/frame (frame 2076); rectangle area mean 238,810, p99 344,065, max 437,831 px/frame (frame 2073); packets consumed per frame mean 97, max 262. |

Conclusions: the game uses none of the dither rendering, async flip, draw_select/front drawing, CRTC re-programming or blank bit. Only the palette collision hack is exercised. Physical behavior of that hack is unproven: the datasheet is unobtainable (web.archive.org blocked in this environment; web search found no register-level VRender0 document). The art tool using `0x010101` suggests the hardware transparency compare may be on the 24-bit palette value (then it would be black, MAME shows 565 `0x0001`), but the difference is 1/31 blue LSB on near-black pixels; MAME behavior retained.

RTL audit vs MAME master `process_packet`/`draw_quad`/`draw_quad_fill`/`do_alpha`/`do_shade`/`execute_flipping`/`pipeline_cb`/`screen_update`/`get_fb_addr` (vr0_gpu.sv, vr0_pixel_pkg.sv, vr0_scanout.sv), all verified equal: flip packet bits 0/7 and palette invalidation (gpu:172-176); state update flags and defaults (181-201); palette load condition and collision fix (113-117, 207-215); transparency selection/NOTRANSCOLOR (114,126,232); clamp/wrap, tile index, 4/8/16 bpp addressing and nibble order (97-113, 216-224); shade (do_shade, pkg:11-18); alpha factors/invert/saturation (pkg:19-47) including fill with `src_blend!=0` (gpu:119); unchanged-pixel store skip (252,266); quad.dest latched at dispatch (180); execute_flipping incl. flip_count==0 (155-160); reset/start semantics (164, 280); scanout get_fb_addr/stride/wrap and RGB expansion (scanout:57-59,107-109). No mismatch found; no RTL change. Minor unaddressed edge: MAME `bank1_select_w` takes bit 15 for any lane write, RTL requires a strobe on lanes 0/1 (same for the game's halfword write).

Test: `python -X utf8 scripts/sim.py gpu` now also writes render_control with dither field 0..3 every 64 packets and checks readback; output must stay identical to MAME (exit 0, 640 comparisons, 84,543 checks).

### 2026-10-06 - Hardware-correct palette transparency (`MAME_PALETTE_HACK`)

`vr0_gpu #(.MAME_PALETTE_HACK(0))` is the default (the board instantiates it unchanged). With 0: palette entries store plain RGB565; `palette_opaque[idx]` is set at palette load when RGB565(entry)==RGB565(key) and the 32-bit entry != key (MAME's collision condition); `source_opaque` is registered at TEX_WAIT (0 for 16bpp); a textured pixel is skipped iff `packet[0][3] && packet[0][2] && source==RGB565(key) && !source_opaque`; there is no 0xecda sentinel. With 1 the previous MAME-exact behavior is unchanged. The oracle benches `gpu` and `gpu_game` now build with `-GMAME_PALETTE_HACK=1` (scripts/sim.py), still bit-exact (640 comparisons; 481 exact stores).

New `python -X utf8 scripts/sim.py gpu_hw` (sim/video/gpu_hw.cpp, parameter 0) checks explicit pixels: 0x010101 / 0x01010101 / 0x020202 entries with key 0 render opaque 0x0000 and are stored; a true 24-bit-equal entry stays transparent; with transparency off an 0xecda texel (palette or 16bpp) is drawn and an entry equal to the key is drawn as 0x0000; 16bpp path unchanged otherwise. Each case also counts the pixels where RTL differs from the pinned MAME oracle and requires exactly the predicted set (masks 0x39,0x39,0xa2,0x12,0x00). A real captured crysking palette (frame 1040, key 0xff00ff, from `mame_video_usage.lua`, private) is rendered with all 256 entries: 1 collision entry, 1 true-key entry skipped, exactly 1 pixel differs from MAME.
