# Natural original-ROM boot observations

The host-only BootObserver records execution of the real cs_boot_probe board with production CPU state loading disabled. It does not replace any device, skip instructions, change inputs, load a game checkpoint or restore a snapshot. Raw work/texture/frame RAM, NVRAM, reset RAM and scanout images remain under ignored sim/obj_dir. Public reports contain counts, hashes and diagnostic CPU values.

Every run has a unique directory and ID; activity/latest_run.json selects the newest run. Old terminal files cannot become a new run's terminal snapshot. Use the authoritative simulator tool session/process to determine whether the run is still live; files alone do not prove process completion.

## Recorded evidence

The bounded progress CSV is flushed every 50 million system clocks by default. It reports matched instructions, PC/SR/SP/ER, CP0/cache activity, physical requests by all five memory clients, sound-register and audio activity, GPU work, scanout words/pixels/raster frames, IRQ acknowledgements and architectural CPU-access latency. Interval hot pages and latency histograms accompany metadata snapshots. This separates CPU/cache/transport wait from the total instruction cost.

The first completed drawing packet and terminal return save all natural RAM areas. The RGB PPM contains actual scanout outputs accumulated so far and is explicitly labelled a partial-frame image. It is not proof of a complete frame, attract mode or gameplay. Memory files and images remain private. These snapshots are diagnostic evidence; they cannot be restored as checkpoints.

Terminal reason is explicitly set to clock_limit for the bounded probe or packet_probe for the optional drawing-packet stop. Other diagnostic exits remain diagnostic_return; the actual simulation exit/stderr and chip fault checks establish their cause.

## Commands

Run a bounded original cold boot:

    python -X utf8 scripts/sim.py boot_probe 2000000000 1

The first argument is the maximum system-clock window. The second optionally stops after the requested completed-packet count, only on a packet-count advance with real pixel stores. Exit 0 at that stop is a diagnostic milestone, never the full attract/gameplay acceptance gate. A third optional argument changes the CSV/metadata reporting period for short observer checks. Without arguments, the existing 250-million-clock limit remains.

Inspect bounded live activity after verifying the specific simulator session is live:

    python -X utf8 scripts/boot_activity.py

After authoritative process completion, check snapshots/counters and write the public hash/metric report:

    python -X utf8 scripts/boot_activity.py --require-terminal --write-report

The structural checks verify unique run identity, monotonic counters, client ownership sums, CPU latency classifications/histograms, terminal/CSV agreement and exact private RAM snapshot sizes. They do not verify game correctness. Build manifests now fingerprint board_memory.hpp, the applicable observer or sound-fixture header and the existing RTL/oracle sources, so --run-only rejects changed source inputs.

## Initial result and next use

The observer's 10,000-clock original-ROM check reaches 416 independently matched CPU instructions, 1,090 physical requests (528 CPU and 562 scanout), 539 completed architectural CPU accesses and 4,533 architectural wait clocks. All snapshot/counter structural checks pass; the intentional clock limit returns exit 1. This checks observation plumbing only. Exact results are in boot_observer_verification.json.

The existing native MAME frame trace executes 02085Fxx at frame 50, before first active GPU submission at frame 154. The preceding 500-million-clock RTL probe ended in that routine. Use interval progress and a completed original GPU packet to distinguish slow initialization from a software loop; then optimize the measured CPU/transport bottleneck and resume the full simulation gate. Native capture and raw game memories remain private.

The observer also saves natural RAM immediately before the first GPU memory request. `gpu_bus.csv` records accepted GPU reads/stores; `video_mmio.csv` records actual CPU video-register writes from reset; `concurrent_graphics_writes.csv` records other clients' texture/framebuffer writes after GPU activity begins. Terminal analysis checks record counts and hashes. These streams preserve the real memory context, including CPU uploads while drawing, without injecting any game state.

Run `python -X utf8 scripts/gpu_boot_compare.py` after terminal activity analysis to compare the qualified first original-ROM fill packet. The script replays every captured read/store and concurrent texture write against pre-request RAM, checks both resulting RAM images, then compiles a host-only oracle containing the unchanged pinned MAME drawing functions. It compares the exact ordered pixel stores and full framebuffer. The comparator currently accepts the first queue-zero, untextured `1110` fill into the bank-one 4MiB destination; it explicitly rejects other contexts. It is not a general multi-packet oracle or attract/gameplay gate.

Original run `1791145341609180800` passes: 98,670,053 matched CPU instructions / 1,517,618,206 system clocks, one packet, 482 exact MAME pixel stores, 77,377 verified reads and a matching full 8MiB framebuffer despite 1,900 concurrent texture uploads. The older source-qualified first-draw baseline is preserved in `boot_probe_first_draw_baseline.json` and `boot_activity_first_draw_baseline.json`. The new run uses about 20.34% fewer total clocks; the two runs have slightly different IRQ scheduling/instruction counts, so this is an observed boot milestone comparison, not physical gameplay performance. `gpu_boot_comparison.json` records oracle provenance. Original active audio, attract/gameplay and realistic physical memory timing remain pending.

New observer models additionally collect a separate complete 320x240 scanout frame. A new raster origin closes the previous candidate. Every expected coordinate must arrive exactly once in row order; partial, missing, duplicate, extra and different-geometry candidates are rejected. Only the last complete candidate is published as `scanout_complete.ppm`, with its exact first/last pixel clocks and completion/rejection counts in `complete_scanout` metadata. Periodic, first-request/packet and terminal snapshots save this image when available. The previous accumulated `scanout_partial.ppm` remains explicitly partial. Neither image alone proves sustained attract/gameplay or memory deadlines.

Use `scripts/boot_activity.py --run-id <identity>` when multiple models/checks have run. The analyzer validates complete-image availability, qualified geometry, exact PPM size and clock window, and records its hash. Older models without complete-frame metadata remain supported. Short tests must not be mistaken for a still-running long model merely because they update `latest_run.json`.

Detailed context traces in new models close after the first completed drawing packet. Their counts/hashes must agree with that first-packet snapshot, while the full-run client counters continue. `context_trace_scope` and `context_trace_closed` record this boundary. This retains the coherent packet comparison without writing every transaction during a long attract/gameplay run. Earlier models continue their original full-run traces and are analyzed accordingly.

The analyzer hashes large legacy transaction files as streams. The first-packet comparator checks trace counts against the first-draw snapshot before loading its records; it rejects a legacy whole-run context extending past that snapshot. This prevents a later CPU/GPU memory state from being compared against first-packet RAM, and avoids loading an unrestricted transaction log into memory.
