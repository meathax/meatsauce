# N strip renderer — primitive verification

`rtl/alpha68kn_renderer.sv` implements the pinned N-family strip list, not the
later Alpha68k II/V sprite engine. It reads positions and tile words through
synchronous ports, selects the row intersecting the next scanline, then fetches
two physical SDRAM words per tile row. Drawing overlaps the next tile fetch.
Two 256-entry line buffers share one clear/draw write port and an independent
display read port; entry 0x100 selects the background indirect color.

`rtl/alpha68kn_video_rom.sv` packs all source PROM bytes into transport words
for block RAM. It provides the color lookup, indirect CLUT, and the N palette's
low-nibble times-17 RGB conversion. Pixel zero, the full tile-word sentinel and
Kyros color 0xff are independent conditions. Native flip follows MAME's strip
Y traversal and tile flips; it does not invent a whole-strip X mirror.

## Evidence and exact scope

`research/renderer_fixtures.json` pins all RTL, the external SDRAM model,
C++ reference, executable, ROM payloads, captured RAM and original MAME source.
`sim/render_fixture.sv` contains the actual renderer, palette ROM and pinned
SDRAM controller. Its C++ model substitutes only the external SDR SDRAM chip.
The independent reference directly transcribes MAME's full strip loops,
GFXDECODE layouts and MSB-first bit reader.

| Fixture | Native RGB differences | Displayed MAME PNG differences | Worst clocks/line |
|---|---:|---:|---:|
| Kyros recorded gameplay RAM | 0 | 0 | 1732 |
| Kyros Japan recorded gameplay RAM | 0 | 0 | 1732 |
| Stingray recorded gameplay RAM | 0 | 0 | 1424 |
| Kyros flip formula | 0 | Not compared | 1732 |
| Kyros all-bank/boundary/color-ff | 0 | Not compared | 2281 |
| Stingray flip formula | 0 | Not compared | 1424 |
| Stingray all-bank/boundary/wrap | 0 | Not compared | 2089 |

Every case compares 57344 pixels and completes 225 line jobs with zero
deadline misses or row FIFO overflows. The dense fixtures draw all 96 strips
per line, cover every graphics bank and boundary tile code, and exercise
Kyros color 0xff and Stingray negative-edge wrapping. All finish within the
3072-clock line budget. Flip/boundary fixtures compare against the independent
MAME-formula reference; they do not claim actual cocktail or late-stage play.

**These are isolated graphics fixtures with captured or deliberately named
boundary RAM. They do not satisfy real RTL CPU attract/gameplay acceptance.**
The renderer is not yet instantiated in the active board/QIP. Full live CPU
integration, dynamic write timing, stage 5/ending and hardware output remain
required. The standalone tests do not replace any P4/P7/P8/P9 gate.

## Reference observation correction

The initial Stingray recorded fixture differed at 746 pixels against Lua
`screen:pixels()`, while the renderer matched the RAM-based reference exactly.
MAME 0.289 swaps the displayed and drawing buffers before the observer.
The saved screen PNG, normalized by inverse pinned ROT90, matches exactly.
All 66 original PNGs now have canonical `.display.rgb` sidecars; 28 differ
from the preserved original drawing-buffer `.rgb` files.

See `docs/REFERENCE_ORACLE.md`, `research/oracle_display_manifest.json` and
`research/renderer_sting_snapshot_diagnosis.json`. Rejected evidence remains
in `research/renderer_fixtures.failed_backbuffer.json` and the ignored
`sim/build/alpha68kn_renderer_backbuffer_sim`. This corroborates the existing
shared lesson “2026-10-05 — MAME frame_done pixels can belong to the draw bitmap”.

## Reproduction and next integration

Run through explicit Ubuntu WSL from this workspace:

- `bash sim/build_renderer.sh`
- `python -X utf8 scripts/normalize_oracle_display.py` on the Windows host
- `python -X utf8 scripts/run_renderer_fixtures.py` on the Windows host

The current active board's main ROM also has a focused synchronous read
correction following Quartus's actual uninferred-RAM report. Read data carries
a registered address tag; DTACK waits until it matches the requesting CPU
address. The owned 90-frame CPU regression and new non-assembly map/fit/STA
are pending in `sim/build/cpu_bram_90_job.json` and
`sim/build/quartus_initial4_job.json`. Before modifying active board/QIP
sources, inspect those owned jobs and preserve their source-bound results.

The 90-frame CPU ROM-pipeline regression subsequently passed, with identical
final work/strip RAM and counters versus the pre-change CPU baseline. Its exact
comparison is in `research/cpu_bram_regression.json`; only the Quartus job is
still pending. This does not expand the fixture's graphics acceptance scope.

### Real CPU boot integration checkpoint

The shared alpha68kn_system top now connects the real CPU board and live strip
RAM to these primitives and the actual SDRAM controller. The external SDRAM
model supplies chip pins only. A 90-frame Kyros boot completed without missing
or duplicated pixels, renderer deadline misses, overflows or unmapped CPU
accesses. Native frames 30 and 90 matched the corresponding canonical MAME
display RGB files exactly. See research/system90_report.json and progress.md.
This advances live integration but does not close attract/gameplay, audio,
Super Stingray or hardware gates. Reproduce with bash sim/build_system.sh in
Ubuntu, then run alpha68kn_system_sim from sim/build with the staged download,
frame count and output directory. The analyze_system_capture.py tool validates
the owned exit receipt, full frame coverage, RAM artifacts and source manifest;
same-label MAME comparisons remain diagnostic until later phase alignment is
established. The active hardware wrapper still awaits this shared top.
