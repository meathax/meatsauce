# Kyros field 900: four-pixel temporal difference

The canonical 1800-field real CPU/system replay completes successfully, but its field900 differs from MAME's final displayed-frame PNG at four native pixels: (26,8), (27,8), (28,8), (29,15). Raster Y is image Y+16. Keep the original comparison failed; no masks, frame offsets, changed clocks or ROM patches are used.

## Measured cause

The offline MAME loop transcription in `scripts/pixel_provenance.py` assigns all four pixels to group1, strip27, row21, tile-word address **0x40EEA**, position-word address0x406C2, tile21/color3. Its ownership agrees with the canonical displayed pixels. This is an offline diagnostic, not execution evidence.

The unchanged canonical MAME recorder, supplemented by `sim/mame/trace_pixel_word.lua`, produces901 state rows identical to the original recording and identical sprite RAM at900. There are no Lua callback errors. The observed word is20 at the field895–899 boundaries. During field900 it is written20 at beam(275,52), then21 at(313,52). At the field900 completion boundary(0,240), it is21. The tile occupies raster lines24–31, which precede the write at52.

The real isolated RTL renderer matches the official MAME900 image from MAME900 RAM with zero differences. A second isolated fixture changes only word0x40EEA to its measured prior value20. Its actual RTL output matches **all57344 pixels** of the unmodified real CPU/system field900 capture. Thus the four-pixel difference is fully reproduced by the late tile update. This fixture does not alter either real CPU execution or the saved canonical MAME image.

MAME0.289's `alpha68k_n.cpp:202` screen_update draws the three strip groups from current sprite RAM. A final-frame image includes the late value even for pixels earlier in the field. The native renderer prepares and emits lines while CPUs continue to run. This establishes a temporal relationship between the two images; it does not by itself establish an undocumented physical PCB latch or qualify every renderer frame.

## Evidence and remaining gate

- `research/kyros_frame900_difference.json`: original four-pixel failure and image hashes.
- `research/kyros_frame900_pixel_owners.json`: ownership, source/payload hashes.
- `research/kyros_frame900_mame_word_trace.json`:901 state-row equality, original sprite-RAM equality, write/field timing and script hash.
- `research/kyros_frame900_mame_fixture.json`: final-state RTL matches MAME.
- `research/kyros_frame900_prewrite_fixture.json`: one measured pre-write word makes actual RTL match the original live-CPU capture exactly.
- `research/board_state900_detached_started.json`: real-CPU diagnostic completed901 fields, exit0; all per-field main counters match the full-system run. Diagnostic sound-chip readback is0xFF.

The original atomic-image graphics comparison remains failed. Qualify corresponding scanline-time state and native CPU write timing separately; preserve both outcomes in the final acceptance matrix. No broad MAME_EXACT, physical PCB latch, fitted timing/resource or hardware claim is made here.


## Native timing confirmed

`research/kyros_frame900_native_timing.json` records the completed901-field diagnostic. Every per-field main counter matches the full real-system run. All8192 sprite-RAM bytes exactly match MAME at900. The native writes are20 at(273,52), then21 at(311,52); MAME writes20 at(275,52), then21 at(313,52). Both change the tile in field900, after its visible lines24–31. The two-pixel horizontal timing difference is preserved. Together with the complete pre-write fixture agreement, this confirms the timing explanation for the four displayed pixels without changing the live RTL.

Two work-RAM words differ at the final snapshot, and the report retains their values. No broad CPU-state or instruction-timing match is claimed. This diagnostic closes the cause investigation; it does not erase the canonical final-image failure or qualify an undocumented PCB latch. Record the final-RAM, live scanline and atomic-image results separately in P7.
