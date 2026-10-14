# Historical Sheriff plan — superseded 2026-10-10

This preserves the complete previous plan text, with CRLF line endings normalized to LF. It is historical, not the active execution plan. Dated next actions, Quartus hold notes and old launcher examples may be superseded. Follow `../plan.md` and current `AGENTS.md`.

Exact original bytes: `_checks/plan-optimization-20261010/original-plan.md`; SHA256 `f96659b84373b87a6764d396da31f5a4900b6849a1a8a5e645b44b98fd4271eb`. Source repository revision: `55dccba694e3019de6625c327eb6a134a49a4758`. The original committed plan also remains recoverable from that revision.

---

# Nintendo 8080 MiSTer implementation plan

Current RTL batch: source-correct SN PCM conversion changes38 gain-ROM words; the native96000-sample component corpus passes with zero PCM/comparator errors (`docs/evidence/sheriff_sn_pcm_quantization.json`). Real current bare-board/8080/8035 execution through1201 fields now has actual native/workflow exit0: all937008 audio samples match the retained component-delta prediction,25485 samples change, and four digital journals plus25 RGB/25 RAM snapshots equal the prior source (`docs/evidence/sheriff_current_gain_integration.json`). Current/staged source and all artifact hashes verify. No registers or clocks were added. This closes scoped mono1 gain integration only. Q32/reference recording assumptions, mixed hardware enable/retrigger, complete current wrapper/later gameplay/graphics and queued fit/STA/resources remain required. Preserve and reuse completed captures with their exact source identities.

**Quartus resumed (2026-10-09): the user explicitly permits normal Quartus use again. Run necessary analysis/synthesis, fit and timing checks through the shared FIFO queue, preserving the resource limits in `config/resource_limits.json`. Earlier dated hold notes describe the state at those milestones; the hold is now lifted. RTL edited during the hold still needs exact-source timing/resource qualification. RBF assembly remains gated on complete simulation and final-source acceptance plus explicit build authorization.**

Prepared 2026-10-09. **Complete Sheriff first, with one parent ROM version: `sheriff` from MAME 0.289.** The family roadmap then adds the other requested games. The real board and MiSTer adapters are implemented with scoped simulation evidence in `progress.md`; complete graphics, gameplay, final timing and release gates remain open.

## Scope and order

The saved finite P1 regression before the SN PCM-conversion change is qualified through1201 fields: native and MAME actual exit0, all25 exported RGB fields match the unchanged timed reference, and native I/O/RAM/digital-sound streams are exact prefixes of the retained cb67879 run. Evidence: `docs/evidence/sheriff_current_gameplay.json`. The cocktail scenario also reaches the first P2 turn through4801 with85 exported fields matching MAME (`docs/evidence/sheriff_current_cocktail.json`). Its first shared-input read difference near field3800 is explained by MAME callback ordering, with an unchanged diagnostic capture and no stream shift (`docs/evidence/sheriff_cocktail_input_boundary.json`); complete I/O equivalence remains unqualified. Current wrapper startup changes initialize the idle hiscore pause and guard gamma until a complete lookup-table upload. Both failed hostile seeds now pass120-field boot/picture verification at fingerprint `01a92c0010fbadb9`; retain the input-response warning and require exact-source fit/STA/resource qualification. Do not repeat completed scenarios unchanged. These captures do not close full gameplay, later corners, mixed audio or exact-source timing/resources. Select the next necessary lifecycle/control scenario from an unchanged deterministic MAME capture; retain the unresolved P1 field2760 pixel and physical RAM/READY/serializer questions. See `docs/GAMMA_STARTUP.md`, `docs/evidence/sheriff_gamma_guard.json` and `docs/evidence/sheriff_hiscore_powerup.json`.

The saved full-wrapper centered-input gameplay before the SN PCM-conversion change is terminal with actual worker/native exit0 through1201 fields (monitor0..1200), sourcea220ba2c8c553374 unchanged. All14 frozen P1 movement/aim values plus coin/start/fire are observed through ordinary HPS commands. Evidence: `docs/evidence/sheriff_current_wrapper_centered_gameplay.json`; recovery `_checks/current-wrapper-neutral-1201-20261010-force/run/` and `.preflight/runs/20261010-054834/`. The earlier uncentered-input negative and cached nonexecution remain retained; do not repeat the completed scenario unchanged. Whole lifecycle, wrapper/MAME moving-video phase, mixed sound and exact-source timing/resources remain separate gates. The original audio negative remains unchanged; exact reference DAC reconstruction and the first SN numerical gain-boundary diagnostic are recorded in `docs/AUDIO_COMPARE_CONTRACT.md`.

The current-source cocktail scenario is terminal: native worker and observer both exit0, with85 captured fields matching the stored MAME scanout through4801. All14 P2 control values and flip4207/first P2 read4339 are observed. Its first shared-input difference is documented as MAME callback ordering; complete I/O/lifecycle acceptance remains separate. Retain the first Bash-CRLF launch failure and successful v2 receipts; do not relaunch a completed scenario.

The incremental cocktail observer is terminal/exit0. Its25-field P1 regression and isolated pixel-negative test remain retained. Early PLL diagnostics did not reproduce the original black boot; full-window diagnosis localized gamma enable, and the guarded current wrapper passes the two failed120-field hostile cases (see docs/GAMMA_STARTUP.md). Do not reuse the insufficient-window PLL attribution as an RTL fix instruction.

| Order | Game/profile | Reference | Scope |
|---|---|---|---|
| 1 | Sheriff, `sheriff` | `n8080.cpp`, `n8080_a.cpp` | First complete game; native graphics, sound, controls, attract and gameplay |
| 2 | Space Fever, `spacefev` | Same driver, Space Fever sound configuration | Color and monochrome video option |
| 3 | SF-HiSplitter, `highsplt` | Same driver | Parent set 1; different ROM and input/DIP configuration |
| 4 | Space Launcher, `spacelnc` | Same driver | Parent; retain corrected IRQ/DAC behavior |
| 5 | HeliFire, `helifire` | Same driver, separate sound board | Parent set 1; color RAM, background effects, 5 MHz MCU, 8-bit DAC |
| 6 | Computer Othello, `cothello` | `cothello.cpp` | Separate 8080/M58741P profile; clock/HOLD and sound limitations need evidence |
| 7 | Block Fever, `blockfvr` | `blockfvr.cpp` | Separate **8085** profile; tilemap/ball/ADC/discrete sound |
| After shared Sheriff path | Bandido | `bandido`, clone of `sheriff` | License variant requested by name; extract only its differing chips from the staged merged Sheriff ZIP when adding it |

Sheriff has a published [Museum of the Game score of 4.88/5](https://www.arcade-museum.com/Videogame/sheriff), based on one vote. This is weak evidence for a universal ranking; Sheriff's explicit priority determines the selection. Do not switch to a different game to chase an incomparable rating.

The available ROMs for all seven parents are already staged. See `docs/evidence/family_rom_manifest.json`: 60 dumped chips, all matching local MAME size, CRC32 and SHA-1, without BAD_DUMP/NO_DUMP markers. Only Sheriff is the initial implementation target. Do not expand into all clone versions, cheats, network features, or savestates before its completion.

## Fixed working rules

1. Native board simulation reaches attract mode and real gameplay before assembling an RBF. Screenshots from MAME alone, a synthetic test pattern, or replaying precomputed frames cannot satisfy this gate.
2. Quartus **analysis/synthesis, fit and TimeQuest happen during development**. They do not authorize assembly. Keep the full framework in fit checks so utilization and timing include the platform.
3. `sys/` stays at the pinned template revision. Use the template for HPS/HDMI/audio/DDR platform support, with game adapters outside it.
4. ROM/program execution remains in FPGA RTL. MAME is the reference/capture tool; do not move gameplay to the ARM processor or replace the real sound ROM with guessed tunes.
5. Read `mamebug.md` when deciding behavior. Historical fixed defects must remain fixed. An unresolved MAME issue does not justify inventing a hardware correction.
6. Keep each approximation, evidence-backed correction, and unresolved hardware question in `docs/HACKS.md`. A verified hardware correction gets its own reference result and a narrowly explained difference from MAME; do not waive unrelated mismatches.
7. Update `progress.md` at completed milestones with the code revision, commands, result, and recoverable evidence paths. Commit local work on the task branch; do not push or publish automatically.

## Architecture and memory

Separate synthesizable `rtl/n8080_board.sv` from `Nintendo8080.sv`, which adapts MiSTer ports. Build the Verilator harness around the **same board RTL** used by Quartus, with an explicit simulation ROM loader and framework/IP shims only at platform boundaries.

Planned modules: `n8080_clock_enables`, `n8080_bus`, `n8080_irq`, `n8080_shift`, `n8080_bitmap`, `sheriff_color`, `n8080_inputs`, `n8080_sound_pins`, `n8080_mcs48`, `n8080_sn76477`, and `n8080_audio_mix`. Later profiles add `spacefev_color`, `helifire_video`, `helifire_sound`, `cothello_board`, and `blockfvr_board`. Reuse a CPU/primitive where suitable; do not transplant another board's maps or sound effects.

Sheriff's CPU map masks A15: ROM at `0000-3fff`, RAM at `4000-7fff`, mirrored above `7fff`. Keep the entire 16 KiB RAM window because it contains work RAM as well as the bitmap. The display reads 32 bytes per row across 256 rows: 8 KiB of bitmap data, bits least-significant first. This board actually has bitmap RAM, so scanout from that memory is correct; a sprite engine is unnecessary.

Store program ROM (16 KiB mapped allocation), CPU/video RAM (16 KiB), sound ROM (1 KiB), MCU internal RAM (64 bytes for 8035), and Sheriff color PROM (1 KiB) in BRAM. The nine program chips occupy `0000-23ff`; match MAME's zero-filled unmapped ROM tail unless hardware evidence establishes a different bus value. Use synchronous dual-port RAM: one CPU port and one scanout/debug port; define read/write collision behavior from the measured write stream.

Use local BRAM during gameplay. These boards do not require external SDRAM or DDR gameplay memory. DDR is already used by the MiSTer scaler/rotation platform, and can be used for fast download staging. The ordinary HPS `ioctl` BRAM loader is the first working ROM path; add the staged DDR loader only if it provides a useful platform feature. Avoid a new memory controller to load an 18 KiB Sheriff image.

Sheriff proposed ROM download packing: main `0000-3fff`, sound at `4000-43ff`, PROM at `4400-47ff`. Generate the MRA and simulation image from the manifest once; include zero padding explicitly. Other profiles get distinct region maps and a stable mod/profile byte. No ROM payloads in Git.

## Clocks and timing before first RTL

| Profile | Reference clock | Proposed game master | Enables/limits |
|---|---|---|---|
| Sheriff and other TSF-family parents | 20.160 MHz board oscillator | **50.400 MHz** | Pixel 5.040 MHz, fixed `/10`; 8080 2.016 MHz, `/25`; MCU crystal 6 MHz, `5/42` enable ratio |
| HeliFire sound | Corrected 5 MHz MCU crystal | Same 50.400 MHz | `25/252` crystal-enable ratio; preserve the MCU's internal divide by 15 |
| Block Fever | 6.144 MHz crystal | 49.152 MHz profile | Pixel `/8`; 8085 oscillator `/8`, effective 3.072 MHz T-state rate after its internal division |
| Computer Othello | 3.579545 MHz crystal | Decide from verified M58741P timing | Existing 750 kHz MAME CPU is an acknowledged workaround; do not present it as verified hardware |

Generate the master PLL using Quartus for the real device; verify the achieved ratio and legal PLL VCO range, rather than assuming an arbitrary handwritten divider is realizable. Change profiles only while the board is held in reset. Sheriff native raster: 320 pixels per line, 256 lines per frame, active X `0..255`, active Y `16..239`, line rate 15,750 Hz, frame rate **61.5234375 Hz**. Rotate output by MAME ROT270, preserving a 3:4 portrait display aspect.

The 8080 donor takes phase enables: derive a real two-phase T-state schedule inside the `/25` period and qualify its bus timing. Do not count the two phases as two CPU cycles. The 8035's nominal 400 kHz machine cycle is **6 MHz / 15**, not its crystal input. All board registers use one master clock with enables, including audio; no fabric divided clocks. The stock MiSTer framework necessarily has platform clocks; inventory these separately.

## Development resource and TimeQuest gate

Use the complete Cyclone V target and the reported device capacities, not guessed denominators. All limits are strict upper bounds:

| Metric | Must be below |
|---|---:|
| Logic ALMs | 80% |
| LABs partially or completely used | 90% |
| Peak interconnect, maximum of H and V | 85% |
| Average interconnect | 60% |
| M10K blocks | 90% |
| Block memory bits | 85% |
| DSP blocks | 90% |

Archive the map, fit, router and STA reports for each checked source snapshot. Record used/available counts and percentages in `progress.md`, including H/V interconnect separately. If the normal summary omits routing utilization, obtain the corresponding Fitter report panels; mark it UNKNOWN until measured. A successful process exit is not a timing/resource pass.

Gate on setup and hold slack >= 0 at the applicable operating corners, recovery/removal and pulse-width checks, all board clocks constrained, no unexplained unconstrained paths, and reviewed clock crossings. Audit generated clocks, exceptions, and setup/hold multicycle pairs. Never silence a failing game path with a blanket false path. Fix timing at the responsible path using pipelining, fanout reduction, enables or BRAM scheduling; avoid increasing the clock unless a measured bandwidth requirement warrants it.

Run **map** after a meaningful RTL edit batch. Run **fit + STA** after the initial PLL/CPU/video skeleton, sound integration, complete MiSTer integration, and a new board profile or change that affects clocks, RAM inference, bus critical paths, arithmetic width, or routing. Tiny changes outside those paths need only focused simulation/map until the next milestone. Reuse an existing fit only if the source/constraints/settings hash matches exactly. Run fits sequentially and check free memory; shared lessons document silent fitter failures under memory pressure.

Use `tools/quartus_check.ps1 -Stage Fit` on a committed snapshot. It submits build-ID generation, analysis/synthesis, fit and TimeQuest as one job through the shared FIFO queue, with no assembler/full-compile call. Exit code alone does not declare acceptance; assess all documented utilization and timing limits.

## Phase 1 — Reference capture and donor qualification

1. Record the MAME binary version, source hashes and ROM manifests already staged. The local source checkout has no Git identity, so hashes are the exact reference identity. Preserve its source alongside any later patch.
2. Implement one Lua capture tool for deterministic input scripts, CPU I/O transactions, IRQ/INTE state, video-control writes, relevant RAM checkpoints, native RGB frames and audio WAV. Use the local 0.289 binary with fresh configuration and the staged ROM path.
3. Obtain a bounded Sheriff recording covering boot, one attract loop, coin/start, movement, all eight aim directions, shot/hit/death, scoring, round transitions, the red-heart/color effect after round 3, and game over. Record both players/cocktail orientation. Start with one combined 1800-frame attract/play capture; extend only if a required event is missing.
4. Capture a per-scanline histogram of writes to bitmap RAM and color/video registers during the same run. This determines actual visible effects of concurrent CPU writes; do not add a frame latch merely because an emulator draws at frame end.
5. Qualify `vm80a_core` directly with a short CPU diagnostic and focused DAA, carry/auxiliary-carry, stack, EI delay, HALT, INTE and interrupt-acknowledge cases. Match the timed bus interface needed by Sheriff. Keep T8080se as the fallback; convert VHDL once with pinned GHDL if needed.
6. Qualify the BSD T48 kernel with its supplied relevant benches and a sound-ROM command sequence. Configure 64-byte internal RAM and external 1 KiB program ROM. Confirm active-low IRQ, T0/T1 and quasi-bidirectional port behavior. Avoid the staged noncommercial `I8035IP` wrapper.

**Exit:** one reproducible reference/capture bundle and qualified CPU kernels. Do not run exhaustive unrelated CPU test suites if these cases and real ROM execution already close the integration risks. Store donor changes separately with diffs and provenance.

## Phase 2 — CPU, bus, bitmap and early fit

1. Implement reset, BRAM preload/download arbitration and the 8080 bus decoder. Derive memory versus I/O from real status/transaction signals; mirror CPU/I/O addresses exactly.
2. Implement the shift latch: two write bytes, programmable shift count, and read port, using the equations from `n8080.cpp`. Test boundary shift counts and byte order once.
3. Implement raster counters and IRQ sources at lines **128** (RST1 vector `cf`) and **240** (RST2 vector `d7`), with INTE gating and acknowledge clearing. Include the historical INTE bug regression, MB-04.
4. Implement bitmap scanout and Sheriff PROM indexing `32*(y>>3)+(x>>3)`. Output black for cleared bits and RGB from the three low palette bits. Primary manuals confirm a video `198` shift register at I/O position 1L; resolve its parallel-load/shift phase, DRAM read latch and normal/flip selection before qualifying concurrent writes. The present per-pixel RAM-bit selector is a functional baseline, not a physically qualified serializer. Follow `docs/HARDWARE_VIDEO.md`; keep the CPU port-3 shift buffer independent of the video register.

   The original 12000-frame corrected-DAC third-round replay is now terminal. It fails acceptance: 48/204 captured native fields match the functional streaming oracle; first pixel difference is frame 2400, and broader gameplay diverges near frame 2752. Native does not issue the reference's red color command 14. Retain the frozen input and completed results (`docs/evidence/sheriff_rounds_native_terminal.json`); resolve the earliest causes before another full replay. This supersedes its earlier pending status.
5. Implement color modes and flip: mode 1 overrides only PROM entries without bit 3; mode 2 overrides all colors; mode 3 forces white; override color is `data XOR 7`. Read video-control mode from bits 4:3, data from bits 2:0, and flip from bit 5.
6. Execute the real Sheriff ROM in Verilator until its own attract-mode loop is visible. Compare RAM, I/O and native pixels at matched checkpoints. Diagnose the **first** divergence, not a distant screenshot symptom.
7. Run the first full-framework **map, fit and STA** with the actual PLL/CPU/RAM/video shape. Resolve RAM inference and clock constraints before more subsystems accumulate.

**Exit:** Sheriff reaches attract mode through real CPU execution, native video passes selected reference frames, early timing/resources pass. Sound may still be pending at this milestone and must be labelled accordingly.

## Phase 3 — Controls and real gameplay

1. Generate input/DIP descriptions from MAME, with manual names where available. Wire coin, start, lives, cabinet, movement and aim polarities from the actual driver.
2. Implement the eight-position shooting selector as the driver's encoded direction values. Provide independent movement and aim using a second stick, keyboard aim keys, and a d-pad-only rotate-left/rotate-right alternative plus Fire. Validate diagonals and wraparound. Do not replace independent aiming with movement direction.
3. Exercise coin/start, alternating two-player behavior, both player movement/aim, score changes, deaths, game over and restart in the same deterministic harness.
4. Verify flip and cocktail routing together; avoid applying the same flip once in the board and again in the platform adapter.

**Exit:** playable Sheriff from reset through game over, with CPU-generated graphics and expected input/RAM/I/O behavior. Reuse the Phase 1 capture. Add a regression only for a concrete behavior previously wrong or newly introduced.

## Phase 4 — Sound, the main custom subsystem

1. Wire sound command latches/pin permutation to T48, preserving active levels, persistent IRQ, T0/T1, P1 reads and P2 bit 7 one-bit DAC output. Use the exact mapping in `n8080_a.cpp` and its header.
2. Implement the two Sheriff 74123 monostables and retrigger/stop behavior. MAME's pulse duration is `550*33*33` microseconds. Do not treat the sound-CPU interrupt as a one-clock pulse (MB-05).
3. Reuse licensed RC filter, rate limiter and mixer primitives, but implement a **Sheriff-configured SN76477**: SLF/VCO, noise, noise filter, attack/decay, one-shot/envelope, mixer controls, enable polarity and external VCO voltage. A Space Invaders UFO oscillator does not implement this chip's complete behavior.
4. Start from the staged MAME numerical model and documented Sheriff component values: noise 36 kOhm/100 kOhm/1 nF; decay 620 kOhm; SLF 47 nF/1.5 MOhm; one-shot 47 nF/560 kOhm; shared attack 1 uF/20 kOhm; VCO 1 nF/1.5 MOhm; amplitude 150 kOhm and feedback 47 kOhm.
5. Use fixed-point integrators/LUTs and clock enables; keep analog state accessible to checkpoints. Pipeline multiplies only where the first fit requires it. Mix DAC and SN paths to signed PCM; preserve the relative default gains and permit volume adjustment.
6. Produce WAV clips from the actual sound ROM for shot, hit, player death and tunes. Compare command timing, pitch and envelopes against 0.289 and original-board evidence available through the bug/source references. Noise phase need not have bit-identical WAV samples; graphics still require exact pixels.
7. Run **map, fit and STA** after the SN76477/DAC path is connected. Do not postpone audio arithmetic timing until the final build.

**Exit:** all Sheriff event classes produce correct sound commands and plausible measured pitch/envelopes, with no missing effects, clipping or stuck sound; timing/resources pass. Any remaining analog approximation is described in `docs/HACKS.md` and prevents an unqualified claim of exact sound.

## Phase 5 — MiSTer integration and Sheriff simulation completion

1. Replace the template demonstration with the board instance; wire HPS `ioctl`, reset/loading hold, stable profile/mod selection, DIPs, joysticks, keyboard and audio.
2. Reuse template `hps_io`, `arcade_video`, `video_freak`, screen rotation and native video outputs. Support original/alternate aspect, integer scaling/crop, HDMI rotation and board flip. Hide HDMI-only controls for direct video.
3. Add Pause with shared CPU/audio/video-enable policy so command latches and monostable state resume coherently. Use the donor pause handshake where appropriate.
4. Integrate CRT Adjust outside `sys/`: H size/position and V shift, with native synchronization preserved. Use the compatible stage, not a `sys/` patch. Add experimental V size only after measuring its cost and documenting its timing tradeoff.
5. Add high-score persistence only with a valid Sheriff RAM signature and tested pause/restore protocol. Inventory borrowed RAM ports now; do not implement full savestates as a prerequisite.
6. Generate `releases/Sheriff.mra` using the installed MAME version, actual ROM manifest and defined packing. Include `<mameversion>0289</mameversion>`, real button names, short DIP labels, orientation and mod byte. Keep ROM bytes private.
7. Run the **same board RTL** through the bounded attract/play script with all features connected. Compare native RGB frames at boot/attract/play/death/round transition/heart/game-over checkpoints, and require zero unexplained pixel mismatches. Match CPU/RAM/I/O/IRQ checkpoints, not just screen similarity.
8. Confirm the wrapper changes did not alter video cadence, loading/reset behavior or PCM delivery. Run the complete MiSTer **map, fit and STA**, all resource metrics and required corners, on the exact source snapshot.

**Sheriff simulation gate:** real ROM executes from reset into attract and active gameplay; independent movement/aim, both players, scoring, color effects, sound and game over work; deterministic comparisons pass; MRAs/maps are validated; all explained limitations are recorded; current full-shell fit/STA/resources pass. Save commands, logs, mismatched-frame diagnostics (if any) and successful reference images. This is a required gate before any Sheriff RBF.

## Phase 6 — Family expansion after Sheriff

This phase is part of the complete family roadmap. The supplied first `/goal` prompt completes Sheriff and leaves these items explicitly pending; it does not silently mark all games complete.

- **Space Fever:** select the parent ROMs/input layout, add color/monochrome option and red-cannon/UFO behavior, configure three monostables and its sound parameters. MB-07 and MB-11 remain relevant. Do not inherit Sheriff color-mode rules.
- **HiSplitter:** change ROMs/DIPs and validate actual split behavior and sound with parent `highsplt`. Alternate-sound clone `highspltb` is deferred; its differences must not leak into the parent.
- **Space Launcher:** reconfigure controls/color behavior and verify upper-formation kill DAC sound plus interrupt disable/re-enable, MB-02/MB-04. PROM sharing is an emulator reference assumption, MB-10.
- **Bandido:** extract the clone's differing program ROMs from `roms/sheriff.zip`; generate an alternative MRA. Verify its coinage/second coin input and cabinet differences, rather than making another copy of the Sheriff engine.
- **HeliFire:** add color RAM at `c000-dfff`, per-line sea/sky gradient, wave/star LFSR, flash and foreground priority; configure the separate MCU/DAC/envelope board at **5 MHz**. Address MB-01, MB-05, MB-06 and MB-09. Its cocktail limitation must be investigated, not removed by deleting a flag.
- **Computer Othello:** write the M58741P/framebuffer adapter, input selection, coin behavior, independent seven-segment timer and beeper. Resolve MB-12..MB-15 from schematics or measurements. Preserve a MAME-compatible comparison baseline and document evidence-backed hardware corrections separately.
- **Block Fever:** qualify or finish the 8085 donor, including DAA, 8085-only instructions/flags, interrupt masks and timing; a working 8080 alone is insufficient. Implement UPB8212 latches, ADC0800 sample/result/selection behavior, 32x16 tilemap with 8x12 cells, ball registers, PROM graphics, lamps, sound and overlay orientation. Resolve MB-16/MB-17. Both staged 8085 candidates have known limitations; neither is a drop-in qualified core.

Each newly affected profile receives one reused-style capture covering its own attract and gameplay, relevant special effect, and controls. Map after its integration; fit/STA for its distinct clock/memory/data path. Do not rerun all Sheriff CPU diagnostics for a ROM-only profile change. Family completion requires all requested profiles, including Bandido, playable and honestly qualified; unresolved Othello/analog evidence cannot be described as fully corrected.

## Final phase only — RBF assembly, MiSTer testing and release

For each completion scope (Sheriff first, family later), **assembly and hardware tests are its last phase**. An explicit user build request is mandatory. The prepared `/goal` text contains such a request conditional on the Sheriff simulation and fit gates; this preparation turn does not.

1. Freeze a committed, identifiable source snapshot with reproducible generated files and accepted fit/STA/resource reports. Generate build identity without embedding credentials or local ROM data.
2. Enable RBF generation only for the authorized release snapshot. Perform final Quartus assembly after map/fit/STA; reuse the accepted database when the source/settings identity permits it. Inspect the final reports again if any build input changed.
3. Deploy the new RBF and validated MRA using the user's standing MiSTer authorization and local connection configuration. Identify the actually loaded core/build before diagnosing it. Use JTAG probes only if a simulation/hardware discrepancy requires them, observing the shared hardware lock.
4. Test reset/load, attract, coin/start, independent movement/aim, score/death/game-over, both players/cocktail, DIPs, sound, pause/high scores, HDMI rotation/scaling and native analog output. Capture board screenshots and logs. Listen to actual audio; simulation arithmetic alone cannot qualify the external analog experience.
5. If hardware finds a concrete discrepancy, reproduce it in a saved bench/checkpoint, fix the smallest responsible layer, rerun only affected comparisons and the necessary map/fit/STA gate, then rebuild within the explicitly authorized final stage.
6. Write supported-set/controls/status/credits documentation, keep limitations visible, and retain verified release evidence. Keep one primary MRA per game; alternatives under the standard release subdirectories. Follow the [MiSTer contribution requirements](https://github.com/MiSTer-devel/Wiki_MiSTer/wiki/Contributing-a-Core-to-MiSTer-FPGA), including source/license and AI disclosure expectations. Do not publish automatically.

## Efficiency and stop conditions

- Reuse the template, CPU kernels, small RAM/filter/mixer/pause/CRT/high-score modules and one harness. No custom scaler, game CPU emulator, unnecessary sprite renderer or general external-memory subsystem.
- Use fixed finite checkpoints and the first divergent bus event to diagnose. Keep traces bounded; preserve full evidence on disk with hashes.
- Convert VHDL once per pinned donor revision; both synthesis and simulation must use the same qualified semantics. Do not substitute a different CPU in simulation to make frames match.
- Map at meaningful edit batches; fit when the timing/resource risk changes, not after every comment. Never skip early fit, sound fit, final integration fit or a new-clock fit.
- Do not launch emulator windows during unattended baseline collection. Use headless/no-video capture when the required API supports it.
- Declare completion only for the scope that passed its gates. A staged donor, successful CPU fetch, attractive screenshot or generated RBF is not a completed game.
- The preparation stage is complete. The active Sheriff implementation goal continues through the complete simulation and authorized final-source timing/resource/release gates; preparation artifacts alone are not its stop condition. Quartus remains on hold until the user explicitly resumes it.

## Full-wrapper coin/start evidence (2026-10-09)

The saved full-wrapper source 27436ef947949a4e completes one 780-field board-profile/seed-1 simulation with actual exit 0 and all 51 HPS operations finished. Ordinary Coin/Start inputs reach the real CPU with MAME-matching read counts; credited field 360 and GET READY field 720 each match all 57,344 native RGB pixels exactly. See docs/evidence/sheriff_wrapper_inputs.json and progress.md. The short scenario does not qualify subsequent gameplay, movement/aim, shot execution, all graphics, persistence or hardware. Reuse this evidence rather than repeating boot. The next fidelity work remains physical video/CPU clock phase and the earliest long-gameplay divergence. The Quartus hold and all final simulation, exact-source timing/resource and release gates above remain in force.

## CPU clock waveform correction (2026-10-09)

The related-Bandido connected clock-network derivation replaces complementary CPU gates with non-overlapping level enables. See docs/HARDWARE_VIDEO.md, docs/evidence/sheriff_clock_network.json and docs/evidence/sheriff_cpu_phase_qualification.json. Architectural, cadence, RAM-service/pause and the six captured short-ROM RGB fields pass. PLL, raster and IRQ edges are unchanged; exact Sheriff net identity, absolute CPU/pixel phase, electrical delays and the 9.920635 ns phi2 sampling error remain explicit.

Next, reuse the built executable and existing MAME third-round capture for one focused run through frame 2400, with completed-field bus windows 2398 and 2399. Capture preceding opcode fetches and interrupt entry; diagnose the first difference before extending to later corners. Do not reuse old complementary-waveform IRQ offsets or saved full-wrapper qualification as current-source passes. Continue serializer/DRAM/READY derivation. Fresh exact-source fit/STA/resources are required once the user resumes Quartus; the hold remains in force.

The partial connected serializer/READY derivation is now recorded in docs/evidence/sheriff_video_control_network.json and docs/HARDWARE_VIDEO.md. Use the gate predicate and exact S0/S1 pins when reconstructing the 4F/4G DRAM read-latch and RAMSTB/RDY IN schedule. Do not substitute a visible-x modulus or permanently-high READY based on this partial derivation. The single immutable first-corner replay is under _checks/physical-cpu-round2400-20261009; read its terminal receipt before extending or repeating it.


## Per-profile controls and display acceptance

For Sheriff and each later implemented family profile, require function-named OSD/MRA controls, the actual cabinet service/test input only if present, all physical DIP positions with correct function names/settings/polarities under DIP switches, Normal/V-Integer/HV-Integer modes, native-refresh derivation, applicable CRT geometry, HDMI CW/CCW and native 180-degree flip, and OSD-triggered high-score save/restore. Compare direct-video, analog and Y/C integration against upstream platform/arcade examples, then verify actual output stability and sync on hardware. Do not infer an output pass from source support or a successful compile.

Sheriff source and scoped simulation audit: docs/DISPLAY_FEATURES.md and docs/evidence/sheriff_display_features.json. Physical sync/output qualification, CRT vertical size and fresh exact-source fit/STA/resources remain open. Existing Sheriff-first ordering, simulation gates, Quartus hold and explicit RBF authorization requirements remain authoritative.

## First third-round corner result (2026-10-09)

The focused cb67879-source run through field 2401 is complete, exit 0. All 45 captured fields match the reused MAME-write oracle exactly; field 2400 no longer differs. docs/evidence/sheriff_clock_round2400.json independently predicts the preceding ANA A interrupt boundary and records the RAM clear moving before the pixel sample. Raster/IRQ edges and scanout were unchanged. This completes the previously requested first-corner replay; do not repeat it.

Next, investigate later restart corners under the corrected waveform, with completed-field bus windows 2758/2759 and 6778/6779 in the next necessary replay. The immutable model qualifies its saved-source scope. Preserve concurrent display/flip edits and obtain current-source qualification before full integration/release claims. Continue physical DRAM/serializer derivation; full graphics/audio, current wrapper and exact-source Quartus gates remain open. Quartus remains on hold.

The corrected related-Bandido readback controls are recorded in `docs/evidence/sheriff_ram_handshake.json`: 4F Q2 feeds D1; HREAD_n XOR Q2 clocks the latches, producing flags 00 -> 01 -> 11 after clear. RDY IN rises after the second capture. Complete the asynchronous CLR/READY coupling and RAS/CAS/WE/address/valid-data schedule before integrating this sequence or the video serializer. Functional capture count alone does not specify CPU waits or a production RAM sample phase. Quartus remains on hold.

RAM mux/data/strobe connectivity is recorded in `docs/evidence/sheriff_memory_mux_connections.json`: CPU addressing retains 14 bits, video selects the lower 8 KiB through the physical H/V bus, and RD buffers DO with an R4 pull-up rather than phase blanking. Reconstruct upstream write qualification and raw CP2 clock/counter phase next; the projected byte index alone does not determine a safe serializer load edge.

The corrected-clock saved-model restart field2760 still differs by one pixel; see `docs/evidence/sheriff_clock_restart2760.json`. Native and MAME now save the same IRQ return PC 0x2175. Preserve the negative graphics gate and inspect instruction epoch plus physical READY/DRAM/serializer timing; do not carry the old wrong-return-PC cause forward or compensate the raster/write oracle. The unchanged 6781-field run continues; read its actual terminal receipt before claiming completion or launching a replacement.

Write qualification and relative raw RAM-control equations are now traced in the memory mux report: WE is enabled only by CPU column-phase/A14/write qualification; raw CAS_n=NOT 4A QB, RAS_n=4A QB AND 4A QD, and COMADR_n=NOT 4A QG. Reconstruct the 4A data/clock and counter reset/initialization schedule, then derive valid read/write and READY/serializer edges without assigning a visual offset to remove the remaining pixel.

## 2026-10-09 conditional RAM phase implementation
The isolated `n8080_memory_phases` primitive now models 2A -> 3B/4I and 4A with clock enables, including pre-count QB capture. Its closed-form Verilator qualification passes 16,000 samples; evidence is `docs/evidence/sheriff_memory_phases.json`. Reuse it rather than re-deriving the relative raw signals. Before board integration, establish actual CPU WR RD/RAMSTB generation, the DRAM-valid window and serializer clock/load/READY ordering. Qualify exact CPU/raster origin separately; do not select a phase to erase the remaining field2760 pixel. The primitive has an artificial reset origin and conditional ENP timing. Quartus remains on hold.

RAMSTB_n generation is now traced and Boolean-qualified as NOT(A14 AND SYNC AND NOT phi1_TTL), with source pins in the memory mux report. Reuse this status-pulse clear when completing READY/readback integration; do not substitute a latched MEMR level. CPU WR RD generation, physical valid-data/serializer timing and phase origin remain open. Quartus remains on hold.

The corrected-clock 6,781-field restart replay is terminal, exit0. Field6780 now matches the MAME-write oracle with matching native/MAME IRQ returnPC0x0a06; evidence is docs/evidence/sheriff_clock_restart6780.json. Reuse its terminal observers. Diagnose the remaining field2760 instruction-epoch/one-pixel discrepancy before another long campaign or release claim; preserve the current source distinction and physical RAM/READY/serializer work. Quartus remains on hold.

The remaining restart pixel now has upstream field2758 IRQ/epoch evidence in docs/evidence/sheriff_clock_restart2758_epoch.json: native/MAME stack0x0590/0x05a0 across JZ, with explicit local -125 ->+125 clock epoch change after the ISR. Diagnose the next mid-screen boundary and upstream pre-edge instruction phase using existing terminal observers; do not treat field2760 matched final CALL return as global IRQ agreement. Untaken conditional operands absent from MAME taps are source-explained, not missing native accesses. Quartus remains on hold.

The two-field restart epoch trace is now complete: all13,372 reference accesses are accounted for with three explicit stack-verified IRQ reorderings and source-proven untaken operands. The first mid-screen event reproduces a one-T-state backdated MAME interrupt (MB-18); it does not establish the earliest vblank phase cause or qualify the remaining pixel. For the next necessary replay, add leading bus/reference window2757 to inspect the field2758 vblank boundary; reuse the immutable corrected-clock ELF and frozen input stream. Physical RAM/READY/serializer integration and current-source qualification remain open. Quartus remains on hold.

Reuse the now-qualified isolated n8080_ram_readback primitive and n8080_memory_phases for the derived pin logic; do not recreate their function tables. Before board integration, complete CPU WR RD generation, DRAM-valid/serializer sample ordering and absolute phase/propagation. The primitive qualification does not supply CPU wait counts. Quartus remains on hold.

Matching leading MAME opcode data for field2757/2758 is prepared and transaction-prefix qualified in docs/evidence/sheriff_prior_vblank_reference.json. Its original capture runtime exit remains unknown; do not label it a runtime pass. Use the new tools/mame_capture.ps1 -WaitForExit option for future reference workers and retain the original process handle rather than reacquiring it with Get-Process. Reuse this prefix data when the immutable native2759-field replay reaches the needed window. Quartus remains on hold.

The2759-field leading replay is complete, exit0. Direct ANA A/JZ fetch qualification and9,156 exact overlapping bus rows are in docs/evidence/sheriff_prior_vblank_boundary.json. Native sampling at this vblank matches the independent local ISA/clock prediction. The125-clock gap exists before ANA A, so do not fix this boundary with raster/CPU offsets or repeat its replay. Prefer finding the earliest RAM/IRQ checkpoint difference in existing full traces before requesting another long prefix. Remaining field2760 graphics, hardware memory timing and exact current-source gates remain open. Quartus remains on hold.

### First ordered RAM difference and resumed timing checks (2026-10-09)

The first23,193 native/MAME writes agree. The next saved return-PC difference occurs at field66, before the field2758 epoch gap. Direct67-field capture and independent local prediction are in `docs/evidence/sheriff_first_ram_boundary.json`; both capture exits are0 and all relevant new streams are exact prefixes of existing completed traces. Native/MAME instruction epoch differs by about50 clocks before ANA A. Absolute boot/raster phase and electrical memory behavior remain open. Trace the origin using the initial CPU/reset schedule and independent hardware evidence, rather than adjusting reference/raster times or requesting another long prefix.

The Quartus hold is lifted. The shared queue rejected the no-assembly job before starting a compiler; no Sheriff preassembly recipe is currently registered. See `docs/QUARTUS_PREASSEMBLY.md` for the exact requested snapshot and admission requirement. Do not retry the unchanged submission or weaken assembly/resource gates. Fresh exact-source map/fit/STA remains required once an independently reviewed recipe is available.

### Reset-origin projection audit (2026-10-10)

Initial MAME fetch0 versus native T1 tag50 is directly observed and the saved-model reset-gate sequence is explained in `docs/CPU_PHASE_ORIGIN.md`. Its source gate model matches78 native pin samples, uniquely identifying counter phase7. Earlier +19 offsets from the tag for final phi2 were incorrect; the corrected saved-model offset is12. Field66 evidence is updated; preserve measured ACK/stack data and do not rerun completed replays to correct a label. Other historical derived phi2 fields require this correction before reuse. Continue hardware RAM/READY/serializer and explicit timing-origin/equivalence work; this diagnostic does not authorize a reference offset or waive the field2760 pixel.

### Current-source boot regression (2026-10-10)

`docs/evidence/sheriff_current_board_boot.json` closes the current board boot/attract regression at factory inputs/user flip off:106 fields exit0, six captured RGB images exact, startup/I/O/RAM/digital sound byte-identical to the saved corrected-clock model. Reuse the retained `_checks/current-board-boot-20261010/Vn8080_board` and frozen restart journal for the next necessary current-source gameplay/corner scenario. The harness now drives flip_screen explicitly. Do not rebuild/replay this completed boot scenario unchanged. Full-wrapper, gameplay/cocktail/flip/audio, physical memory timing and current timing/resources remain open; this scoped result is not the release graphics gate.
## Current sound investigation checkpoint (2026-10-10)

Latest physical-video update: connected joins establish high-blank TP4/TP5
HB/VB and complementary5T active inputs. Corrected the serializer polarity
and added the4J/4G horizontal reload network. Joined actual native component
build/test exit0 observes320 clocks per period (256 active/64 blank),1280
counter pixels and128 held-byte loads; source-derived first-byte pipeline
is eight counter clocks. See `docs/evidence/sheriff_horizontal_network.json`
and `sheriff_horizontal_video_path.json`. Blocks remain outside production.
Next derive vertical enable, actual flip-latch mapping and PROM/RGB/analog
visible gating, then integrate full memory/readback/READY/serializer. Keep
physical RC/order/reset and exact Sheriff applicability explicit. Reuse the
completed component and its preserved failed-bench receipt; no load/time
offset, field2760 waiver or timing/resource pass follows.

Current physical-video progress: `docs/evidence/sheriff_dram_cycle_edges.json`
derives C2 row -> C3 column -> pre7 serializer loading from the connected
counter/delay/gate network, with CAS four crystal periods before loading.
The common serializer/counter clock is traced across the joined drawings.
`rtl/n8080_video_path.sv` now connects the qualified198 register, mode gates,
pin ordering and end selection; native build/test exit0 is bound in
`docs/evidence/sheriff_video_path.json`. It remains outside board/files.qip.
Next derive horizontal reload/blanking/origin and the physical flip-latch
mapping, then integrate DRAM address/readback/READY and held-byte scanout.
Do not fit a load offset, treat nominal DRAM access as PCB setup/hold, rerun
the completed isolated streams or waive field2760. The complete graphics
and production-source fit/STA/resource gates remain open.

The receipt-backed SN chip replay completes with actual exit 0 and reproduces
all 937,008 old full-board SN samples exactly; see
`docs/evidence/sheriff_sn_gameplay_replay.json`. The corrected gain conversion
leaves 2,286 differing reference-residual samples, including a directly
observed Q32/binary64 gain-index boundary and a larger second-burst phase
difference. `docs/evidence/sheriff_sn_control_sampling.json` records predicted
trigger/expiry sample positions. The source-equation prediction now matches
all 936,961 reference PCM samples across all five separated mono1 bursts,
while an independent Q32 shadow exactly matches the actual current native
chip. Only two samples differ between native-timed binary64 and Q32, both
gain-index arithmetic boundaries; the large differences arise from control
sampling. See `docs/evidence/sheriff_sn_control_waveform_all_mono1.json`.
Do not repeat this completed finite diagnostic or add a fitted delay. Next
cover mono0/overlap and other actual sound classes with meaningful gameplay
events, and continue physical clock/memory/video derivation. This closes
the recorded-write component case only. Full current integrated audio/game
execution, physical video/IRQ/DRAM timing, lifecycle and exact-source queued
fit/STA/resources remain required. Quartus permission is restored; historical
hold notes above are superseded. No assembly until the final authorized gates.

### Current prerequisite: resolve the vertical extension contradiction (2026-10-10)

Before integrating the physical horizontal/vertical/serializer path, resolve `docs/evidence/sheriff_vertical_network.json`: the naive extension of the tested horizontal equations wraps the drawn eight-bit vertical counter after 128 lines while the Sheriff reference has 256. QA feeds V0, so dropping a vertical bit is not supported. Recheck the connected horizontal reload, carry, enable and clock event interpretation; derive the blanking and actual flip latch from primary drawings. Keep the isolated horizontal qualification conditional. No arbitrary divisor, reference shift, or full raster qualification follows from its 320-pixel period. Then use the existing captures to test the first affected divergence; avoid replaying unchanged completed campaigns. Quartus preassembly/resource gates remain required and currently UNKNOWN pending the registered Sheriff queue recipe.

### Mixed sound classes and receipt recovery (2026-10-10)

The existing 1201-field sound recording covers only five separated mono1 bursts. `docs/evidence/sheriff_sound_control_coverage.json` locates mono0 cancellation and mono1 overlap in the saved native cocktail capture, and two mono1 retriggers in the longer MAME recording. The focused native prefix completed 1,439,875 samples with byte-identical old-gain SN output and identical capacitor states, but lost its OS exit receipt; `docs/evidence/sheriff_sn_mixed_gameplay.json` therefore retains a functional diagnostic with qualification false. Do not rerun that unchanged prefix solely to repair observation. Next compare the mixed-class/retrigger waveforms against the existing longer MAME WAV using the independent source equations and actual control times. Keep whole-audio and full-gameplay gates open. Future required native cases invoke `tools/run_native_with_receipt.sh` explicitly through Ubuntu /bin/bash to persist the child exit code; its zero/seven exit cases are recorded in `docs/evidence/native_exit_receipt.json`. A native end-result cannot substitute for an observed OS exit at a release gate.

### Mixed sound model checkpoint and next integration decision (2026-10-10)

`docs/evidence/sheriff_mixed_sound_checkpoint.json` closes the independent source-equation investigation for all mixed/retrigger classes in the saved WAV: source setter order plus one uniform lower DAC timestamp bound explains all 12,482,881 samples. Both analysis jobs have actual OS exits 0 and unchanged source bindings. The generalized Q32 shadow also matches the existing 1,439,875-sample native mixed prefix. Retain the nominal-index 4,553-sample negative, atomic-control 648,385-sample negative, and original missing native OS receipt; none is repaired or waived by this analytical result. Do not rerun these unchanged completed campaigns.

Before a sound RTL correction, resolve the 26 additional reference envelope restarts from MAME sequential stop/start setters versus atomic native timers. The related Bandido 74123/diode drawing is staged; actual Sheriff signal polarity and enable propagation are unqualified. Obtain exact integer reference timestamps in the next otherwise-required capture, rather than performing another unchanged capture solely for this diagnostic. Implement only the resulting justified control/envelope change, then run its focused native/integrated comparison and the required queued synthesis/fit/STA/resource checks. The core audio gate remains false; physical raster, first graphics divergence and complete gameplay gates remain required. See the MB-08 update in mamebug.md and docs/HARDWARE_SOUND_ENABLE.md.

### Reused P1 lifecycle evidence and current main-source bridge (2026-10-10)

`docs/evidence/sheriff_gameplay_source_bridge.json` proves that the current main board with `flip_screen=0` specializes byte-for-byte to the completed cb67879 board; current CPU wrapper/kernel hashes match the saved model. Only the added user-flip input and its two scanout coordinate XORs distinguish the board sources. This is a main-board projection claim, not current complete-wrapper or changed-sound qualification.

`docs/evidence/sheriff_gameplay_lifecycle.json` reuses the actual 6,781-field terminal replay: all117 shared control-RAM6000..603f snapshots match restart-MAME exactly;53 whole-RAM snapshots match, and all other differences remain recorded. Native ROM-rendered HUD demonstrates attract, coin/start, score increases, life losses3->2->1->0, full GAME OVER at6060/6120 with score/highscore0330, and ordinary coin6200/start6290 restart with3 lives and retained highscore at6780. Field6000 is a transient partially drawn GAME O message, not the stable game-over checkpoint. No CPU/RAM state was forced and no native campaign was rerun.

Do not repeat this unchanged P1 lifecycle. Remaining simulation work includes the first physical graphics/IRQ/memory divergence, cleared-round/color effects (the qualified ordinary-input reference first sends red control14 at11302), and the exact current complete wrapper/changed sound through the required lifecycle and two-player sequence. Keep full gameplay/graphics/audio and resource/timing gates false; the source bridge does not waive any saved pixel, RAM or clock/propagation negative.

### Saved RAM chronology prerequisite (2026-10-10)
Reuse docs/evidence/sheriff_lifecycle_ram_boundaries.json: all300 native differing-byte observations agree with their logged writes, while15 reference observations lead their logged writes. Address6856 at6240 anticipates its reference write by about50 master clocks. Do not use frame RAM dumps as physical bus-time equivalence or waive graphics/IRQ differences. Include integer seconds/attoseconds and common callback sequence IDs in the next otherwise-required capture; preserve existing payloads and diagnose the first graphics divergence. Additional original family manual provenance is in sheriff_maintenance_manual.json; physical raster remains unqualified.

### Exact reference observations available (2026-10-10)
The new optional -ExactObservations capture sidecar is qualified by a4-field real Sheriff run, with original payloads unchanged and exact callback chronology preserved. Use it with -SoundProbe when needed in the next otherwise-required scenario. docs/EXACT_REFERENCE_OBSERVATIONS.md and sheriff_exact_capture_observations.json explain the observed backward timer/device timestamps. Preserve original captures; the sidecar is neither a physical bus model nor a graphics mismatch waiver. Do not repeat its completed short test.

### First IRQ divergence and next origin check (2026-10-10)
The actual short68-field native/exact-reference diagnostic locates the first return-PC split at66, after82 matching IRQs. The reference LDA/ANA epoch is50 master clocks earlier; it executes JNZ before IRQ while native services IRQ after ANA. See docs/FIRST_IRQ_BOUNDARY.md and sheriff_first_irq_boundary.json. Next resolve initial CPU/video/reset origin from startup clock evidence before changing phase or integrating an unqualified physical raster. Reuse this case; no ANA flag correction, arbitrary offset, field2760 waiver or unchanged long replay follows. Full current integration/audio/gameplay and timing/resources remain required.

## Field66 phase projection correction (2026-10-10)

The completed reset audit already accounts for the native startup observation origin. Reuse it rather than creating another reset bench. The newer first-IRQ report now binds that audit and projects final ANA phi2 at IRQ+12 (tag phase7, final phi2 phase19), preserving RST tag+25, ACK+27 and stack writes+194/+269. This is a diagnostic correction, not grounds to shift CPU/raster phase to MAME time0. Next qualify actual raster/IRQ and RAM/READY/serializer timing, retaining the field2760 graphics failure and current integrated audio/gameplay/fit gates. Evidence: docs/CPU_PHASE_ORIGIN.md, docs/FIRST_IRQ_BOUNDARY.md and docs/evidence/sheriff_first_irq_boundary.json.

## Current-source gain integration completed (2026-10-10)

The real current bare-board/8080/8035 execution through1201 fields has actual native and workflow exit0. Its937008 audio samples all match the independently retained old/current SN component delta plus unchanged DAC;25485 samples change. All four digital journals and25 RGB/25 RAM snapshots are byte-identical to the prior source. Current/snapshot source closure, ELF, runner and all report artifact hashes verify. Evidence: docs/evidence/sheriff_current_gain_integration.json and _checks/current-gain-integration-20261010/independent-artifact-verification.json. This closes the scoped gain-ROM integration check only: full-wrapper audio, mixed hardware enable/retrigger, Q32/reference recording assumptions, later lifecycle/color/graphics and final fit/STA/resources remain open. Preserve old waveform negatives and reuse this completed run unchanged.

## Monorepo timing snapshot preparation (2026-10-10)

Use tools/prepare_timing_snapshot.ps1 with the canonical core ProjectRoot for pure source preparation. It archives the committed cores/sheriff subtree at the snapshot root, scopes dirty checks to this core and records source/archive/flow hashes. The tested9538653d8c36 snapshot has every tracked file matching its Git blob after only the exact committed CRLF materialization where declared, with actual archived SHA256 recorded and the complete framework present; no other core or local ROM/donor/environment data is included. GENERATE_RBF_FILE remainsOFF and the staged Tcl performs only map/fit/STA. This is a prepared compiler input, not compiler admission or a timing/resource pass. An independent reviewed Sheriff preassembly recipe remains required; do not repeat the historical unsupported submission. Evidence docs/evidence/sheriff_quartus_snapshot.json.
