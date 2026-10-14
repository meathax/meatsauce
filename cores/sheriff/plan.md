# Sheriff-only MiSTer — completion plan

Updated 2026-10-10. This plan supersedes the former family roadmap and its historical next actions. Record completed work, source identity, actual exits and recovery paths in `progress.md`.

## Sole target

Support **Nintendo Sheriff, MAME 0.289 parent `sheriff`, only**. Deliver one playable Sheriff core and `releases/Sheriff.mra`. Bandido and every other clone/game are excluded permanently from this project’s scope; there is no later family phase. Existing related-board documents and donor code remain references where they actually support Sheriff. Their preservation does not require implementing those games.

Use the real parent ROM on the same synthesizable 8080/8035 RTL in Verilator and MiSTer. Keep existing project/module filenames while they serve Sheriff; renaming the Quartus project during an active check adds no gameplay progress. The final public package/menu must identify Sheriff and offer no other-game selector or MRA. Remove reachable unused profile dispatch only when needed for that package, without broad refactoring or deleting useful research.

## Current critical issues

| Issue | Known evidence | Next decisive action |
|---|---|---|
| First CPU/IRQ difference | On the retained pixel model, 23,193 ordered RAM writes match before field 66 saves native `0ff3` versus reference `0fef`. Later field 2760 still has a one-pixel failure. | Fix the responsible supported CPU/IRQ/READY/memory connection; compare field 66 first, then extend that same executable to fields 2758–2760. |
| Production memory wiring | Actual storage/readback/READY passes five synthetic origins. CPU_WR_RD generation remains unresolved; direct grafting also breaks pause cadence and current video/hiscore ownership. | Resolve the missing source input and implement the minimal service bridge in `docs/DRAM_INTEGRATION_REQUIREMENTS.md`. Constant-1 stimulus is not a production equation. |
| Timing | Pinned `66f53ed9` passes all seven resource limits, but all-corner setup is −0.008 ns. | Finish the existing isolated SEED 2 placement trial and endpoint review. Preserve the baseline; use the hardened corner checker. Repair measured failures before further changes affecting their paths. |

Capture origins and hardware assumptions remain explicit. `docs/COMMON_ORIGIN.md` explains different reset/event semantics; it does not authorize a 50-clock shift. `docs/FIRST_PIXEL_CAUSAL_PATH.md` supersedes the older local `2178` return diagnosis; the newer local IRQ returns `2175` on both sides. Do not invent an origin, align callbacks to pass, waive pixels, or import related Exidy color timing without Sheriff applicability.

## Fast execution sequence

1. **Close the first divergence.** Reuse qualified CPU kernels, IRQ integration, DRAM storage, READY/readback, counters and serializer evidence. Implement only the remaining supported Sheriff connection. A focused regression must demonstrate the former failure and corrected behavior. If a necessary net cannot be established, state its exact missing input and switch to an independent open requirement; do not repeat inconclusive schematic crops or unchanged boot runs.
2. **Extend the same native run to complete gameplay.** Reuse the frozen P1 restart, P2 cocktail and round/color fixtures in `docs/SIM_ACCEPTANCE_COVERAGE.md`. After field 66 passes, extend to the pixel corner, later rounds and the recorded red command at field 11302/checkpoint 11340. Use ordinary controls, never forced game RAM, registers or CPU state. Collect RGB, CPU/RAM/I/O/IRQ and sound together. Require zero unexplained graphics mismatches against comparable deterministic MAME 0.289 observations.
3. **Close sound on that source.** Keep real 1 KiB 8035 ROM execution, persistent command IRQ, T0/T1, P1 wiring, P2 DAC and connected SN76477/74123 functions. Reuse the passing gain corpus and 1,439,875-sample connected audio result; do not duplicate them. Complete shot/hit/death/tune, overlap/retrigger, pitch/envelope, mix/clipping and pause checks using `docs/AUDIO_COMPARE_CONTRACT.md`. Preserve the 132 source-ordered versus 106 atomic restart difference until connected evidence resolves it. State analog/noise assumptions; do not insert an invented disable pulse or fitted sample delay.
4. **Finish the current Sheriff wrapper and package.** Qualify changed behavior using the smallest fixture set below. Reuse unchanged HPS download/input and completed component evidence. Deliver only the Sheriff MRA, menu and release package. Close every Sheriff-applicable entry in `mamebug.md`, retaining justified limitations rather than claiming uncertain hardware is corrected.
5. **Pass exact final-source timing/resources, then the final authorized build/hardware phase.** Preserve source, fixture, tool, report and executable identities. Final assembly requires an explicit user build request after simulation and timing/resource gates pass. `GENERATE_RBF_FILE` stays OFF throughout development. Hardware testing is last.

Run independent work in parallel: CPU/video/memory fidelity, timing/resources, and remaining audio/wrapper acceptance. The parent integrates shared documents and commits. Keep agents on disjoint files; reassign completed agents to the next Sheriff requirement. Do not create abstractions, donors, tests or research solely for other games.

## Complete simulation gate

All acceptance evidence must cover identifiable current synthesizable RTL, real parent ROMs and the declared input/DIP fixture. Earlier narrow passes retain their original scope.

- Boot/HPS download/reset, attract, coin/start, genuine P1 and P2 gameplay, independent movement and eight-direction aiming, fire/hits/scoring, deaths, round/color effects, game over and restart.
- Lives/cabinet DIPs, cocktail and user flip; keyboard, second-stick and rotary aim; correct orientation without double rotation.
- Native 320×256 raster with active X0–255/Y16–239, bitmap/PROM/color modes, portrait ROT270 and 3:4 aspect; HDMI scaling/rotation/integer/crop, native analog/direct video and CRT horizontal geometry/vertical shift. Experimental vertical sizing is not an added completion requirement.
- Real mixed sound, coherent CPU/audio/video pause/resume, working high-score signature/save/restore with safe RAM ownership, guarded gamma after a complete LUT upload, and correct menu visibility.
- Sheriff MRA `mameversion` 0289, manifest packing/CRC/sizes/padding/region order, buttons/DIPs/orientation/mod byte; no other game or clone included.

No screenshots, prerecorded frames, ARM emulation or simulation-only CPU behavior substitute for this gate. Unexplained graphics differences and unknown producer exits fail it. Any MAME correction needs specific source/hardware evidence; unrelated failures remain open.

## Continuous timing and resource gate

Use Quartus 17.0.2 at `D:/q17/quartus/bin64`. Direct check-only map/synthesis/fit/STA is allowed unqueued. Full compile/ASM/CPF/RBF uses the shared FIFO with at most two full jobs and requires applicable build authorization; never raw `quartus_sh`, `quartus_asm` or `quartus_cpf`.

Run analysis/synthesis after meaningful RTL batches; full-framework fit and all-corner TimeQuest after clock, RAM, critical-path/routing or substantial integration changes, and on exact final source. Combine concurrent reasons into one check. Documentation/comments and unchanged accepted snapshots do not justify recompilation. Reuse a valid synthesis database for a placement-only experiment; one trial is not permission for a seed sweep.

Require nonnegative setup/hold, recovery/removal and minimum pulse-width results at every applicable operating condition, complete per-corner measurements, constrained game clocks and no unexplained unconstrained board paths. `tools/timing_corner_gate.py` rejects missing checks; review real external-interface roles and exceptions rather than adding blanket false paths. A successful process exit or default-corner pass is insufficient.

| Resource | Hard limit |
|---|---:|
| Logic ALMs | <80% |
| Partially/completely used LABs | <90% |
| Peak interconnect, max(H,V) | <85% |
| Average interconnect | <60% |
| M10K blocks | <90% |
| Block memory bits | <85% |
| DSP blocks | <90% |

`config/resource_limits.json` is authoritative. Record actual used/available counts and interconnect metrics; missing measurements fail. Keep one 50.4 MHz Sheriff master plus enables; document required framework clocks separately. Optimize measured timing failures or limited headroom, not already-small resource counts. Baseline utilization is ALM26.24%, LAB41.80%, M10K22.42%, bits15.17%, DSP30.36%, peak29.8%, average10.8%; these figures cover pinned production source, not future integration.

## Implementation constraints and reusable evidence

- Keep `sys/` untouched. Board RTL is outside it, selected through `files.qip`. Preserve the 16 KiB CPU-visible RAM window, 8 KiB bitmap, main/sound/PROM packing and qualified clock-enable/IRQ behavior.
- Reuse `docs/CPU_IRQ_ACCEPTANCE.md`, `docs/CPU_RESET_ACCEPTANCE.md`, `docs/CPU_DRAM_SERVICE.md`, `docs/DRAM_STORAGE_INFERENCE.md` and the source-bound evidence they cite. Storage physical DUAL_PORT inference is acceptable; there is no extra SINGLE_PORT requirement.
- Source-supported RAM integration must preserve ROM/INTA/I/O priority, pause-safe memory cadence, dynamic video capture, timed hiscore/debug ownership and CPU readback restoration, cold initialization/warm retention and transaction cancellation. Keep unknown CPU_WR_RD explicit.
- Reuse `docs/COLOR_CLOCK_APPLICABILITY.md` and connected video evidence. Primitive qualification is not proof that related-board wiring applies to Sheriff.
- Preserve applicable donor notices/credits in `donormap.md`; reject the noncommercial DK wrapper. ROM bytes, credentials and local configuration remain ignored. Linux/ELF tools run explicitly in Ubuntu WSL.

## Final build, MiSTer and release

After the complete simulation and exact-source fit/STA/resource gates pass, obtain/use the explicit final-stage build request. Assemble through the shared queue, retain RBF/MRA/build identities, then deploy and test with standing MiSTer access authorization and local configuration. Verify the actual loaded image, both players/aiming/lifecycle, DIPs/flip, sound, pause/high scores, HDMI and native outputs. Fix concrete hardware discrepancies with focused simulation and necessary timing checks before an authorized rebuild.

Completion means the verified Sheriff release, actual hardware acceptance, reproducible commands/evidence, licenses and honest limitations. No other-game roadmap is a deliverable. No push/publication without instruction.

## Efficiency rules

Use bounded reads and the first failing window. Reuse captures, checkpoints, donors, converted kernels and unchanged passing checks. Build once per relevant source change and extend the same executable. Stop broad work at the first unexplained failure. Preserve failed receipts; never restart a live job because observation timed out. Consult relevant indexed lessons only when needed. Commit coherent owned paths and keep `progress.md` current.
