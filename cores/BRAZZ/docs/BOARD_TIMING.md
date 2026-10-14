# Continuous board implementation checks

The user's 2026-10-05 instruction authorizes Quartus analysis/synthesis and fitting/STA during RTL development. RBF generation still requires an explicit RBF request and the final simulation gate.

## Current result

Timing is **not yet closed**. The latest completed historical fit, GPU/CRTC snapshot 1791167022504670600, uses 21,658 / 41,910 ALMs (52%), 24,570 registers, eight RAM blocks and 31 DSP blocks. All corners are constrained; worst global setup is -13.853 ns and external-input hold is -2.071 ns. Internal setup fails at -7.395 ns (CPU address -> SPU channel target) and -6.677 ns (RTC minute arithmetic); internal hold passes every corner, minimum +0.123 ns. See `board_timing_gpu_crtc_fit.json`.

The working RTL additionally fixes a reproduced mid-quad draw-bank bug, simplifies aligned MMIO addressing, narrows the LOAD/cabinet offset arithmetic and replaces RTC decimal division with equivalent BCD digit carries. GPU passes 640 MAME comparisons plus a 13,002-store, two-vblank bank-switch case matching the entire 8 MiB framebuffer. GPIO/RTC passes 14,099 checks and board BIOS/sound integration retains its acceptance counts. Exact arithmetic identities were checked for all 256 BCD bytes and every narrowed offset address. No earlier timing result covers these source changes.

Registered-boundary snapshot 1791169878930782000 completed synthesis/fit successfully at 50% ALMs, but setup still fails (-5.495 ns) through GPU shading plus blending into WRITE_REQ. Hold passes all four corners, minimum +0.117 ns; zero unconstrained paths. The next RTL registers shading while issuing the destination read. It passes all GPU comparisons with identical clocks/request counts; snapshot 1791171573059175900 has passed synthesis and is running fit/STA. This is an isolated core timing target, not the production wrapper or physical memory interface.

## Efficient workflow

Run with native Windows Python from this project:

```text
python scripts/check_timing.py
python scripts/check_timing.py --registered-interfaces --fit
python scripts/check_timing.py --fit-from sim/obj_dir/timing/<run>
python scripts/check_timing.py --sta-from sim/obj_dir/timing/<run>
python scripts/timing_audit.py sim/obj_dir/timing/<run>
```

Analysis checks changed board RTL. Add fit/STA for changes to register paths, arithmetic, memories, arbitration, clocking or resource use. Resume an unchanged successful synthesis for fit, or an unchanged successful fit for STA, instead of rebuilding. Resumption verifies the working and snapshot RTL source set/content and project/constraint hashes. The audit-only command can inspect a historical successful fit, but validates its exact staged source/configuration hashes.

Each fit/STA now includes four-corner global and register-to-register setup/hold paths and unconstrained-path counts. A timing pass requires nonnegative summary slack and a successful fully constrained path audit. Retain source identities and failure status in `progress.md`, fix the responsible RTL, and run the affected simulation regression. A prior pass does not cover changed RTL.

Snapshots, databases and raw reports stay under ignored `sim/obj_dir/timing/<run>/`. The tools use the shared JTAG exclusion guard, preserve return codes and private error logs, and never invoke `--flow compile`, `quartus_asm` or produce an RBF. Quartus 17 STA does not accept the map/fit settings flags; use `quartus_sta board -c board`. Read-only Tcl audits close with `project_close -dont_export_assignments` so that Quartus does not silently append settings and invalidate source/configuration provenance.

## Scope and final acceptance

The raw-port intermediate top is `cs_boot_probe`, using Cyclone V `5CSEBA6U23I7`, seed 1, and an 11.640 ns system clock. CPU `ce` is an enable. Top-level pins are virtual, with provisional 2 ns maximum / 0 ns minimum synchronous interface delays. This checks actual board-chip RTL, not physical board closure. The current `CrystalSystem.qsf` still selects a diagnostic MiSTer wrapper and does not include the complete board source set.

Use `--registered-interfaces` for intermediate synchronous core closure. The generated `cs_timing_registered` bench launches every core input and captures every output with registers at the same board clock. Only synthetic external pin-to-bench and bench-to-pin segments are excluded; there are no path exceptions through the actual board core. Both core sources and generated boundary/configuration are hash-guarded. This model represents a synchronous producer/consumer contract, and deliberately makes no physical I/O/PLL/backend timing claim. The raw-port model and its failed external hold reports remain available and preserved as historical evidence.

Final closure must use the production wrapper, PLL and physical memory backend: real I/O contracts, all clocks, setup/hold, recovery/removal, unconstrained paths and CDC. Retire intermediate assumptions as those interfaces are integrated. Fitting alone never establishes closure.

## Implementation evidence

| Snapshot | Result |
|---|---|
| 1791157548034952100 | Initial synthesis passed; fit failed: 5,148 LABs needed versus 4,191 available. CP0 data RAM used registers. |
| 1791159232481349700 | Common write-port refactor passed cache/BIOS integration but still inferred registers; fit was stopped. |
| 1791159908707748400 | Quartus 17 rejected an implicit generate loop; replaced with explicit generate syntax. |
| 1791160132929154800 | Wrong M9K family annotation; stopped before acceptance and corrected to Cyclone V M10K. |
| 1791160440929223800 | Four independent 8-bit M10K cache banks inferred (32,768 added memory bits); registers fell from 56,391 to 23,591. Cache/BIOS regressions passed. Fit passed; four-corner STA/audit failed setup and external hold, with no unconstrained paths. |
| 1791165993717831900 | Registered GPU replies: synthesis/fit passed; STA/audit FAIL, retained with exact path and source identities. |
| 1791167022504670600 | GPU plus pipelined CRTC: synthesis/fit PASS; all-corner STA/audit FAIL on MMIO/SPU and RTC paths; affected regressions pass. |
| 1791168471066726200 | Per-packet framebuffer destination: synthesis PASS; superseded by the address/RTC fixes before another fit. |
| 1791169878930782000 | Registered-interface target: synthesis/fit PASS (50% ALMs); setup FAIL on combined GPU shading/blending; all-corner hold PASS. |
| 1791171573059175900 | GPU shading held during destination-read issue: GPU regression and synthesis PASS; fit/STA in progress. |

Primary references: [Cyclone V embedded memory](https://docs.altera.com/r/docs/683375/current/cyclone-v-device-handbook-volume-1-device-interfaces-and-integration/embedded-memory-capacity-in-cyclone-v-devices) and [Standard Edition RAM inference guidance](https://docs.altera.com/r/docs/683323/18.1/quartus-prime-standard-edition-user-guide-design-recommendations/ram-with-byte-enable-signals?contentId=HnPPywXesa_G4hmFWGXpew). Installed 17.0.2 tool reports are the implementation authority.


Latest measured request-path work (2026-10-05): the shade-hold snapshot still misses setup by 4.262 ns through CPU request selection, arbitration and address decode; hold passes in every corner. The subsequent parallel arbitration/prefix decode revision passed decoder equivalence, sparse/fair/stalled arbitration and CPU-driven board integration. Its source-frozen fit is pending; no timing-closed claim is made until its own four-corner report passes. See `board_timing_gpu_shade_hold_fit.json` and `../progress.md` for exact snapshots and qualification.


The completed parallel-request fit (`1791174158440919600`) still fails setup, now in GPU texture addressing (-3.388 ns at slow -40 C) and SPU envelope arithmetic (-2.988 ns at slow 100 C); all hold corners pass. The subsequent mask/shift and look-ahead envelope-delta revision passed GPU, voice, full-SPU and board integration regressions with unchanged pipeline cadence. Its new timing snapshot is `1791175045456843000`; its own fit/audit must pass before calling this revision closed.

The checker prints a bounded `TIMING_CORNERS` JSON record before its final result, including failing setup endpoints, all hold margins and the constraint audit. Use this directly for the next RTL decision; recover detailed paths from its report links when needed. This reporting change does not alter synthesis inputs or constraints.


The texture/envelope fit still fails at sample decode plus gain multiplication (-3.181 ns worst slow corner), while hold passes throughout. Secondary paths were queried from the same netlist to batch the remaining fixes; see `board_timing_texture_envelope_secondary.json`. The tested grouped revision is being fitted as `1791177053194722600`, with the original board period and single-cycle constraints. Its positive four-corner results, not prior regression success, determine closure.


Snapshot `1791177053194722600` reduced global setup failure to -1.645 ns in CPU decode/ALU writeback. Voice and scanout secondary paths now pass; small negative margins remain in SPU command writes, GPU alpha arithmetic and cache snoops. Their focused fixes, including fetch-edge decode and an owned SPU command bridge, passed affected reference regressions. Snapshot `1791178913349387400` is the current fit; its own global four-corner audit remains the closure gate.


### 2026-10-05: parallel requester map selection

The fitted snapshot `1791178913349387400` for revision `0754f93` completed map, fit and STA, but failed setup: slow 100 C -1.166 ns, slow -40 C -1.150 ns; fast setup +4.523/+5.763 ns. Hold margins +0.244/+0.235/+0.136/+0.103 ns; all corners fully constrained. Evidence: `docs/board_timing_registered_decode_spu_blend_fit.json`. This is the registered-boundary board diagnostic, not physical MiSTer timing closure. No RBF generated.

The worst path ran from CP0 address through MMIO qualification, arbitration and the final shared address decoder into request offset. Each client now decodes its address before arbitration; target/offset use the same locked one-hot grant as address/data. No request/response cycles added. Verilator arbiter5 passed 320 transactions plus 155 sparse pointer/mask cases, including exposed grant routing under stalls. CPU-driven sound BIOS integration passed unchanged: 4847 matched instructions, 26 sound MMIO, 8 SPU reads, 24 active audio checks, two IRQ2 entry/return pairs, 1760 scanout reads, mirrored RAM and uncached cabinet reads. Reports: `docs/simulation_arbiter5.json`, `docs/simulation_bios_sound.json`. Fresh map/fit/STA snapshot `1791180591744613000` is running; timing closure remains unproven.