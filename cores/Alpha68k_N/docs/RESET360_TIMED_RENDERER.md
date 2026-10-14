# Field360 accepted-write renderer replay

Parent2d326a5. The actual reset421 CPU run remains the native source. Replay
starts at its completed330 snapshot and runs exactly30 complete raster fields
through360, using10,453 accepted sprite writes, actual byte lanes and recorded
48MHz master ticks. Applying all those writes reconstructs the native360
sprite RAM byte-for-byte. The recorded warm-reset release tick predicts
every write's logged raster coordinate exactly; there is no fitted frame,
pixel or phase offset. Preparation hashes cover the actual events, reset marker,
RAM snapshots, raster/background state and generated write timeline.

The real renderer, palette/PROM and JTFrame SDRAM path produce all57,344 pixels
of native360 exactly. Final run exit0,7,920 completed scanlines (264*30),
worst line2,280 ticks,0 deadline misses/overflows. Evidence:
research/kyros_reset360_timed_renderer_verification.json, preparation JSON,
v2 job/worker/build/exit/input manifests, and ignored diagnostic captures.
The actual output still differs2,104 pixels from canonical atomic MAME360.
That failed comparison is retained; correct final RAM alone does not predict
native raster output while CPU writes are ongoing.

This is a causal graphics diagnostic, not another actual CPU bring-up run or
a complete MAME/physical timing pass. It uses target-field final background64
rather than replayed background history, flip0, and the isolated SDRAM fixture's
normal refresh cadence. Original controller state/refresh phase is not restored.
Source game RTL, CPU/clock enables, ROM and pinned framework remain unchanged.
The earlier actual reset421 CPU terminal evidence is unchanged.

The first run produced the same exact native image, but exited1 because its
inherited static-fixture check expected225 scanlines/field. The timed loop
runs264, so the corrected check requires7,920. First result, source copy,
manifest and exit are preserved; no pixel/timing/DUT changes were made for
the passing second run. The output's initial_static_pixel_mismatches and
first_x/first_y refer to the separate initial330-RAM static helper image;
they are not failures against native360, whose oracle_mismatches is0.

Tools: scripts/prepare_reset360_renderer.py prepares guarded actual events;
scripts/run_reset360_renderer.py launches the frozen WSL build/run and refuses
to overwrite a job; --attempt2 preserves the first run. The dedicated
sim/build_renderer_timed.sh and render_timed_main.cpp leave the original
static fixture intact and use the established D-drive WSL build runtime.

Next: replay fresh MAME raster events with their recorded horizontal positions
to assess the remaining actual CPU/write-phase discrepancy, and connect this
case with backdrop60 and combat sprite differences. Keep the atomic image
failures until an explicit time-aware oracle and source/board accuracy evidence
qualify them; do not force CPU clocks or defer writes to match atomic pictures.
