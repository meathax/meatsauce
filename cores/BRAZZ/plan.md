# The Crystal of Kings — Crystal System MiSTer implementation plan

Prepared 2026-10-04. Target: **crysking**, BrezzaSoft, 2001, on the AMG0110B/AMG0111B Crystal System. Project/core name: **CrystalSystem**. This file is the authoritative plan. Record completed work, evidence, blockers and the next action in `progress.md`.

## Objective and completion contract

Implement a synthesizable FPGA recreation of the game's board, starting from the official MiSTer template. The game's ROM must execute on an RTL SE3208 CPU, use the RTL VRender0 peripherals, draw its own frames, produce working music/SFX and accept normal player inputs. Finish the complete simulation bring-up first. **Quartus analysis/synthesis and fit/STA run during RTL development as needed. RBF generation, deployment and MiSTer hardware testing belong to Phase 12, after the full simulation gate, with an explicit user request for each RBF build or rebuild.**

Preparation is complete. Work is paused at the human request "commit then stop" on 2026-10-06. Resume only on a new human instruction; the full simulation and final hardware objective remains incomplete. Partial RTL/subsystem/boot evidence is recorded in progress.md; none is a claim of complete gameplay or a finished FPGA core. Every RBF build requires a fresh explicit human build request.

Required before Phase 12: reproducible cold boot from the staged BIOS/cartridge; service/ROM checks; stable title/attract loops; coin/start/character selection; real gameplay with movement, attacks, enemies, damage, effects and sound; P2 join/play; boss/stage transition; death/continue/game-over/restart; persistent settings; reset/pause; all exercised instructions/registers/render modes implemented. Use a scripted full-game route or validated late-stage checkpoints to cover remaining stages and ending behavior. An unresolved crash, missing CPU operation, stalled queue, silent sound engine, placeholder renderer or memory deadline failure fails this gate.

The final validation run must execute the actual synthesizable RTL with normal inputs. MAME co-simulation, captured packets and injected RAM are development tools; they do not satisfy the final cold-boot/gameplay gate. Do not substitute an HPS software emulator, canned frames, a high-level CPU or a recorded attract sequence for the FPGA implementation.


## Current execution priority (2026-10-06)

**Paused by explicit user request.** All recorded live handles below are historical; task-owned work has stopped. On an explicit resume, first run production analysis/synthesis and fit/STA for the final registered CPU operand patch. CPU differential and integrated diagnostic BIOS sound tests pass, but this RTL has not yet had production synthesis/fit. Completed snapshot1791224029627454600 fails physical timing: SDRAM input setup -11.681/-11.297/-8.971/-8.572 ns; internal slow setup -0.172/-0.053 ns; scaled HDMI setup -0.180 ns. Required unconstrained ports remain4 inputs/22 outputs. Preserve docs/production_hps_cdc_drive_timing_result.json and docs/hps_video_cdc_probe.json. The actual HPS second-stage paths pass all corners; overall timing remains open. Do not mask failures or lower clocks. The optional SDRAM cycle diagnostic remains rejected and unapproved.

The interrupted native run1791225574276266400 and checkpoint identity212d5c877684a853c566c79eebf49edb9a5a0e0df5cb2921659f524e683a22a9 predate the CPU patch. They establish bounded development evidence only. Do not transplant their state into the new model. Preserve pristine sys/ and project-owned overrides. On explicit resume, resolve physical timing, then qualify current-source cold boot and checkpoint continuation, repair first-coin audio and prove pixel-exact title/two attract passes/P1/P2 gameplay before all remaining original gates. No RBF was built; each build requires a fresh explicit request.

The historical host-loader diagnostic stopped at clock 8,137,175,759 with audio underrun after consuming both coin pins and producing 21 nonzero samples. This is no attract/gameplay acceptance. Diagnose real sound/display memory service and SPU deadlines with bounded accepted/replied traces and genuine sound MMIO logs; use the qualified physical model for a fresh savable cold boot. Match complete native frames to equivalent MAME presented frames for title, two attract passes, selection and P1/P2 gameplay, then continue all remaining game/features gates. RBF assembly still requires a fresh explicit human build request and remains after the simulation gate.

## Audit and remaining-work summary (2026-10-06)

Audit scope: repository hygiene, live-run state, documentation consistency and plan status. Read-only for RTL/sim/constraints: another session was actively editing `scripts/sim.py`, `sim/boot/*`, `sim/video/scanout.cpp`, SDC/QSF and a `CrystalSystem` fit (quartus_fit PID 39028) plus native/Verilator runs were live at 05:23, so none were touched, rebuilt or restarted. No simulation or fit was run by the audit; no RBF built.

Verified clean: branch `develop`; ROMs, `mister.env`, `donors/*/`, `sim/obj_dir`, `*.rbf` ignored and untracked (only the development `.mra` is tracked); no credentials in tracked files; all `docs/*.json` parse; every file in `files.qip` exists; no donor/diagnostic RTL (`cs_diagnostic_video`, `cs_nvram`, `cs_bus_ram`) is in the production file list.

Findings:
1. **Resolved without altering the vendor tree:** AGENTS.md requires pristine `sys/`. The exact timing/CDC patches now live in project-owned `rtl/mister/sys_top.v` and `hps_io.sv`, selected by `sys_project.qip`; upstream files were restored from pinned template3ea1134. docs/HACKS.md and docs/vendor_override_sources.json record the patches/hashes. The running fit is a frozen copy and is undisturbed. Project-owned source-selection analysis passes in snapshot1791225481152366700 (326.651 s); whole-production timing remains open.
2. Fixed: `Readme.md` and `docs/MISTER_FEATURE_AUDIT.md` still described the diagnostic-raster top level and an `MVTC R0,CR5` CPU stop; corrected to the real-board wrapper status (the audit doc keeps its history behind a dated correction note).
3. Open cleanup (not done, to preserve source-hash identity of live fits): template leftovers `rtl/mycore.v`, `rtl/cos.sv`, `rtl/lfsr.v` are unused by synthesis and simulation (Phase 9 item 1). Remove after the current fit completes, in the same commit as the next source change.
4. Large uncommitted work (12 modified, 6 untracked) on `develop`: commit as coherent milestones once the live fit/run results are recorded; CRLF/LF warnings come from `core.autocrlf`, not content changes.
5. Timing still fails (see Current execution priority): SDRAM input setup -11.7/-11.3/-9.0/-8.6 ns at the 3.175 ns capture phase, scaled HDMI output -0.219 ns and exposed HPS crossing -6.916 ns, 4 input/22 output pins unconstrained (latest fit 1791227413509599700, 2026-10-06: internal setup/hold nonnegative in all corners; the SDRAM input and unconstrained-port failures are unchanged; see progress.md), forwarding-clock route experiment unproved. The saved-fit SDRAM cycle diagnostic still awaits human approval (`docs/sdram_cycle_diagnostic_proposal.md`).

**Update 2026-10-06 (user-requested):** item A timing closure is done at fit `1791239461195686100` (all four corners nonnegative, 0 unconstrained) and an RBF was assembled from that exact fit: `releases/CrystalSystem_20261006.rbf` (sha256 207645472185caa6815d56737843fe1917a23efb1b49694955243e9c9d17f6ce), not deployed or hardware-tested. Items C-H remain; the Phase 11 simulation gate has NOT passed, so this RBF is a timing-closed development build, not a release.

Required to complete, in order:
- **A. Timing closure:** observe the live `CrystalSystem` fit (registered arbiter + HDMI stage), record all-corner setup/hold and unconstrained pins; resolve SDRAM capture ownership/aperture at unchanged clocks (human decision on the diagnostic proposal); fix internal hot paths; constrain remaining pins; then PLL/CDC/memory-interface closure on the production wrapper.
- **B. Project-owned override QIP selection is qualified by analysis;** tidy the tree only without disrupting live source identities (finding3).
- **C. Qualified current-source cold boot** with the phased physical SDRAM model and a savable checkpoint (earlier checkpoint identities are invalid after source changes); keep a separate final genuine cold boot.
- **D. Fix first-coin audio divergence/display underrun** (historical stop at clock 8,137,175,759) with bounded accepted/replied traces.
- **E. Pixel-exact evidence:** complete RGB565 frames vs MAME presented banks for title, two attract passes, warrior selection, P1 and P2 combat, with per-frame RTL bank identifiers recorded; zero mismatches.
- **F. Remaining game gate:** sound pass vs MAME PCM, stage/boss/ending route, continue/game-over/reset/pause/service, DS1302 and game-owned persistence, throughput/deadline measurements.
- **G. Wrapper completion and Phase 10 artifacts:** dynamic video modes and CDC, final MRA, adapted build/deploy tooling, notices.
- **H. Phase 11 simulation gate, then (only on an explicit human build request) Phase 12:** RBF, hardware validation, release artifacts.

## What preparation established

- Official template cloned locally; Quartus 17 project renamed to `CrystalSystem.qpf/.qsf/.sdc`, top wrapper to `CrystalSystem.sv`; `sys/` remains pristine; documented timing/CDC overrides live under `rtl/mister/`. The template demonstration has now been replaced with the real board/platform and physical memory transport; wrapper/features and full timing qualification remain in progress.
- `roms/crysking.zip` and `roms/crysbios.zip` staged privately and unmodified. Full MAME **0.289 (mame0289)** reports `romset crysking [crysbios] is good`. Archive hashes/member CRCs are in `docs/rom_manifest.json`.
- CPU, SoC, video, sound, UART, RTC, flash and NVRAM reference files are staged under `docs/reference/mame/`. Seven critical `.cpp` files match the official `mame0289` tag after newline normalization; hashes/comparisons are in `docs/research_log.json`.
- Nine pinned public donor/reference snapshots are staged under `donors/`, with revision, archive checksum, file inventory and provenance. `docs/DONOR_MAP.md` describes the precise reuse boundaries.
- Public web, GitHub repository, MiSTer-devel, JTcores/OpenCores and Patreon searches did **not locate a usable public SE3208 or complete VRender0 RTL implementation**. This is a bounded search result, not proof that none exists. These blocks remain custom RTL tasks. PIC firmware/model is also unknown for this cartridge.

## Hardware facts and source authority

Follow the staged **MAME 0.289** driver and device files for software-visible behavior; retain documented MAME quirks separately from assumptions about physical timing. Do not silently mix a newer MAME master device into the reference. The physical PCB notes and incomplete device timing are not a complete electrical schematic.

| Block | Evidence / initial target | Implementation decision |
|---|---|---|
| ADChips SE3208 EISC CPU | Eight 32-bit GPRs; PC/SR/SP/ER; 16-bit instruction encoding; little-endian; MAME clock 42,954,540 Hz | Custom SystemVerilog CPU from the staged interpreter/disassembler; no ARM, SH2, Hyperstone or RISC-V substitution |
| VRender0 SoC/renderer | 85,909,080 Hz nominal in MAME; 2 DMA channels; 4 timers; IRQ controller; 32 GPIO; 2 UARTs; CRTC; memory/system/PWM/SIO register areas | Custom register-compatible SoC; borrow small transport/clock/FIFO blocks |
| VRender0 video | Display-list packets, affine texture steps, 4/8/16-bit textures, palette, transparency, shade, programmable source/destination blend, RGB565 framebuffer, bank/flip control | Custom pipelined framebuffer renderer; PSX/Saturn are architecture references, not compatible GPUs |
| VRender0 sound | 32 channels; linear 8/16-bit and µ-law; looping/pitch/envelope/L/R volume; texture/frame RAM sample sources; IRQs | Custom register-compatible engine; SCSP is a scheduling reference; use MAME's conversion/semantics |
| Board RAM | 3 × HY57V651620, each 4M × 16 = 8 MiB; main, texture and frame RAM | 24 MiB of live RAM; external SDRAM/DDR transport, not 24 MiB of BRAM |
| Battery SRAM | GM76C256 physical notes say 32 KiB; driver maps 64 KiB NVRAM | Preserve the MAME-visible 64 KiB initially; note physical/map discrepancy; persist via HPS |
| BIOS | MX27L1000, 128 KiB; default AMG0110B `mx27l1000.u14` | Read-only boot region; default BIOS first, alternate BIOS later within the same game |
| Cartridge flash | 3 × Intel E28F128J3A, 16 MiB each = 48 MiB; eight selectable 16 MiB windows | Banked read image and observed command behavior; missing banks return FF |
| Protection | Scratched PIC16xxx? / dgSMART-PR3, clock 3.579545 MHz; no crysking PIC ROM region/dump | Use the eight exact MAME patch halfwords during load/read overlay; retain untouched source ROMs; generic PIC donor is future research only |
| RTC | DS1302, 32.768 kHz; GPIO CE bit 24, SCLK bit 25, bidirectional data bit 28 | Custom DS1302 slave/device emulation; NeoGeo calendar helpers can inform it |
| PAL / 74HC138 | ATF16V8 and cartridge 3-to-8 decoder | Ordinary address/bank decode from the board map; no programmed PAL contents are available |
| DAC / amplifier | PCB drawing/notes disagree on DA1133A/DA1311A marking; TDA1519 stereo amplifier and volume pot | Deliver stereo digital samples through MiSTer audio; analog parts need no processor core |
| Reset / outputs | DS1233; reset/service/test switches, DSW8, coin-meter darlington TD62003, LEDs, JAMMA, CN1/CN2 | Synchronised reset, inputs, DIP/service logic and counters/output state; unused/unknown connector behavior stays documented |
| Clocks / passives | 14.31818 MHz oscillator; RTC/protection crystals; battery, resistors, capacitors, power circuitry | PLL/CE/reset/persistence equivalents; no invented synthesizable model for an analog passive |

The inventory covers every component named in MAME's motherboard/cartridge notes and every emulated SoC function. Unidentified components, PAL equations, MCU identity and CN2's purpose cannot be guaranteed without a schematic or PCB inspection. They are explicit unknowns, not hidden missing donors. See `docs/HARDWARE_NOTES.md` for the address map and protection details.

## Donor selection and licensing boundary

Prefer small SystemVerilog/Verilog blocks that directly help this design. **JTFRAME** is the primary primitive library; its source now lives in `jotego/jtcores/modules/jtframe`, not the unavailable standalone repository. Candidate RAM/SDRAM/cache blocks and their existing benches are staged. **PSX** is the closest staged texture/cache/pixel/framebuffer transport example; **Saturn VDP1/SCSP** is the closest staged SystemVerilog framebuffer/32-voice scheduling example. Neither implements VRender0's packets, blend arithmetic or registers.

Saturn's staged snapshot has `NOASSERTION` license metadata and no root license found during preparation. Treat its VDP1/SCSP as a design reference until explicit reuse terms are established. PSX/NeoGeo/PIC/SiliconRE metadata says GPL-2.0; JTFRAME/CRT Adjust/Hiscores include GPL-3.0 material. Check actual selected file notices and version compatibility once before copying RTL; do not assume that changing the project license resolves a GPL-2-only dependency. If terms remain ambiguous, use a clearly licensed primitive or write the small block directly from the BSD-3-Clause MAME specification. Preserve provenance and notices. A staged source is not a tested or license-cleared integration.

Do not fetch unrelated 68k/Z80/Yamaha/OKI CPU/sound modules: this PCB does not contain those chips. DS1302 master/controller examples cannot replace a DS1302 slave. The undumped PIC cannot be solved merely by staging a PIC CPU. SiliconRE's selected K054539 material is reverse-engineering documentation, not a complete PCM RTL donor.

## Initial clock and memory architecture

### Clocks

Use one game domain with planned `clk_sys = 85.90908 MHz`, CPU CE every 2 cycles and steady pixel CE every 12 cycles. This preserves the nominal 42.95454 MHz CPU/sound and 7.15909 MHz pixel targets from MAME, while providing the renderer's faster domain. A generic 48 MHz system default is unsuitable for this board's declared SoC clock. PLL rounding must preserve integer ratios and be documented. Do not create a jittering fractional pixel enable.

MAME default raster: 320 × 240 active, 455 × 262 total, approximately 60.054442 Hz, horizontal, 4:3 display aspect. The CRTC is programmable: capture BIOS/game register changes before choosing the implemented timing range. The real PCB notes describe a different startup raster; keep VGA blank until a valid output raster is established if needed, while simulating internal timing faithfully. Keep HPS/DDR crossings in the existing framework domain with explicit handshakes/FIFOs. Reset must wait for PLL/memory readiness.

CPU throughput is a design risk. MAME's interpreter uses an abstract instruction-cycle model; it is not a complete physical SE3208 timing specification. Use a compact pipeline/prefetch and coherent transport caches as needed to sustain the target workload. A correct but very slow multi-cycle CPU is not complete. Measure retired instructions, waits and frame progress in the integrated simulation. Do not compensate with hidden clock overdrive or fabricated idle skips.

### Memory

Plan for a normal single **32 MiB SDRAM module plus onboard DDR3** initially; no capacity question blocks preparation. Total ROM plus live RAM exceeds 32/64 MiB if kept together. Keep cartridge ROM in a reserved DDR3 window during gameplay, and the 24 MiB active RAM in SDRAM. This is an explicit reason to use DDR during play. A 128 MiB all-SDRAM layout is an optional alternative, not a prerequisite or second core.

| Backend allocation (proposed, not CPU addresses) | Size | Use |
|---|---:|---|
| SDRAM `0x0000000–0x07fffff` | 8 MiB | Main RAM |
| SDRAM `0x0800000–0x0ffffff` | 8 MiB | Texture/queue/sample RAM |
| SDRAM `0x1000000–0x17fffff` | 8 MiB | Frame/sample RAM |
| SDRAM `0x1800000–0x181ffff` | 128 KiB | BIOS image if not held in BRAM |
| SDRAM `0x1820000–0x182ffff` | 64 KiB | NVRAM staging if not held in BRAM |
| SDRAM remainder | <8 MiB | Reserved, not assumed available to enlarge the renderer |
| DDR3 physical proposal `0x30000000–0x32ffffff` | 48 MiB | Cartridge flash banks 0–2, immutable source image / protected read overlay |

Confirm the framework's address-unit convention, HPS bridge mapping, scaler/rotation reservations and actual port address width before using these DDR addresses; they are a placement proposal, not already wired hardware. Allocate one owner for each memory range. Do not confuse CPU addresses, SDRAM byte offsets and DDR word-address ports.

Use coherent CPU/DMA/renderer/audio accesses: byte/halfword/word lanes, cached instruction invalidation after RAM writes, texture/palette visibility, framebuffer read-after-write and reset/load ownership must be explicit. Scanout needs bounded bursts into small line FIFOs; a line FIFO is additional transport buffering, not a replacement for the board's framebuffer. Reserve refresh, scanout and audio deadlines, then renderer/DMA/CPU progress with no starvation.

At 85.90908 MHz a 16-bit SDRAM bus has a theoretical 171.8 MB/s ceiling before activate/precharge/refresh/arbitration costs. Native RGB565 scanout needs about 9.22 MB/s. Four full-screen blended passes, with 2-byte texture read + 2-byte destination read + 2-byte write, need about 110.7 MB/s in addition to scanout; 32 × ~44.192 kHz × 16-bit audio fetch adds ~2.83 MB/s before cache reuse. CPU/DMA add further load. These are illustrative bounds, not proof of fit. Measure actual packet overdraw and backend service times in Phase 2/8. If the single SDRAM path misses deadlines, move framebuffer or another hot client to burst DDR3 with its own cache and coherent CPU map before escalating clock speed. The staged PSX backend is an integration example for that fallback.

## Efficient working rules

1. Keep `plan.md` as the plan and `progress.md` as the only progress ledger. Update after a meaningful milestone with commit, command/exit status, compact evidence path and next action. Avoid duplicate roadmaps.
2. Reuse staged sources and observations. A working baseline is not rerun after a documentation-only change. Run one relevant regression after a subsystem change; broaden only if the affected paths justify it.
3. Build one reusable Verilator executable with modes for CPU differential checks, packet replay, audio replay, subsystem MMIO and full board execution. Share ROM loading, RAM transport, input schedule, state capture and frame/audio output.
4. Use lightweight counters, rolling signatures and a short trace ring by default. Save only first-divergence traces. VCD/FST is opt-in for a short failing window, never a full boot/game recording.
5. Introduce deterministic checkpoints once RTL cold boot works. Use them to shorten later tests, while preserving a separate final cold-boot run. Include source/ROM/input hashes and schema/version in checkpoints.
6. Fail explicitly on unknown opcodes, unsupported accessed registers, illegal bank/range, queue overrun and unmodelled render modes. Stubs that hide a missing block cannot be release behavior.
7. Preserve ROMs, donor snapshots and `sys/`. Promote only selected donor files into `rtl/vendor/` with provenance; keep local changes outside pristine source snapshots.
8. Commit working milestones on `develop`. Do not push or create a GitHub release unless requested. Keep ROMs, machine-local configuration, simulator outputs, captures and credentials out of Git.
9. Windows: run POSIX scripts through their shell and Linux executables through WSL Ubuntu. Use one runtime for Verilator compilation/execution. Do not invoke an extensionless ELF/script from PowerShell. WSL enumeration was denied inside the initial sandbox; discover/authorize the runtime when starting simulation rather than declaring it unavailable.
10. Reuse the staged build/deploy/locking tools after adapting their core-specific assumptions. They are scaffolding, not already verified CrystalSystem tooling. The user's 2026-10-04 rule requires an explicit RBF-build request and supersedes standing build authorization. MiSTer access remains authorized. The final-phase ordering restriction still applies.

## Current execution priorities (2026-10-05)

These are the next concrete actions for the active full implementation goal; the full-game objective and final RBF/hardware gate remain unchanged.

1. Resolve physical SDRAM capture and required production I/O/CDC timing. Production 1791205766578342200 has nonnegative reported register corners (setup minimum +0.076 ns, hold +0.096 ns), but remains TIMING_FAIL with 20 input/88 output ports unconstrained. Eight realistic delayed chip/pad profiles expose two fast-return first-halfword failures; an isolated ideal earlier-capture prototype passes all eight, but is disabled in production and has no PLL/I/O signoff. Select and implement a physically qualified pin/capture architecture at the same frequency, run affected delayed/ownership/deadline tests, then production map/fit/STA with actual capture-edge and pin constraints. Do not use the rejected diagnostic multicycle exception, hide failures, lower clocks, or run assembler. Preserve exact historical snapshots and original live diagnostic.
2. Observe native host ROM run 1791198948410855200 (handle 48823) on the combined CPU/GPU pipelines and reserved display service. The preceding run stopped after 18 packets/15,459 stores with an armed scanout underrun. A physical contention diagnostic reproduces that failure with fair arbitration; display priority passes three complete frames with both peers making progress. Production now prioritizes scanout without preempting locked tokens, retaining round-robin service for peers. This is diagnostic evidence; current-source cold boot, stable attract, sound and gameplay must still pass. Never rebuild a live target executable merely because polling times out.
3. Finish production wrapper runtime and physical closure. Real emu now connects the physical board/loader, native video/audio, cabinet controls/pause, actual SRAM backup and shared DDR rotation. Focused host SRAM/DDR ownership tests and wrapper port lint pass; real sys_top synthesis passes with source/resource evidence. Complete wrapper runtime, RTC/game-owned persistence and required CRT/flip features, then constrain actual PLL/I/O/CDC paths and fit as needed. No diagnostic raster or duplicated SRAM belongs in production.
4. Establish integrated pixel-exact evidence. Corrected native MAME 320x240 presented PNG/RGB565 frames are available at 300/900/1800/3600; banks are uniquely identified only at 300/1800. Preserve source-qualified capture phase; never use frame_done screen:pixels as the presented texture after MAME swaps buffers. Use scripts/compare_presented.py on complete native RTL frames from equivalent game state/input route and the actual presented bank, aligned by events and completed flips. An integrated 320x240 BrezzaSoft fade-in splash matches MAME frame 206 at all 76,800 RGB565 pixels; this is an initial boot image, not the title/attract/gameplay gate. The current run did not record a per-frame RTL bank identifier, so do not infer one from image equality. Record zero mismatches, image/source/ROM hashes and exact reproducible paired evidence for title, at least two attract passes, selection, P1 combat and P2 combat. Independent renderer packet replay and unaligned/blank image matches do not satisfy this gate.
5. Complete sound, normal gameplay, all stages/bosses/ending, P2, death/continue/game-over/reset/pause/service and persistent settings with realistic memory deadlines. Reuse validated checkpoints when available; host_checkpoint now saves full native RTL, strict memory model timing/queues, reference/shadow state, observer and cabinet state with exact source/ROM identity; early BIOS continuation is byte-equal over 333,333 clocks. Validate later game checkpoints against uninterrupted continuation before reusing them. Measure actual CPU/GPU/audio bottlenecks before optimizing. Keep one final cold-boot acceptance route and only affected regressions.
6. Pass the full simulation completion gate, then obtain explicit authorization for each RBF build and complete the final hardware/local release phase. No assembler/RBF has been authorized or run. Keep the goal active until the entire objective has evidence.

## Phase 0 — preparation milestone (completed)

- [x] Clone the official template and make a local CrystalSystem Quartus 17 project.
- [x] Stage/audit `crysking` and both BIOS images, without changing source archives.
- [x] Stage pinned donor/reference snapshots and distinguish RTL, reference-only, conditional and unavailable blocks.
- [x] Inventory the full MAME-documented motherboard, cartridge and SoC behavior.
- [x] Pin MAME 0.289 reference evidence and write this plan, progress ledger and goal prompt.

Exit: preparation audit passes; no claim that the game runs yet.

## Phase 1 — lock the implementation contracts and simulation runtime

1. Read this plan, progress, hardware notes and donor map; use the seven pinned matching MAME files as the functional specification.
2. Select the actual Verilator/C++/make runtime already installed. Prefer Ubuntu WSL if working; MSYS2 is a valid alternative with explicit interpreter/executable paths. Confirm one tiny synthesizable model compiles and runs. Do not install a second toolchain unnecessarily.
3. Adapt the copied tools' configuration. Use the full `D:\Arcade\AI\mameexe\mame.exe` for the oracle, not `mame289\mame.exe`, which lacks crysking even though it reports 0.289. Audit Lua CPU/state access for SE3208 and little-endian 32-bit memory; the generic scripts were written for other boards.
4. Freeze the board bus interface (32-bit address/data, byte strobes, request/ready/read response, error/unmapped behavior), memory-client handshakes, IRQ/vector interface, pixel/sample outputs and reset ownership.
5. Define `rtl/board/`, `rtl/cpu/`, `rtl/video/`, `rtl/audio/`, `rtl/memory/`, `rtl/vendor/`, `sim/` and shared state/debug ports. Use synthesizable interfaces with registered responses and bounded queues.
6. Resolve licenses only for files selected for immediate reuse; retain alternate donors as references. Update `docs/STATE.md`, `docs/HACKS.md` and `docs/MAME_KLUDGES.md` as blocks are introduced.

Exit: one documented simulator command works, board interfaces are fixed, and the next implementation can run against a bus/RAM model. Quartus analysis/synthesis and fit/STA checks are permitted during RTL development under the user's 2026-10-05 instruction; RBF generation stays in the final phase.

## Phase 2 — capture one reusable MAME reference suite

1. Use default AMG0110B BIOS, a clean deterministic NVRAM/RTC seed and fixed frame-indexed input scripts. Capture CPU reset/boot vector, instruction samples, MMIO/DMA/IRQ events, render packets/state, selected RAM snapshots, frames and audio registers/PCM.
2. Capture cold boot → logo/title → at least two attract passes. Record a gameplay script for coin/start/selection/movement/combat/P2 join/boss or stage transition/continue/game-over. Reuse one sufficiently long run (about 1800 frames minimum where useful) instead of separate repetitive sweeps for each subsystem.
3. Take a bounded write-timing histogram for texture/packet queue, framebuffer, renderer/CRTC registers, flash banks, sound registers and NVRAM in attract and play. CPU address-space taps alone miss GPU writes through the device's private frame/texture spaces; instrument the relevant device/DMA paths when required. Determine when packet words become visible and front/rear/flip state changes. Do not apply tile/sprite-vblank latching assumptions to a framebuffer GPU.
4. Record CPU operation families reached, MMIO addresses used, render mode combinations and worst-frame packet/pixel load. Cover any unobserved but required game path with a small targeted follow-up capture.
5. Read game instructions/service screens to settle actual controls and button names; base MAME Crystal inputs declare four players/four buttons, which does not prove this game uses every base-system control. Keep P1/P2 gameplay as the required scope.
6. Package the oracle with source/version/ROM hashes, seed, input timeline and event-relative frame selection. Use raw game pixels/RGB565 for exact video comparison, avoiding frontend scaling/filter/color effects.

Exit: a small replayable oracle bundle covers real boot, attract and play; the measured command/bandwidth inventory guides implementation.

## Phase 3 — ROM loader, memory fabric and minimal board map

1. Create one ROM packer/MRA generator from the staged driver/XML. Preserve three sequential 16 MiB flash files and the selected 128 KiB BIOS, with explicit offsets/endian order and deterministic padding; no wasted duplicate ROM copies.
2. Add the load-time protection overlay for crysking only. Use the exact eight halfword replacements in `docs/HARDWARE_NOTES.md`; store original and expected patched values/addresses in metadata and keep the original ZIP unchanged. Apply equivalent semantics in simulation and MiSTer loading.
3. Implement BIOS, main RAM and mirror, texture/frame RAM, NVRAM, eight flash banks, command/ID readback and FF-filled absent banks. Implement reset bank/flash command values and the MAME test-reset compatibility area separately from cartridge protection.
4. Use a latency/backpressure-capable memory model from the first board test. Adapt a staged SDRAM controller/cache/FIFO design, with a DDR ROM backend and a shared client arbiter. Simulate refresh/burst/turnaround limits and expose wait/deadline counters. Do not postpone transport design until after gameplay.
5. Implement active-low inputs, DIP/service/test registers, coin edge IRQs/counters, lamp/LED state and safe reset/download sequencing. Keep unused outputs readable/stateful only where specified.
6. Produce an early `.mra` with generated `<mameversion>0289</mameversion>`, archive CRCs, BIOS handling, controls and DIP lengths. Tag it development status; an MRA does not imply an RBF exists.

Necessary check: one bus-level integration run exercises lanes/mirrors/banks/ID/erased banks/reset/load and a representative mixed-client memory workload. Existing controller tests are reused only for selected controller changes.

Exit: the CPU can see a correctly laid-out, protected ROM image through the same board map/backends used later.

## Phase 4 — implement and bring up the SE3208 CPU

1. Extract the decoder/instruction families from `se3208.cpp/.h` and `se3208dis.cpp/.h`. Implement the eight GPRs and PC/SR/SP/ER, the exact extension-register/flag rules and 16-bit fetch semantics; make reset vector/stack initialization match the staged model.
2. Implement integer/flag/shift/multiply/divide operations, register/immediate/stack addressing, signed/unsigned load widths, stores, push/pop, branches/calls/returns, exception/software trap/NMI/IRQ entry, vector acknowledge and return. Use the reference's edge cases, not assumptions from another RISC ISA.
3. Start with instruction families seen in BIOS to expose useful boot progress early, but complete every defined required instruction before calling the CPU done. Trap unknown decoding; keep architectural state available at retirement.
4. Use one differential harness against the extracted BSD MAME CPU behavior: directed edge cases for each family plus a bounded randomized mix with controlled memory/interrupts. Compare retirement PC/opcode/registers/SR/ER/SP and architectural memory transactions, not arbitrary FPGA internal cycle counts.
5. Integrate ROM/main RAM and run the real BIOS. Compare the first divergence using a ring buffer. Add prefetch/cache/stall handling without changing architectural semantics; invalidate on CPU/DMA writes to executable RAM.

Exit: required instruction families and exception paths pass the focused differential suite, real BIOS advances through initialization, and measured CPU throughput can support the game. No MAME CPU substitution remains in the board simulation.

## Phase 5 — complete VRender0 system peripherals and BIOS handoff

1. Implement SYSID/CFGR and all accessed local-memory/chip-select/system register behavior from the frozen SoC source.
2. Implement the interrupt controller's pending/enables/vector/acknowledge/clear semantics, coin IRQs 12/19, timers, DMA and sound/vblank sources. Verify interrupt masking changes while a source is pending and byte-lane writes to control registers.
3. Implement both DMA channels with width, source/destination direction/increment/hold/count/start/busy/completion/IRQ rules from MAME. Real memory service introduces backpressure; never fabricate successful instant copies in the final design.
4. Implement all four timer control/preload/prescaler/count/reset/IRQ paths; use the staged formula and compare event time in emulated clock units. Record MAME timing approximations explicitly.
5. Implement GPIO and the DS1302 slave: serial edge/bit order, command decode, clock/calendar/BCD, write protection, halt, burst and 31-byte RAM behavior used by the game. Feed a deterministic simulation time; later seed from HPS RTC and persist state where appropriate.
6. Implement the two UART register interfaces/FIFOs/status/IRQ behavior used by boot/game. Generic `jtframe_uart.v` is only a datapath donor; wrap the VRender0 register semantics. Complete PWM/SIO/watchdog/unimplemented register behavior only to the source/observed contract, keeping unexpected accesses diagnostic.
7. Let the BIOS identify flash, copy/decompress its own program/data and transfer execution naturally. Make service reset behavior agree with the documented MAME compatibility routine.

Necessary check: the real boot plus one compact MMIO/IRQ/DMA/RTC replay. Reuse it for later peripheral changes instead of creating one redundant bench per register.

Exit: cold boot reaches the game's program and submits valid renderer/sound work, with no unexplained peripheral stub blocking execution.

## Phase 6 — VRender0 framebuffer video bring-up

1. Implement command queue front/rear (11-bit readback), queue wrap, start/reset/draw controls, bank selection and flip count. Packets are fetched from **texture RAM** (`get_packet` reads a halfword at `ptr << 1`). Confirm packet stride/wrap from `execute_drawing` rather than inventing a CPU-side sprite list.
2. Implement stateful packet fields: only specified fields update retained renderer state; x/y/end coordinates, texture origin/affine increments, palette/texture base/format/size, source/destination blend colors/factors, shade and transparent color.
3. Implement solid fill and opaque 16-bit texture first for visible boot/logo; add 4/8-bit indexed and tiled/linear texture modes, palette bank/update, clamp/wrap, signed fixed-point affine stepping and clipping to the exact reference arithmetic.
4. Complete transparency, shade, all required alpha blend combinations, RGB conversion/rounding/saturation and palette collision workaround. Record source TODOs (dither, async flip and front-buffer drawing/CRTC-start uncertainty) as MAME limitations; do not call a placeholder pixel path complete.
5. Use a pipelined fetch/decode/texture/sample/blend/write design with burst caches and explicit read-after-write handling. Borrow architecture from staged PSX/Saturn, and directly reusable licensed FIFOs/caches from JTFRAME. Do not transcribe the MAME nested draw loop into a single slow per-access FSM.
6. Keep the full board framebuffer semantics: B0 starts at zero; B1 selection uses offsets `0x100000` or `0x400000` in the device's frame address space. Preserve source address units and bank/flip ordering exactly. Render front/back selection and synchronous/asynchronous flip commands need distinct behavior.
7. Implement programmed CRTC and RGB565 scanout, actual framebuffer stride/addressing, blanking and vblank/IRQ/flip coordination. Use small scanout FIFOs/line buffers and predict deadlines under contested memory.

Necessary check: one packet replay corpus from boot/attract/play compares framebuffer bytes and selected output frames to MAME, including state retention, clipping/ROZ/transparency/blend and flips. A few directed packets cover rare numerical edges. Fix the first mismatch, then rerun affected corpus segments.

Exit: boot/title/attract/gameplay captures render correctly with no missing observed packet mode, corrupt bank, queue hang or scanout underrun.

## Phase 7 — VRender0 audio completion

1. Implement the complete 32-channel parameter/global register layout, byte strobes, note-on/status, pitch/sample address, start/end/loop and texture/frame-memory selection.
2. Implement signed 8/16-bit linear sample fetch and exact µ-law conversion table; update/interpolate positions and apply channel envelopes, left/right volumes and saturation according to the staged model.
3. Implement channel end/loop/status/interrupt mask/pending behavior and the game's accessed reverb/buffer/control registers. MAME has incomplete effects/timing; distinguish faithful implemented behavior from a missing hardware effect in the reference.
4. Use a time-multiplexed voice pipeline/cache. Saturn SCSP offers a 32-voice scheduling reference but different registers/sample arithmetic; SiliconRE offers chip research only. Fetch from the same coherent memory fabric as video/CPU/DMA.
5. MAME's initial sample rate is sound clock / 972, approximately 44.192 kHz; the source explicitly questions its divider. Preserve that reference target initially. Connect stereo samples to the native MiSTer audio interface/resampling without assuming an unrelated chip's sample rate.

Necessary check: replay one captured register/memory sequence with directed format/loop/envelope boundaries; compare PCM using agreed integer rounding/alignment. Listen to generated WAV from attract and play. Timing relative to video/game events matters more than a resampled frontend WAV byte hash.

Exit: working music and combat/coin/menu SFX, all required voices/formats, no silent stub, audio starvation or unhandled sound IRQ.

## Phase 8 — genuine integrated Verilator attract and gameplay

1. Integrate the synthesizable CPU, SoC, GPU, SPU, RTC, memories and loader under the board harness. Remove development-only software substitutes. Run cold boot from original staged ROM plus documented load overlays and known NVRAM/RTC seed.
2. Reach attract mode without injected post-boot game state. Save an RTL-generated attract checkpoint and frame/audio/state signatures; run at least two attract passes with no unknown accesses/opcodes or queue deadlock.
3. Apply normal scripted inputs: coin, P1 start, selection, movement, each used action, combat/damage/enemies/effects, P2 join/play, boss/stage transition, death/continue/game-over and restart. Exercise service/test/reset as the game supports them.
4. Cover remaining stage transitions/ending with an input route and/or RTL-created late-stage checkpoints. A cheat-assisted exploratory capture can help coverage but cannot be the sole normal-play evidence. Update coverage from actual RTL execution.
5. Check the worst captured render load and shared-memory pressure with realistic latencies/refresh. Record CPU waits/retire rate, render backlog, queued flips, DMA completion and video/audio deadlines. Correct transport throughput before hiding symptoms with buffering or timing hacks.
6. Produce only the minimum proof artifacts: representative frames, short attract/gameplay audio, compact event/signature log, input file, exact command, exit code and source/ROM hashes. Keep one full cold-boot test and a short affected-path regression set.

Exit: genuine RTL-generated attract and gameplay work with sound/controls and the required transitions; no unresolved critical functional or throughput problem remains.

## Phase 9 — MiSTer wrapper and required user features, still simulation-only

1. Replace template `mycore`/demo references with the actual board. Wire `emu` reset, CPU pause, HPS IOCTL/DIP/input, SDRAM, DDR3, video and stereo audio. Leave `sys/` untouched; reuse its standard HPS/video/scaler behavior.
2. Finish the `.mra`: `crysking.zip|crysbios.zip` handling, default/alternate BIOS selection where supported, exact ROM layout/CRC/version, documented load patch behavior, correct game-specific controls, DIP/service/test and reset. Use the game's actual button names; DIP name+longest option fits 28 columns.
3. Expose pause (gamepad + OSD + persistence arbitration), applicable DIP settings, aspect/crop/scaling, flip screen, stereo/mono mix and core-side CRT Adjust. Hide dependent CRT controls unless enabled and HDMI-only controls under direct video. This horizontal game needs no mandatory rotated-game rendering branch; framework rotation support is sufficient where exposed.
4. Persist NVRAM/RTC. Determine whether high scores already persist there; if yes use that path. Integrate the staged Hiscores helper only if score storage requires it and an actual game-specific range/initialization signature has been identified. Do not invent a score address or run duplicate save systems.
5. Flip scanout coherently for HDMI/analog; verify a software-side 180-degree reference frame. Keep CRT Adjust optional/bypass-identical and use native vertical blank, not combined H/V blank, at its input. Vertical size/savestates/cheats are optional enhancements unless needed for the agreed objective.
6. Use vendor-primitive shims for the wrapper simulation. Compile/lint the real board plus wrapper and exercise load/reset/pause/IOCTL/persistence transactions. This simulation checks wiring without generating an RBF.

Exit: MiSTer interfaces and required controls/features are connected to the working board and pass a single wrapper-focused regression.

## Phase 10 — prepare release/build artifacts without building an RBF

1. Finalize module/QIP lists, PLL configuration, SDC clock/IO/CDC constraints, SDRAM placement and debug identity ports. Count inferred memories/DSP/multipliers and estimate logic from the selected design; record capacity risk honestly because a real fitter has not run yet.
2. Adapt `build_staged.py`, `hwlock.py`, `deploy.py` and identity/probe scripts for this core. Use a clean source snapshot for the later build, bounded logs, all-clock timing-slack gates and mandatory fitted-instance checks. Configure normal/debug revisions if debug probes are actually implemented; do not create inert debug menus.
3. Prepare README/status/controls/credits/license inventory and `HACKS.md`/`MAME_KLUDGES.md`/state inventory. Keep a clear list of known original-reference limitations. ROMs/credentials stay private; release artifacts include no commercial ROM data.
4. Prepare repeatable Phase 12 launch, screenshot, reset/input/audio and rollback commands, using local connection instructions. Keep RBF generation and hardware execution behind the simulation gate; run analysis/synthesis and fit/STA as needed during RTL development.

Exit: a reviewable build/deployment recipe and release metadata are ready, with no pending implementation dependency deferred to hardware.

## Phase 11 — single simulation completion gate

Run one consolidated acceptance suite against the final implementation revision:

- Cold boot/service checks → title → stable attract with real ROM execution.
- The scripted gameplay/transition/P2/continue/reset coverage from Phase 8, including short frame/audio evidence and persistent settings.
- Focused CPU, GPU, audio or MMIO regressions only for blocks changed since their last pass; no redundant reruns of unchanged donor benches.
- Realistic memory backpressure/refresh; no unknown operations/accesses, starvation, lost IRQ, stuck render queue or audio/video deadline miss.
- Wrapper ROM layout, loading/pause/persistence/control/DIP behavior and final source/license/MRA completeness.

Record commands, exits, source/ROM/input hashes and evidence paths in `progress.md`; sign off the **SIMULATION COMPLETE** checklist there. Timing differences from MAME's abstract models must be explained and cannot conceal a game malfunction. If it fails, repair the affected subsystem and rerun only that path plus the impacted acceptance segment. **Do not start Phase 12 until this gate passes.**

## Phase 12 — FINAL PHASE: Quartus RBF build, MiSTer validation and finish

This is the final production RBF and hardware phase. Each RBF build requires an explicit user build request. Analysis/synthesis and fit/STA checks are authorized during RTL development under the user's 2026-10-05 instruction. Task-related MiSTer access retains standing authorization.

1. After the simulation gate, require an explicit user request for the RBF build under the user's latest global rule. Check shared build/JTAG reservations using the locking tool. Build the validated clean commit in an isolated staging snapshot with **Quartus 17.0.2** at the installed `D:\q17` toolchain. Record revision/commit/seed, fitted resource use and every relevant clock's setup/hold slack; successful fitting alone is insufficient.
2. If fit/timing fails, make the smallest implementation/constraint fix, run the affected simulation regression (and gameplay gate if behavior changed), then rebuild in this same final phase. Actual fit feasibility remains unproven until this step; no promised fixed completion time.
3. Stage the validated RBF/MRA to the MiSTer using local connection configuration. Preserve the prior task-relevant bitstream for rollback. Load the game's existing local ROMs; record deployed identity so diagnostics cannot be mistaken for another core.
4. Perform one purposeful hardware pass: cold boot, title/attract, coin/start/selection, normal gameplay/P2, stage transition, SFX/music, continue/game-over, reset, NVRAM/RTC persistence, controller inputs and applicable HDMI/analog/CRT/flip/pause features. Capture screenshots and a short audio observation; confirm boot/game speed and memory reliability.
5. If hardware differs, save a bounded counter/probe/state dump, reproduce it in simulation and repair at the responsible layer. Do not conduct JTAG during other builds/simulations or kill another session's process. Avoid speculative full rebuilds and unrelated feature expansion.
6. Once playable hardware, fit/timing, sound and persistence pass, place the verified RBF and primary MRA in `releases/`, with BIOS alternatives in the appropriate alternatives directory. Update progress/README with the build identity and actual results, retain all dependency notices and AI-generated-code disclosures required by current MiSTer contribution guidance. No remote publication/push is implied.
7. Mark the future goal complete only when its stated simulation and hardware outcomes are achieved. If a material limitation remains, state it plainly and keep the goal incomplete; finishing documentation or merely producing an RBF is insufficient.

Exit: verified playable Crystal of Kings MiSTer core, local release artifacts, evidence and complete progress ledger. This final phase includes any last hardware-driven corrections; there is no later planned bring-up phase.

## Critical path and stop conditions

Critical path: **SE3208 correctness/throughput → BIOS/system/MMIO → packet GPU + memory deadlines → sound → real integrated gameplay → wrapper/features → single sim gate → final hardware phase**. Packet/audio replay work can proceed independently once the board/memory interfaces and captured oracle are fixed. Keep CPU boot moving while renderer/audio work proceeds where safe; avoid two workers changing the same interfaces.

Main risks: no existing target CPU/GPU/SPU RTL; incomplete physical timing/MCU/PAL knowledge; bandwidth on one SDRAM; license ambiguity in otherwise useful donors; actual Cyclone V fit/timing. The plan closes these through focused measurements and staged alternatives. It does not promise that staging sources makes this board a simple port.

Do not widen scope to other Crystal System games, add unsupported peripherals, chase instruction-cycle fidelity absent evidence, build savestates/cheats as a prerequisite, or repeat broad donor searches after selection. Reopen research only for a concrete missing feature/blocker. Future game support can reuse this board after crysking is complete.

## Primary references and exact recovery

- [Official MiSTer template](https://github.com/MiSTer-devel/Template_MiSTer); initial commit recorded in `docs/template_provenance.json`.
- [MAME 0.289 Crystal driver](https://github.com/mamedev/mame/blob/mame0289/src/mame/misc/crystal.cpp).
- [SE3208 CPU](https://github.com/mamedev/mame/blob/mame0289/src/devices/cpu/se3208/se3208.cpp), [VRender0 SoC](https://github.com/mamedev/mame/blob/mame0289/src/devices/machine/vrender0.cpp), [video](https://github.com/mamedev/mame/blob/mame0289/src/devices/video/vrender0.cpp), [sound](https://github.com/mamedev/mame/blob/mame0289/src/devices/sound/vrender0.cpp), [DS1302](https://github.com/mamedev/mame/blob/mame0289/src/devices/machine/ds1302.cpp).
- `docs/reference/mame/SOURCE_MANIFEST.json`, `MAME_COMMANDS.json`, `mame_version.txt`, `mame_listxml.txt`, `mame_verifyroms.txt` and corresponding stderr retain exact local evidence.
- `donors/manifest.json`, each donor's `PROVENANCE.json/.md` and `FILES.json` retain pinned download/recovery details. `docs/research_log.json` retains GitHub search results and source comparisons.
- [MiSTer contribution requirements](https://github.com/MiSTer-devel/Wiki_MiSTer/wiki/Contributing-a-Core-to-MiSTer-FPGA), [Quartus compilation guidance](https://mister-devel.github.io/MkDocs_MiSTer/developer/mistercompile/).

## Continuous implementation and timing checks (user update, 2026-10-05)

Run `python scripts/check_timing.py` for changed board RTL, and `python scripts/check_timing.py --fit` after changes affecting register paths, memories, arithmetic, arbitration, clocking or resource use. Fix synthesis/fit errors and negative setup/hold slack at their source, then run the affected simulation regression. A passing previous report does not cover changed sources. Use source hashes and isolated snapshots, preserve diagnostic logs privately, and record actual outcomes in progress.md.

The intermediate target is the actual `cs_boot_probe` board source set in `cs_timing_registered`, not the diagnostic MiSTer wrapper. Use `--registered-interfaces --fit` on the DE10-Nano device at an 11.640 ns system period. Only synthetic pin-to-boundary segments are excluded; actual core and boundary-register paths remain single-cycle timed. Preserve the earlier raw-port reports with provisional interface budgets as historical evidence. Its result is intermediate board implementation evidence. Final closure must include the production wrapper, PLL, real memory backend, all clocks, CDC and real interface constraints. Never waive a negative path or apply speculative false/multicycle paths merely to obtain a pass. Analysis/synthesis/fit/STA may run before the simulation gate; the script never invokes the assembler. RBF generation and MiSTer testing remain the final phase, subject to explicit RBF build authorization.


Continuous timing clarification (2026-10-05): use `python scripts/check_timing.py --registered-interfaces --fit` for intermediate synchronous board-core closure, followed by source/hash-qualified fit/STA resumption only when unchanged. The generated register-boundary bench times every core path at 11.640 ns; only its synthetic pad segments are excluded. Record the model scope and all-corner setup/hold/unconstrained results. This does not replace final production-wrapper/PLL/physical-memory/I/O/CDC closure. Preserve historical raw-port failures and never call a changed RTL revision closed from an older report. RBF generation retains the explicit authorization rule and final simulation gate.


Historical measured timing update (superseded; retain recovery): owned-request host fit 1791191142527600500 removed the SRAM-enable failure but still misses cold setup by 0.045 ns on CP0 fill_word -> CRTC configuration_pending. Resolve the measured comparison path at unchanged clocks, run affected regression and fresh host fit. Host ROM first-drawing diagnostic 1791190553575772000 passed before the boundary change; preserve it as partial evidence and proceed to current-source stable attract/gameplay with physical timing and paired MAME pixels.
