# Alpha68k N progress

## 2026-10-10 — Cocktail terminal qualified; earned reset timeout diagnosed

Parent92f89da. Original cocktail process6770 completed1801 fields exit0 in
3746.866s. New bounded `scripts/verify_kyros_feature_terminal.py` verifies
every applied port/source pin, field sequence, full unique pixels and renderer
metrics, actual Player2 actions and exact1140 RGB/sprite/work RAM. Finite
feature checks pass;62/64 canonical images exact. Retain atomic differences
60=20745 pixels and900=4; full graphics acceptance remains false. Evidence:
`research/kyros_cocktail1801_v2_native_{exit,feature_terminal}.json`.

Current real-HPS earned wrapper7814 finished901 fields but exited1 in
2539.111s: reset/readiness was not observed within1000*20000 ticks. Real
upload saved178 bytes, best00002000, after the actual host's RAM equality
assertion. No synthetic fallback. Finite full-protocol pass remains false;
original field60/900 differences and missing119/179 wrapper images retained
in `research/kyros_earned_wrapper901_v2_feature_terminal.json`.

`sim/mame/probe_earned_reset.lua` and `scripts/probe_earned_reset.py` run
only legal actual CPU gameplay then soft reset with read-only observations.
Official pinned MAME exits0,1041 fields, all six checks true, exact901 input
prefix and actual BCD2000. Score clears at reset+57, zero plus readiness
at+69; failed wait covers only24.660669 fields. Evidence:
`research/kyros_earned_reset1041_{job,exit,verification}.json`. Genuine
hiscore.dat matches the configuration. Do not patch production reset/RAM,
lengthen blindly without observations, or claim a native reset pass.

Prepared and launched `scripts/prepare_earned_wrapper_v3.py`: preserve original sources
and jobs; derive only6000-step wait and read-only reset journal in a distinct
namespace. Earliest actual MAME earning895 makes901 the useful stable
prefix. Private v3 build exits0; actual simulation11163 is live with5 observed
fields, worker10925, launcher Windows WSL27212. Private executable SHA256
030131b18194d703fdb44e54fca8225239aada679c7c62663204f480fe10330f;
`research/kyros_earned_wrapper901_v3_{launcher,job,build_exit}.json` and
`research/kyros_earned_wrapper_source_v3.json` preserve ownership and pins.
Python syntax and git diff --check pass. Next follow this actual HPS replay to terminal,
then require actual reset-zero and exact saved/reloaded178 bytes. No duplicate
cocktail, production RTL change, Quartus invocation or RBF assembly here.
Docs `COCKTAIL_ACCEPTANCE.md` and `EARNED_SCORE_ACCEPTANCE.md` distinguish
finite feature coverage from original graphics and full-core gates. User
has resumed queued Quartus use; strict complete-design resources/timing
and conditional final RBF/hardware gates remain pending.

## 2026-10-10 — Actual native Player2/cocktail1140 has exact full RGB and RAM

Parent21b4ba3. Same real combined CPU process6770 remains live at42:21,
1186 fields. After legal two-player start, natural Player1 death and MAME's
observed cockpit flip, native1140 matches all57344 MAME pixels, all8192
sprite bytes and all4096 work bytes exactly. No differences, masks, shifts,
state injection or production RTL change. Receipt:
`research/kyros_cocktail1801_v2_native_player2_1140.json`. This qualifies a
finite actual player-turn/cocktail case, not the still-pending full1801 run
or continued Player2 actions.

An accepted late flip timestamp is not retained by this older host: bus.csv
is sample-capped; epoch_events covers IRQ/backdrop/HUD and excludes late MCU
writes. Inspected actual stream/filter; no timestamp or missing-hardware-flip
claim is invented from that gap. Exact full RGB/RAM evidence remains valid.
Updated `docs/COCKTAIL_ACCEPTANCE.md`; continue the same native and earned-score
wrapper handles to terminal, then qualify all required outcomes and failures.

## 2026-10-10 — B13/B14 sound address usage audited from existing capture

Parent60eef46. Added `scripts/audit_sound_address_usage.py`, one bounded-output
pass over the existing complete3600-field actual MAME combat event stream.
Verified frame sequence/completion and the exact port hash used by native
combat3301. Lower1KiB has2325198 writes/1991777 nonzero; upper1KiB has exactly
one zero write per address (1024 total), no nonzero or repeated-address writes.
All documented ignored ports e006/e008/e00a/e00c/e00e receive writes; counts,
values and field bounds are retained. Eight known virtual alias-pair value
differences do not prove both bytes are read or prove PCB capacity/wiring.

Receipt: `research/kyros_sound_address_usage3600.json`. Updated B13/B14 in
`docs/bug_coverage.json`, `mamebug.md` and new `docs/SOUND_ADDRESS_USAGE.md`.
Retain the2KiB/nopw MAME baseline; no speculative RAM alias, analog correction,
new game capture, production RTL change, Quartus stage or RBF. Read/physical
and full per-profile sound qualifications remain explicit. Actual live
cocktail6770 is at38:41/1088 fields; earned-wrapper7814 at19:16/397 fields.
Both terminals remain pending; next qualify actual player2/flip and actual
earned-score HPS save/reset/reload using the same owned processes.

## 2026-10-10 — Actual current HPS wrapper gameplay240 matches full MAME RGB

Parent4d7744d. Actual earned-wrapper process7814 is live at12:38/248 fields.
Checkpoint240's57344 raw core pixels match canonical MAME and settled VGA
exactly; the first240 applied real HPS port records are complete. Receipt:
`research/kyros_earned_wrapper901_v2_gameplay240.json`, bound to the current
compiled wrapper, source manifest, observed port trace and full RGB hashes.
No masks/shifts or production RTL changes. This qualifies finite real wrapper
CPU/input/video gameplay; score save/reset/reload and901 terminal stay pending.
The same cocktail process6770 is live at32:03/900 fields, before the actual
MAME player2 turn1132. Keep both owned handles; no restart is justified.

## 2026-10-10 — Complete bug disposition map; actual feature replays remain live

Parentd32a7a7. Expanded `docs/bug_coverage.json` from the late-scene subset
to an explicit B01–B16 map with current evidence, requirements and remaining
work. Catalogue completeness is separate from coverage_complete=false:
finite graphics/audio/CPU cases, isolated MCU probes and documented physical
limits do not invent full-game, waveform, Stingray or hardware passes. B16's
field60 timed18-pixel backdrop residual remains open; the six qualified HUD
cases retain their atomic failures and independent temporal proof.

Reviewed current audio QIP integration and preserved source underdump,
clock/raster, sound-I/O/analog, SRAM-alias and watchdog limits. Corrected
`docs/LOADER_AND_CLOCKS.md` so historical raw/separate-stage diagnostics cannot
be mistaken for current approved FIFO execution or assembly authorization.
No production RTL, simulation restart, Quartus stage or RBF changed.

Exact Linux processes remain live: cocktail6770 at23:36 elapsed/675 fields;
earned-wrapper7814 at4:12 elapsed/75 fields. Both terminals are pending.
The previous goal turn was progress (current wrapper build/CPU execution).
Next follow these same owned processes, qualify actual player2/flip and
earned-score HPS save/reset/reload results, and address any decisive failure
before the final Kyros audit. All full-goal completion gates remain open.

## 2026-10-10 — Real HPS earned-score wrapper compiled; actual CPU replay live

Parent9bfb6e0. Inspected actual combat RAM: best00002000 at900 and00005000
at3300, matching MAME. Added private wrapper host generation and owned
build/run scripts for real CPU901-field gameplay through HPS, actual donor
save/upload, actual CPU-reset-cleared best score and actual HPS restore.
No synthetic RAM/register/PC writes or production RTL changes. The protocol
requires nonzero earned best, exact178-byte upload/restoration, pause
acknowledgement and actual reset readiness rather than a still-persistent
old value. Details and decisive future terminal requirements:
`docs/EARNED_SCORE_ACCEPTANCE.md`.

First launch stopped before compilation on Windows-backslash JSON paths
under Ubuntu. Preserved original source/worker snapshots and failed handle
recovery in `research/kyros_earned_wrapper901_prebuild_failure.json`.
Portable `/` paths fix that material handoff; corrected v2 is separate.
Build completes exit0,48.159 seconds. Its source manifest and private ELF
30d0db6c...ac5a585 are bound in
`research/kyros_earned_wrapper901_v2_{job,build_exit}.json`. The actual
simulation7814 is confirmed live, has loaded327680 words via real HPS and
begun CPU/video execution. First-field framework57602/core57344 samples
retain the known settling limit. No score/save/reset/reload acceptance is
claimed before its terminal and `earned_score.json` evidence.

The same real cocktail CPU process6770 remains the other required live
replay; keep its namespace and eventual terminal. Next qualify both native
cocktail/player2 behavior and this actual wrapper earned-score flow, repair
any decisive failure, then complete the remaining Kyros acceptance audit.
No Quartus, RBF, resource/timing or hardware pass is claimed.

## 2026-10-10 — Native non-default A coinage case matches every pixel

Parent0cdfb5d. The same actual combined RTL cocktail process6770 is confirmed
live at6:39 elapsed,201 completed fields, no terminal yet. Full field150
matches every57344 MAME pixel, including two credits awarded for one legal
A coin with IN1=70. Receipt:
`research/kyros_cocktail1801_v2_native_credit150.json`, bound to the private
executable, source manifest, observed-port trace and both complete RGB hashes.
No masks, frame shifts or RTL changes. This qualifies a finite native CPU
A-coinage case; player2/cocktail transition and full1801 terminal remain pending.
Follow the same PID and final verifier command in `docs/COCKTAIL_ACCEPTANCE.md`.

## 2026-10-10 — Legal cocktail/coinage oracle qualified; combined RTL replay launched

Source parent101d6d0. Added legal-port cocktail recorder generation and owned
oracle/native runners. Cabinet=Cocktail, Difficulty=Hard, A1C/2C B2C/1C
produce IN1=70. One A coin120..125 yields actual CREDITS2 at150; Start2
160..165 plus natural Player1 death reaches an actual cocktail flip at1132.
Only legal Player2 directional/action inputs follow; no RAM/register/PC
injection. Corrected1801 v2 capture passes all eight checks, exit0,
38.620 seconds,669 flipped fields. All images, RAM, observed ports and
MCU/sound events/WAV are hash-bound in
`research/kyros_cocktail1801_v2_oracle_{job,exit,verification}.json`.

The first3601 observer failed cleanup due to a Lua local declared after
finish()'s lexical scope. Preserved its generated Lua, partial capture and
exact runner snapshot. Its recorded worker/MAME PIDs are absent, and no
terminal exit code was recovered; no success is invented. Recovery:
`research/kyros_cocktail3601_oracle_recovery.json`. V2 declares the local
trace handle before finish() and uses a separate evidence namespace.

Launched actual combined RTL1801 through explicit Ubuntu WSL, reusing
qualified private ELF864ebb2c...03fffa without a rebuild. All70 source pins,
runtime micro/nanoroms, payload and exact oracle ports match. Recorded Linux
worker6768 and simulation6770; actual ps confirms the expected live command.
Native source/input/job handles:
`research/kyros_cocktail1801_v2_native_{launcher,job}.json`; log
`research/kyros_cocktail1801_v2_native.log`. Native terminal/graphics/feature
qualification remains pending. No production RTL, Quartus stage or RBF
changed. Updated `docs/COCKTAIL_ACCEPTANCE.md` and `docs/FEATURES.md`.

Next follow this same process to completion, apply the existing complete-run
verifier and inspect accepted flip/port transactions plus representative RAM
and full RGB around the player transition. Preserve any timing differences.
Remaining full Kyros/Japan, Stingray and P7/P8/P9 gates stay open; the previous
goal turn was progress, and this turn adds a real missing-feature oracle and
an actual combined CPU replay rather than substituting a renderer fixture.

## 2026-10-10 — B02 actual staff roll and full renderer match

Source parent82f0a41. Distinguished stage-clear bonus359a from the actual
high-ROM staff roll. Added `scripts/generate_ending_fixture_profile.py` and
`research/kyros_ending_fixture_profile.json`, validating both program hashes
and five ending code/dispatch blocks. Changed the existing capture Lua and
runner with optional `--ending`: only after guarded scene5/room9 initialization,
normal CPU/SR/SP/return context at1800 permits logged state byte writes
20d10=5/20d11=2/20d12=2. No additional ending PC redirect. Real ROM code then
initializes and writes staff glyphs through1edae/1edd4/1f004.

Kyros5400 capture passes all eleven integrity/setup checks, including actual
staff `KAIROSU` glyphs in sprite RAM. Actual2400/3600 images show characters
covering the credits. Unchanged actual renderer/SDRAM ELF39b91147... matches
all57344 pixels at2400/3000/3600/4200/5399; internal-reference, deadlines and
overflow checks pass. Decisive receipts:
`research/kyros_late_scene_candidates5400_centered_up_scene5_lastroom_ending_*`
and `research/kyros_ending_renderer_*`. Updated partial bug coverage, late-scene
documentation and B02 in `mamebug.md`. Priority stays faithful to MAME/original
behavior; no production RTL, masks, Quartus stage or RBF changed.

Finite B01/B02 graphics coverage now has usable late-game references. These
explicit MAME fixtures do not qualify actual RTL CPU progression through late
gameplay/ending. Full Kyros/Japan feature acceptance, initial backdrop timing
residual, Stingray production MCU/CPU integration and complete P7/P8/P9 gates
remain open. Quartus is resumed by the user, but shared preassembly recipe
registration remains subject to the previously rejected automatic approval;
no raw-tool/queue bypass or assembly is authorized. Continue required RTL/
simulation work while that separate approval remains pending.

## 2026-10-10 — B01 late-room regression qualified for both Kyros ROM sets

Source parent044eef9. Guarded source-derived scene5/room9 MAME fixtures
complete World3600 and Japan3601 fields; all nine capture/setup checks pass.
The first Japan3600 attempt remains failed: World addresses do not satisfy
Japan's call-context guards. Added per-ROM profiles derived from unique
entry signatures, JSR return, wait loop and PC-relative descriptor table;
Japan is42 bytes earlier, independently validated against its program hash.
Changed capture Lua, runner, renderer verifier and added
`scripts/generate_scene_fixture_profiles.py` with
`research/kyros_scene_fixture_profiles.json`.

Unchanged actual renderer/SDRAM ELF39b91147... and all11 current source pins
match every57344-pixel field at World1500/1800/2400/3000/3599 and
Japan1500/1800/2400/3000/3600, with zero internal-reference mismatches,
deadlines or overflows. Separate RAM-only obsolete-color-filter probes at
1500 change500 pixels in each set and produce the expected complete-RGB
failure. Decisive receipts: `research/kyros_candidate5_lastroom_renderer_*`
and `research/kyrosj_candidate5_lastroom_renderer_*`; capture job/exit/verify
receipts bind the fixtures and source revisions. Updated partial
`docs/bug_coverage.json`, `docs/LATE_SCENE_FIXTURES.md` and `mamebug.md`.

Finite B01 graphics coverage is now nonvacuous for both ROM sets. This uses
explicit MAME RAM/register setup and does not qualify actual RTL CPU late
gameplay, ending, unavailable report images or the whole P7 audit. No
production RTL, Quartus or RBF changed. Next trace and capture the actual
stage-clear/ending source path for B02, then continue remaining core gates.

## 9 October 2026 — preparation

**Status:** Research, template/ROM/donor staging and implementation plan prepared. Real CPU/renderer bring-up is in progress. Finite Kyros/Japan simulation evidence is recorded below; complete all-game, fitted resource/timing and MiSTer qualification remain open.

| Work | Result / evidence |
|---|---|
| User constraints | Stored in `AGENTS.md`: no RBF without explicit build/rebuild request, simulation first, resource ceilings, local credentials only |
| Template | Template_MiSTer cloned locally, initial revision in `research/source_manifest.json`; active project renamed `Alpha68k_N`; original `sys/` retained |
| Git | Local `develop` branch; template remote named `template`; no push/publication |
| Board research | `docs/HARDWARE_NOTES.md`: CPUs, MCU variants, exact maps/graphics, clocks, physical component inventory and evidence gaps |
| Online MAME issues | Five applicable Testers records plus source/history limits: `mamebug.md` B01–B15; saved URLs/hashes and commit evidence under `research/` |
| Donors | Twelve repositories downloaded; full commits, available submodule identities, license paths and sparse selections in `donors.lock.json`; integration decisions in `donormap.md` |
| Local ROM ZIPs | Copied `kyros.zip` and `sstingry.zip` into ignored `roms/`; archive hashes in source manifest |
| ROM audit | `kyros` 26 files, `kyrosj` 26 files, `sstingry` 18 files matched driver CRC/SHA1 and consumed sizes; exact region images/load continuations in `research/rom_manifest.json` |
| MCU preservation | Full bootleg and partial original dumps retained independently for firmware use; BAD_DUMP status is preserved and not considered repaired |
| MAME baseline | Local driver text matches upstream `mame0289` after CRLF normalization. Source-tree binary reports `0.289 (unknown)` but returns no matching Kyros machine; compatible reference executable is P1's first dependency |
| Quartus location | `D:\q17\quartus\bin64\quartus_sh.exe` exists; version saved in tool manifest. No FPGA stages invoked |
| Plan | `plan.md` P0–P9; map/fit/STA throughout, strict `resource_limits.json`, all games in real RTL simulation before final assembly/hardware |
| Goal prompt | `goal_prompt.md`; preparation itself did not start a goal or authorize assembly |

Preparation verification outcome and source revision are written to `research/preparation_verified.json` by the final decisive check. That small manifest is the authoritative check result. A local preparation commit is created after the check. The large local caches remain ignored.

## Next action

After the user pastes the goal prompt, start P1: select/build a 0.289 executable containing the Alpha68k N target sets, then freeze reference captures and board profiles. Do not start with an RBF. Read the relevant indexed lessons and the pinned donor interface/provenance before implementation.

## Running phase ledger

Append concise entries here as phases complete. Record: phase, concrete change, source revision, one decisive check result and evidence path, fidelity limit, and next action. Keep failed commands and their real exit codes in evidence, not only successful summaries.

| Phase | State | Required evidence before completion |
|---|---|---|
| P0 | Prepared; final check recorded separately | Template/ROM/donor identity and document consistency |
| P1 | Reference executable, profiles and six 1800-frame recordings established; late fixtures pending | Matching reference executable, XML/audit, deterministic captures/write sweep |
| P2 | Real system and real HPS wrapper run; map/fit/STA held by user | Real RTL harness/load/raster, baseline fitted resources and timing |
| P3 | Kyros real CPU gameplay runs; MCU HLE and fit limits remain | Kyros real CPU boot/coin/start state, bus/MCU proof, fit |
| P4 | Kyros finite graphics checks and field-900 diagnosis; Japan pending | Kyros/Japan MAME-exact frames and gameplay, no underflow, fit |
| P5 | Real sound executes; sampled writes match; waveform/game coverage pending | Live game sound effects/timing/mix, complete sound fit |
| P6 | Pending | Stingray real 8748/68000/Z80 attract/gameplay, graphics/handshake, fit |
| P7 | Pending | Full finite simulation acceptance and B01–B15 coverage |
| P8 | Pending | Features/MRAs/provenance, final complete-design fit/STA and refreshed sim manifest |
| P9 | Authorized only after all simulation/resource/timing gates pass | Final RBF hash and actual MiSTer results for every profile |

## 9 October 2026 — P1 reference bring-up

Source base: local `develop` preparation commit `e544c19`; changed files are the
oracle/recorder/loader scripts, `sim/mame/capture.lua`, `board_profiles.json`,
`rom_layout.json`, `.gitignore`, this ledger and the reference evidence/documents.
The user approved execution of P1–P9 and explicitly requested final assembly only
after the complete simulation and fitted timing/resource gates. That authorization
does not permit early assembly.

The official isolated MAME 0.289 release passed all target XML/source ROM identity
checks and one ROM audit; see `research/oracle_identity.json`. No user binary was
replaced. Kyros MCU NEEDS REDUMP/BAD_DUMP warnings are preserved. Six real MAME
recordings completed, each 1800 frames with finite gameplay inputs, native frames,
RAM, write timing and audio. The decisive artifact check is
`research/reference_capture_manifest.json`; recovery details and renderer decision
are in `docs/REFERENCE_ORACLE.md`. This is MAME reference evidence, not RTL acceptance.

The failed pixel, port-tag and frame-number API assumptions are preserved in ignored
capture directories. A completed first revision lacked scanline bins because Lua
does not expose vpos; those recordings were preserved and replaced with valid bins.
The recorder now exits on callback failure and its runner terminates an owned child
on timeout. No failure or incomplete recording counts as a pass.

`scripts/make_rom_layout.py` materializes a stable loader payload from audited ROMs;
the full raw Kyros MCU candidate is separate from MAME's overlapping region.
Current limit: stage-5/ending, non-default DIP and cocktail fixtures are still pending,
along with physical timing/analog questions. Next action: begin the real RTL shell,
CPU adapters and harness using the frozen reference format, then obtain the late
fixtures before their graphics/bug acceptance gates. P2–P9 remain unverified.

## 9 October 2026 — P2 CPU shell and first divergence

Source base: `7f131741b6e5703ae7bfb861a8ef3f5f7483d484`. Added the 48 MHz board
module, pinned CPU source closure/provenance, actual Verilator C++ loader/clock
harness, explicit Ubuntu build/probe scripts and state/HLE inventories. Framework
`sys/` and the active Template wrapper remain unchanged at this checkpoint.

The installed simulator is Verilator 5.050. The unchanged donor first failed with
BLKANDNBLK; three signal structs are packed, with both source/imported hashes retained
and the same source intended for synthesis. A build under the spaced repository
path failed GNU Make's directory check; compilation now uses an exact temporary
source snapshot and returns the ELF executable to ignored `sim/build`. The first
runtime stopped on the donor's reset-time unique-case check. `--no-assert-case` now
disables generated uniqueness checks while explicit assertions stay enabled.
Failures and actual exit codes remain in `research/rtl_cpu_status.json` and its logs.

The 10-frame probe completed reset-vector reads at 0/2/4/6, entered ROM at 0x0400
and wrote shared-RAM MCU ID 0x12. Evidence: ignored
`sim/captures/rtl/kyros_cpu10/{bus.csv,frames.csv,work.bin}`. The longer 90-frame run
completed 2060235 main transactions with no unmapped accesses, but only five work
writes, two MCU transactions, no strip writes and no IRQ acknowledgements. It
remained around 0x01fc00..0x01ff00 and does **not** pass boot/attract. Evidence:
`sim/captures/rtl/kyros_cpu90` and `research/rtl_cpu_90.log`.

Next action: use the bounded bus instrumentation to distinguish strobe/byte-lane
commit timing from ROM/MCU check failure, then correct the proven boundary and rerun
the smallest boot checkpoint. Graphics/audio chips/SDRAM/PROM loading, wrapper PLL
integration and initial complete-wrapper map/fit/STA remain pending. No fitted
headroom, real RTL attract/gameplay or RBF assembly result is claimed.

The bounded trace proved that all first stack writes were accepted with UDSn/LDSn
both high. fx68k asserts AS before write strobes; acknowledging that address-only
phase discarded the return address (0x0422) and subsequent exception stack data.
The adapter now waits for either valid byte strobe, with interrupt acknowledge
handled separately. Original failure evidence is `sim/captures/rtl/kyros_cpu10_bus`.
The corrected 10-frame probe passed: the real CPU wrote and read back the return
address 0x0422 with both word strobes active and escaped the 0x01fc00 error path.
`research/cpu_boot_regression.json` pins the trace, source hashes and RAM artifacts.
The corrected 90-frame run is underway; it still requires a separate boot/attract
state assessment and does not provide graphics acceptance.

Corrected 90-frame result: 2015083 main transactions, 7776 work writes, 32234 strip
writes, 37 MCU transactions, 35 acknowledgements for each main interrupt and zero
unmapped accesses. It reaches strip initialization and sustained interrupt-driven
game state. Evidence: `sim/captures/rtl/kyros_cpu90_strobes` and
`research/rtl_cpu_90_strobes.log`. No rendered attract/gameplay pass follows from
these bus/RAM results. CPU shell/fix commit: local `01a1aa1` on `develop`.
Whitespace checking passes on owned sources; unmodified generated/vendor sources
retain donor formatting. Next: complete the shared wrapper/48 MHz PLL, load/storage
path and first map/fit/STA, while preparing a longer coin/start CPU replay.

The 300-frame Kyros CPU coin/start replay is now running on a separate copy of
the verified ELF, so subsequent compiler output cannot overwrite its executable.
Recovery/ownership: `sim/build/cpu300_job.json`; streamed state:
`sim/captures/rtl/kyros_cpu300/frames.csv`; result log: `research/rtl_cpu_300.log`.
It is not yet a pass. The goal remains active through all P9 gates.

### 2026-10-09 — P2 loader/wrapper subphase, native memory proof

Source base: `7d08f8a`; working source hashes are bound in
`research/onchip_loader.json` and `research/gfxmem_loader.json`.
Changed: active emu wrapper/QIP, 48 MHz PLL, board PROM/CLUT/color/raw-MCU loader
and diagnostic ports, pinned five-file JTFRAME SDRAM closure, graphics FIFO/
physical row-pair mapping, loader bench and non-assembly Quartus stage runner.
The pinned `sys/` framework is unchanged.

Decisive results: 105088 on-chip ROM words match the canonical payload.
Real SDRAM-controller pin-level simulation matches all 393216 graphics bytes
and 24576 row-pair reads, without dropped/duplicate requests; maximum sampled
read latency 10 clocks. This is memory-path proof, not rendered game acceptance.
The earlier 300-frame real CPU run completed with 88229 strip writes,
245/248 IRQ acknowledgements and zero unmapped accesses; its source/binary/
payload/artifact hashes are now in `research/cpu_boot_300.json`.
Coin/start were applied but have not been independently accepted yet.

Failures retained: first map attempt
`artifacts/quartus/20261009_115845/` lacked generated `build_id.v`; the runner
now generates it before source hashing. Initial pin-model probes sampled
unsettled startup commands; the model now starts after the real registered
reset/NOP settles, with subsequent initialization mode checked strictly.
No controller or donor RTL was changed to conceal that model issue.

The restarted complete-wrapper map/fit/STA job remains owned/live as recorded
in `sim/build/quartus_initial2_job.json`; current evidence
`artifacts/quartus/20261009_120221/`. Resource and timing acceptance are pending,
including external SDRAM constraints. See `docs/LOADER_AND_CLOCKS.md`.
Next: finish this analysis/fit/STA, resolve actual synthesis/timing findings;
continue real raster/strip renderer integration and align native game frames.
No RBF assembly, deployment or hardware test has run.

### 2026-10-09 — P2 first-wrapper synthesis finding

Source `b8e6483`: map reached hard-block generation and then failed with
Error 15834 (`vga_clk_sw.inclk[3]` absent). `SDRAM_CLK` was also stuck at GND.
The own PLL wrapper incorrectly used `altera_pll.pll_type="auto"`; Quartus 17's
actual library and the pinned generated PLL use `"General"` for generic
synthesis. Corrected that parameter at its source, without editing `sys/`.
Evidence/source-library hash: `research/pll_type_diagnosis.json`; failed logs
`artifacts/quartus/20261009_120221/`. Fresh complete-wrapper map/fit/STA is
launched under `sim/build/quartus_initial3_job.json`. Its fit/resource/timing
result is pending; no successful synthesis or clock qualification is claimed.
The native board/SDRAM tests bypass PLL internals and remain valid within their
recorded scope. Next: inspect this owned run, repair any actual RAM/resource/
timing findings, then integrate the renderer. No assembly has run.

### 2026-10-09 — N strip/palette primitives and corrected displayed oracle

Source base `277283a`; renderer source/executable/ROM/RAM hashes in
`research/renderer_fixtures.json`. Added actual N strip/line-buffer renderer,
packed video PROM/CLUT/color ROM, standalone fixture and finite runner.
Seven fixtures pass: three recorded RAM cases match both the independent
MAME formula and the official displayed PNG at all 57344 pixels; flip and
dense all-bank/boundary cases also have zero RGB differences. Worst measured
line 2281/3072 master clocks; no missed lines or row overflow. Kyros color-ff,
both Kyros layout banks, Stingray layouts/wrap and native flip formulas are
covered at primitive scope. `docs/RENDERER_PRIMITIVES.md` defines the limits.
No full CPU renderer acceptance is claimed; active board/QIP integration is next.

A real reference defect was preserved and corrected: MAME 0.289 Lua
`screen:pixels()` reads the drawing bank after texture swap. Stingray frame
1200 differed at 746 pixels against that bank and zero against the displayed
PNG after inverse ROT90. Wrong flip produced 46424 differences. All 66 original
PNG captures now have canonical `.display.rgb` sidecars; 28 differ from the
original drawing-buffer data, which remains intact. New/reused captures now
normalize their displayed sidecars. Evidence:
`research/oracle_display_manifest.json`,
`research/renderer_sting_snapshot_diagnosis.json`,
`research/renderer_fixtures.failed_backbuffer.json`.
The existing shared MAME draw-bitmap lesson was consulted and corroborated.

The corrected-clock map `artifacts/quartus/20261009_121812/` reached actual
memory synthesis and reported main_rom uninferred because of asynchronous read
logic (Info 276007). The owned runner 57332 and map child 56064 were explicitly
stopped after identity/time/parent checks; the cancellation reason is recorded
in its original receipt. Added a dedicated synchronous main-ROM output and
registered-address qualification before ROM DTACK. See
`research/rom_bram_diagnosis.json`; functional/inference qualification is pending.

Current owned jobs: 90-frame CPU-only read-pipeline regression PID 42332,
`sim/build/cpu_bram_90_job.json`; fresh map/fit/STA PID 49784,
`sim/build/quartus_initial4_job.json`, evidence
`artifacts/quartus/20261009_125655/`. Both source manifests bind the actual
working RTL; do not restart a still-live job. Next: verify these results,
resolve actual synthesis/resource/timing findings, connect the proven renderer
and physical SDRAM path to real CPU simulation, then run Kyros into visible
attract/play. All sound/MCU/feature/final fit and P7–P9 gates remain required.
No RBF assembly or hardware test has run.

The ROM-pipeline CPU regression has now completed: 105088 on-chip words checked,
90 CPU frames, main transactions 2015083, work writes 7776, strip writes 32234,
37 MCU transactions, 35 acknowledgements of each IRQ and zero unmapped accesses.
Final work and strip RAM hashes match the prior corrected run exactly. Exact
artifact comparison is in `research/cpu_bram_regression.json`. The owned CPU
job is terminal; `quartus_initial4` remains live and inference/fit/STA are pending.

## 2026-10-09 — real CPU / video / SDRAM integration boot checkpoint

Source base: b0b1b49 on develop. Added rtl/alpha68kn_system.sv,
sim/system_main.cpp, sim/build_system.sh and scripts/analyze_system_capture.py.
The shared system connects the actual fx68k/T80 board, live synchronous strip
RAM, renderer, palette and JTFRAME SDRAM controller; only the external SDRAM
chip is modeled. This top is not yet in the active hardware QIP. Board, wrapper,
QIP and pinned sys inputs were left fixed for the still-owned baseline Quartus
run. Pixel coordinates/blanking/CE follow the three-edge palette pipeline.

The finite 90-frame Kyros run exited 0 (401 seconds): 57344 distinct visible
pixels on every frame, no duplicate pixels, no renderer deadline misses or row
overflows, and zero unmapped CPU accesses. Final main transactions 2012881,
work writes 7725, strip writes 32042, MCU transactions 37, IRQ1/IRQ2 acks 34/35.
Worst observed line 2280 master clocks, below the 3072-clock line budget.
The actual boot image at native frames 30 AND 90 matches the official displayed
MAME references with zero differing RGB pixels (frame 90: World Games Inc.).
This is a real CPU boot display result, not full attract/gameplay or P4/P7 closure.
No audio-chip or hardware acceptance is claimed. Evidence:
research/system90_report.json, research/system90_exit.json,
research/system_build.log, sim/build/system_inputs.sha256,
sim/captures/rtl/kyros_system90/. ELF SHA256
e89d565ce4765b1df6752f27b9322b7ca35f37228a34df3bf205473b3268cf2c.

Owned 600-frame Kyros continuation now runs the same bound native ELF, including
MAME's coin/start/action sequence applied at vblank entry. Its exact PID,
command, timestamp, log and exit-receipt handle are in
sim/build/system600_job.json. Do not restart it while live. Baseline
quartus_initial4 remains owned via sim/build/quartus_initial4_job.json;
map/fit/STA qualification is still pending. Next: inspect visible attract and
gameplay frames, quantify displayed-reference comparisons/state alignment,
finish the shared hardware video wiring once the baseline run ends, and
integrate sound. P5–P9 and final resource/timing gates remain required.
No RBF has been assembled or tested on hardware.

## 2026-10-09 — user stopped Quartus; explicit hold is active

The user instructed us to stop our Quartus tasks and not use Quartus until told
again. Terminated the verified owned runner 49784 first to prevent subsequent
fit/STA dispatch, then its map worker 49208 and parent map process 57404.
A Win32 process inventory confirmed no Quartus processes remained. Evidence:
research/quartus_user_stop.json; the original baseline receipt at
artifacts/quartus/20261009_125655/receipt.json now records cancellation.
This run provides no completed map, fit, resource or timing qualification.

quartus_hold.json and the development runner enforce the hold before creating
an evidence directory or invoking any Quartus executable. AGENTS.md records
the latest user override. Do not restart any Quartus stage or use preflight
modes that invoke Quartus until the user explicitly permits it again.
RTL implementation and Verilator simulation continue within the active goal.
Final resource/timing, assembly and hardware gates remain unfulfilled.

## 2026-10-09 — live Kyros gameplay and P5 sound primitives checkpoint

Source base 7c269ba, with Quartus hold committed as 82bfaf1. The owned
600-frame real CPU/video/SDRAM Kyros replay is terminal, exit 0. Every one of
600 visible fields has 57344 pixels and no duplicates. Zero renderer deadline
misses/row overflows/unmapped accesses; worst line 2280 clocks. Final main
transactions 13886750, work writes 62018, strips 147081, MCU transactions 557,
IRQ1/IRQ2 acks 544/552. The coin/start/action sequence reaches visible stage-1
gameplay. Native displayed RGB equals official MAME at frames 30, 90, 240
AND 360; frame 600 differs at 458 pixels. The latter is an unresolved fidelity
finding, not a waived gate. Do not label P4/P7 complete. Evidence:
research/system600_report.json, research/system600_exit.json,
research/system600_inputs.sha256, sim/captures/rtl/kyros_system600/.
The analyzer's passed field covers capture plumbing, not whole-game fidelity.
Next graphics action: identify frame/state alignment or the responsible RTL
difference at frame 600 using the retained RGB/RAM and event evidence.

Imported pinned JT03/nested PSG sources and separately namespaced external
JT49 sources with originals/licenses/provenance retained. Added soundchips,
nominal wide mono mixer, shared audio wrapper, inactive audio QIP and native
contracts/build scripts. Initial staging rejected variable whitespace in a
VHDL QIP line before a complete import; the reproducer now accepts whitespace
and validates the whole closure before writes. Source/hash integrity is bound
by rtl/vendor/audio_sources.json. The qualified external AY configuration
uses period-zero-as-one, sixteen envelope levels and MAME's resistor transfer.
No duplicate PSG module namespace remains.

Real donor chip contracts build/run exited 0: independent registers/masks,
sixteen levels, periods 0/1/37, zero/nonzero envelope rate, YM timer status/
clear and warm reset. Complete audio-top lint and nominal mixer build/run
exited 0; six floating-reference vectors establish signed arithmetic,
profile route gains, 48 kHz cadence, reset and single saturation/counting.
Decisive evidence: research/soundchips_contracts.json/log,
research/mixer_contracts.json/log, corresponding build-exit receipts and
research source manifests. Details and reproduction: docs/SOUND_HARDWARE.md;
donormap.md updated. These isolated contracts do not close P5's real game WAV,
event, gain, effect or analogue checks, nor its grouped bug gates.

Next implementation: connect actual Z80 I/O queries/readback and DAC to the
shared audio system; record real game register events and WAV, resolve the
frame-600 graphics finding, then complete Kyros/Japan and subsequent Stingray
work in plan order. Quartus remains explicitly disabled; no map/fit/STA/RBF
or hardware pass is claimed. The goal stays active for RTL and simulation.

## P4 frame-600 diagnosis and P5 real CPU/audio integration — 2026-10-09

Source baseline: 0e43957 (the original CPU/video capture remains bound to
7c269ba and its preserved executable). Quartus remains disabled by the user.

The frame-600 finding is localized: all 458 differing pixels belong to the
GET READY PLAYER 1 message. Its 18 differing strip words XOR only bit 0x4000;
the terminal work counter is 0x021c versus MAME 0x021d. Both captured states
independently render to their respective recorded images with zero differing
pixels, zero deadline misses and zero row overflows in the real isolated RTL
fixture. This proves the static renderer is faithful for these two states;
it does not prove that the real CPUs reached equivalent frame epochs.
Evidence: research/kyros_frame600_state.json,
research/kyros_frame600_diagnosis.json, research/kyros_mame_counter_events.json,
docs/FRAME600_DIAGNOSIS.md. Added scripts/diagnose_frame_state.py. No graphics
RTL was changed in response to an unsupported timing hypothesis.

Connected the staged YM2203, two AYs and DAC mixer to alpha68kn_system on the
same 48 MHz clock. alpha68kn_board now separates Z80 I/O reads from program
ROM and returns the actual chip query data, retaining its existing single
write-per-transaction qualification. Added a DAC write observation strobe.
The CPU-only harness and unfinished MiSTer wrapper explicitly tie chip
readback to 0xff; they are not integrated-audio acceptance candidates.

Native combined build exits 0; all 68 manifest inputs match the source used
to build it. Evidence: research/system_audio_build_exit.json,
research/system_audio_gameplay_inputs.sha256. The old CPU/video executable
is preserved as sim/build/alpha68kn_system_pre_audio_sim.

Started the actual combined Kyros gameplay run for 1800 fields, executable
ae4c3058532ba217b224c01cf6d823b6f3d909436253089adf492d0ad930dfbd.
Its owned worker was verified live, with frame 30 reached and complete
57344-pixel fields, zero duplicate pixels and zero reported missed deadlines.
The first 100 actual game I/O writes and a DAC write are recorded. This is
running evidence, not a terminal pass. Recovery: sim/build/system_audio1800_job.json;
research/system_audio1800_started.json; research/system_audio1800.log;
terminal receipt research/system_audio1800_exit.json; captures in
sim/captures/rtl/kyros_audio1800/. New audio_events.csv records real bus writes,
reads and DAC writes. epoch_events.csv records the complete selected causal
stream. Final audio.wav is raw mono PCM16 at 48 kHz from the actual chip/mixer
outputs, with audio.json write counts, clipping and sample bounds. No audio
normalization or fabricated effects are used.

P4/P5/P7 remain open: resolve the reset/frame/IRQ state alignment, complete
actual attract and gameplay and sound fidelity/bug checks, then Japan and
Stingray in plan order. Later framework integration and every fitted
resource/timing gate remain pending. No Quartus stage, RBF assembly or
MiSTer test was run.

## P4 reset/capture epoch correction — 2026-10-09

Source baseline: 67cad80. A fresh read-only, four-callback official MAME run
exits 0 and binds callback 0 to t=0.016896 s, beam (240,0), screen frame 0.
Evidence: research/mame_origin_trace.json; sim/mame/trace_origin.lua.
The native selected write stream places the first work-counter writes on
lines 104/128, versus MAME 80/104: a 24-line, 1.536 ms reset-phase difference.
The native board instead reset to line 0 and its first complete image was
labelled 1. Corrected alpha68kn_board reset origin to line 240 and
system_main.cpp capture labels to 0..N-1 with input changes after the same
label as capture.lua. This uses a documented MAME startup convention; no
CPU-frequency adjustment, screenshot relabeling, pixel mask or renderer
change is used. Physical PCB startup raster phase remains unmeasured.
analyze_system_capture.py now checks the zero-origin sequence by default;
legacy evidence requires explicit --frame-origin 1.

The obsolete audio1800 run was verified live and intentionally stopped by
SIGTERM to its exact owned Ubuntu process (89942). The matching argv and
reason are recorded in research/system_audio1800_cancelled.json. Its partial
real CPU/audio/epoch traces and executable/source hash are preserved; no
terminal game/audio fidelity pass or final WAV is claimed. Its worker exit
receipt is research/system_audio1800_exit.json. This is a source correction,
not a restart caused by a polling timeout.

Next: build the corrected shared RTL in the pinned Ubuntu Verilator runtime
and run the full same-input Kyros attract/gameplay comparisons from the
corrected epoch, retaining complete counter/message/IRQ and audio traces.
All P4/P5/P7 acceptance gates stay open pending those results. Quartus
remains disabled; no FPGA build stage or hardware test was used.

Corrected-epoch qualification job: source 90b3081; owned worker 48420.
Recovery: research/system_epoch1800_job.json (also sim/build copy);
research/system_epoch1800.log; build receipt research/system_epoch_build_exit.json;
source/executable binding research/system_epoch1800_started.json and
research/system_epoch_gameplay_inputs.sha256; final receipt
research/system_epoch1800_exit.json; output sim/captures/rtl/kyros_epoch1800/.
research/system_epoch_startup.json records the current authoritative worker,
build and early capture evidence. It does not establish terminal acceptance.
Do not restart solely for a missing terminal receipt or observation timeout.

Corrected native startup verified: build exit 0, all 68 compiled manifest
inputs match, owned worker live, frames 0..15 reached with complete 57344-pixel
fields and no duplicates/deadlines/overflows/unmapped accesses. The first
completed frame (0) is byte-exact to the displayed MAME frame 0. Executable
SHA-256 eabf3b99703bcfa09c46fcc73ccf8fa0c5f792d38df26de772d9b87decc6a60a.
The 1800-field run is still active, with no terminal or whole-game graphics/
audio acceptance pass asserted. Next read its actual causal traces and
checkpoint results; do not weaken comparisons to force the frame-600 gate.


## 2026-10-09 — replay observed ports; close early DAC/control divergence

Source baseline 7542301 on develop. Changed sim/system_main.cpp to replay
actual recorded IN0/IN1/IN2 pins via --inputs, log applied ports, and add an
optional bounded sound-bus/DAC probe. Board/system expose diagnostic Z80 bus
signals; the scaffold wrapper leaves them unconnected. No CPU clock, ROM
mapping, chip algorithm or image comparison was changed. sim/mame/trace_dac.lua
adds read-only control/DPCM observations to the unchanged original recorder.

The reset-epoch correction alone did not close frame 600: its displayed-image
comparison remains 458 pixels different. The next causal evidence identifies
queued MAME field:set_value requests committing one frame later than the old
native manual script. Native coin command 0x72 occurred at 121 rather than
MAME 122, followed by divergent second-stream state and DAC writes. The
incorrect-input 1800-field epoch run was deliberately cancelled (exit 15);
research/system_epoch1800_cancelled.json and system_epoch1800_exit.json
preserve the reason and terminal status. This was not an observation timeout.

Fresh official MAME DAC probe completed 130 fields (exit 0). Its 3,711 DAC
write rows match the original recording, and 654 selected ROM reads over
329 addresses match the staged payload. Disassembly uses the official staged
unidasm; ROM-derived output remains ignored. Evidence:
research/mame_dac_probe_run.json, research/unidasm_identity.json,
research/dac_control_first_difference.json; captures under
sim/captures/kyros/dac_probe/. Read-end native bus samples are diagnostic
observations, not claims about the CPU sampling edge.

Canonical-port native build and 130-field probe both exited 0. Executable
SHA-256 e161405f3f99f967a512fdcf0702e8aa2da18c4dd53127801078797cbcd88aa1;
physical-port source SHA-256
009afa6eab5ebbae2802f807ee000811e6716cb47c884ea1fcdc9d7243c47e2d.
The first coin command is now frame 122, y61, matching MAME. All 131 applied
port records match their source rows. All 12,734 selected control-RAM writes
and 3,711 DAC writes match MAME in field/address/value/order (zero paired
differences). This closes that finite causal trace difference, not complete
PCM, gameplay or graphics fidelity. The 130-field capture has 57,344 pixels
per field, zero deadlines/unmapped accesses; mixer clips 0, 105,431 samples,
and YM/AY1/AY2 writes 42/40/32. Actual effects/music qualification is pending.
Evidence: research/kyros_portreplay_probe.json,
research/system_portreplay_coin_gate.json,
research/system_portreplay130_exit.json and sim/captures/rtl/kyros_portreplay130/.

The same immutable executable now runs the canonical-port 1800-field gameplay
recording. Owned worker 13308 was observed live, with frame 240 reached;
no terminal receipt exists yet. Recovery: research/system_portreplay_job.json,
research/system_portreplay.log, research/system_portreplay1800_started.json,
research/system_portreplay_inputs.sha256; final receipt
research/system_portreplay1800_exit.json; output
sim/captures/rtl/kyros_portreplay1800/. Do not restart for a polling timeout.
Next: inspect frame 600 and subsequent checkpoints, then close remaining
Kyros attract/gameplay/audio/bug gates before expanding qualification.
All P4/P5/P7 overall gates remain open. Quartus is disabled by explicit user
hold; no analysis, synthesis, fit, STA, assembly or hardware test was run.
## 2026-10-09 — connect shared system to framework; elaboration only

Source baseline b49a70a. Alpha68k_N.sv now connects alpha68kn_system to the
actual pinned arcade_video/screen_rotate framework and routes real mixed
audio. files.qip includes the shared renderer/system/video ROM and existing
audio QIP. SDRAM refresh/download/read arbitration is shared with the native
harness. Added concise orientation/effect/aspect controls. No sys/ source
was edited, no game clocks or CPU algorithms changed. See
docs/FRAMEWORK_BOUNDARY.md for connections, crossing limits and pending work.

sim/lint_wrapper.sh elaborates the actual core/framework in native and
framebuffer/palette builds, with vendor HPS/PLL interface stubs only. Initial
checks failed because sync_fix lives in sys_top.v and because Verilator
rejects hq2x's procedural assignment to its implicit net output. The script
extracts the exact sync_fix module and uses the indexed -Wno-PROCASSWIRE
compatibility setting. Both corrected checks exit 0, assertions remain
enabled, sys unchanged; warnings 75/92 (wrapper timescale only). Evidence:
research/wrapper_lint_result.json, wrapper_lint_inputs.sha256,
wrapper_lint_missing_sync.json, wrapper_lint_procasswire.json. Logs are under
sim/build/. No full-framework execution, pixel, DDR, CDC or timing pass is
claimed. P8 remains open for functional boundary captures and remaining
menus/CRT Adjust/pause/hiscore qualification.

The immutable canonical-port gameplay run remains active; latest observed
field 450 has all 57,344 pixels, no duplicate/deadline misses. No terminal
receipt exists yet and frame 600 is still pending. Wrapper changes do not
modify its captured source snapshot. Next inspect the existing run's
frame-600 checkpoint, preserving its exact physical-input and image contract.
Quartus remains disabled until explicit user release; no FPGA stage or
hardware test was invoked.
## 2026-10-09 — frame 600 exact; diagnose framework RGB scope

Previous goal turn classified as progress: b49a70a fixed actual-port replay,
and 03ed44e connected the shared system/framework. This turn uses 03ed44e as
source baseline. The existing immutable gameplay worker was reobserved live
(Win13308/Linux109354) and reached field 600 without restart. The previously
failing GET READY checkpoint is now byte-exact: 0 differing pixels, SHA-256
870367cea2cc090698af979491e7a9c75e56ca3048a484753ad11186728f9bc8 on both sides.
Available checkpoints 0/30/90/240/360/600 all match. No renderer, CPU-clock,
frame-offset or masking workaround was introduced. Evidence:
research/kyros_portreplay_graphics_partial.json; source/executable/input
bindings remain research/system_portreplay1800_started.json and manifest.
This closes that finite checkpoint, not terminal/all-frame game fidelity.

Added an executed pinned-framework video fixture and build script. The
original chain passes input RGB and all six native/HQ2x/CRT/forced-scandoubler
pixel-count/sync checks but produces black RGB and exits 1. Its input register
matches 172,032 pixels per mode. The indexed video_mixer generate-scope
lesson was verified against this source and reproduced. Added an explicit
temporary-copy net-scope adapter; no sys/ source edit or sequential/datapath
replacement. Corrected-model native RGB has zero differences and all six
timing checks still pass. Normalized ELF SHA-256
7b7116557bb1486d500951562f1ed0cf7ef615df9b55d09ef3e8fe6a917a1b4e.
A tool failure omitted its first terminal receipt after writing full output;
after authoritative handle absence, rerunning the same ELF recovered exit 0.
Original failure and recovered result both retained. Recovery/evidence:
research/framework_video_{run,result}.json,
research/framework_video_normalized_{run,result}.json,
research/framework_video_scope_adapter.json, both source manifests;
sim/build/alpha68kn_framework_video_{original,normalized}_sim and build logs.
See docs/FRAMEWORK_BOUNDARY.md for the conditional model's limits.

Next: continue the same long gameplay run and inspect later checkpoints and
terminal audio/game evidence; exercise rotation DDR mapping and real wrapper
execution. P4/P5/P7/P8 overall acceptance stays open. Quartus remains disabled
by user hold; no FPGA stage or hardware test was run. No goal completion,
resource/timing pass or whole-game MAME_EXACT claim is made.
## 2026-10-09 — actual HPS wrapper boots; rotation mapping verified

Previous turn classified as progress (693cfdf, frame-600 closure and actual
framework diagnosis). This phase uses 693cfdf as baseline. Extended the
framework fixture through the real screen_rotate DDR writer: native
clockwise output is 224x256, stride 896; all 57,344 pixels match the independent
coordinate transform, zero unwritten pixels/out-of-bounds writes. Horizontal
mode disables framebuffer writes. Seven mode runs exit 0. This uses an
always-ready DDR endpoint and explicit temporary net-scope adapter; physical
bandwidth and changing-game rotation remain pending. Evidence:
research/framework_rotation_{build,run,result}.json, inputs.sha256 and
scope_adapter.json. The native/non-native RGB counters now distinguish
uncompared modes with null.

Added sim/build_wrapper.sh and wrapper_main.cpp, exercising actual emu,
hps_io, CPUs, renderer, audio and SDRAM. ALPHA_EMU_SIM adds ideal PLL outputs,
diagnostic signals and external HPS pin drivers only to simulation; production
PLL/sys stay pinned. Both production elaboration modes pass. Initial runs
ended with explicit failures: uninitialized SDRAM pins sampled at cycle 1;
HPS input pins erased by generated inout response logic; and a visible-only
buffer unable to retain the first startup VGA field. Each cause/recovery is
documented in docs/WRAPPER_SIM.md and retained diagnosis/terminal artifacts.
The fixes affect simulation boundary/collection logic; no fake loader/CPU,
ROM patch, image offset, mask, cropping or padding was used.

Corrected wrapper run: build and 96-field runtime exit 0, all 79 source inputs
bound to its manifest; ELF
88352a15f9a1efd81d8152cf62e078f2b0ad5cf58935046e7760de1ad82ececc.
Real HPS audits all 327,680 ROM words and validates joystick/start/coin release
and orientation commands. Fields 4..95 have exact paired core/VGA RGB,
57,344 pixels, zero duplicate/unmapped/deadline/overflow counts. Canonical
MAME comparisons: core 0/30/90 and VGA 30/90 all 0 differing pixels. VGA field
0 has 57,602 actual startup samples and is unqualified, retained at its real
172,806-byte size. No full-wrapper startup/hardware/audio pass is inferred.
Evidence: research/wrapper96_qualification.json, wrapper96_settle_exit.json,
wrapper96_settle_inputs.sha256 and scope_adapter.json; captures under
sim/captures/rtl/kyros_wrapper96_settle/. Recovery of the completed worker
42480 and Linux112029 is in wrapper96_settle_job.json; it is terminal, not live.

The separate canonical-port gameplay worker109354 remains live, with field
1590 observed. Frame1200 is exact, but frame900 has four differing pixels
near the health-bar region (native x26..29/y8,15). They are retained in
research/kyros_frame900_difference.json; cause is unproven. The partial
graphics evidence records that failure, not an all-checkpoint pass.
Next investigate actual sprite state/write-versus-scan timing at that first
remaining checkpoint; do not mask pixels or shift images/clocks. Finish the
existing long-run terminal/audio qualification and remaining Kyros features
before claiming P4/P5/P7/P8 complete or advancing overall set acceptance.
Quartus stays disabled; no FPGA or hardware stage was run. Goal remains active.


## 2026-10-09 — complete Kyros gameplay recording and HPS DIP wiring

Source baseline `07cb0cc`; real-system ELF `e161405f3f99f967a512fdcf0702e8aa2da18c4dd53127801078797cbcd88aa1`. The observed-port gameplay run completed all **1800 zero-origin fields, exit 0**. Every field has 57344 pixels, zero duplicates, unmapped accesses, deadline misses and row overflows; worst preparation is 2280/3072 master cycles. Canonical MAME checkpoints 0,30,90,240,360,600,1200,1799 match exactly; **900 retains four differing pixels**. Do not infer a whole-game graphics pass. Evidence: `research/system_portreplay1800_exit.json`, `research/kyros_portreplay1800_qualification.json`, ignored captures `sim/captures/rtl/kyros_portreplay1800/`.

Sampled MAME sound-write windows match address/data/order/field: 11377 DAC writes (fields 0–259), 114 chip writes (0–259), and 224 chip writes (1190–1209). Empty windows provide no active-sound proof. The run produced 1459814 samples at 48 kHz, range -31130..10895, no clipping. PCM fidelity and physical analog calibration remain unqualified. Evidence: `research/kyros_portreplay1800_sound_writes.json` and captured `audio.json`/WAV.

`Alpha68k_N.sv` now exposes `DIP;` and connects bank zero from HPS ioctl index254/address0/low byte, with power-on default0x8E. Convention follows pinned TripleZ80 wrapper lines455–462; no donor framework edits. `sim/wrapper_main.cpp` exercises bank/address/byte selection through real HPS, restores defaults and offers a bounded `--host-only` diagnostic. Host-only test passed, then the same ELF booted **31 fields, exit0**, auditing all327680 ROM words. Core fields0/30 and VGA30 exactly match MAME; fields4–30 pair core/VGA exactly. Initial VGA field0 still has 57602 samples and remains unqualified. Evidence: `research/wrapper_dip_{build_exit,exit,result,inputs.sha256,scope_adapter.json}`, `research/wrapper_dip31_qualification.json`; ELF `343dd175ec068226223361673fd71332a403c5d49944ac51e9a9184b4bfa1704`. MRA DIP labels, pause, CRT adjustments and hiscore integration remain pending.

Field900 investigation: all four pixels belong to tile word0x40EEA. Fresh unchanged MAME recording with a read-only tap matches all901 original state rows and its frame900 sprite RAM. The word changes20→21 at raster(313,52), after its displayed tile on lines24–31. Isolated actual RTL renders the final MAME state exactly; replacing only that word with its observed pre-write value20 reproduces the **entire real-CPU field900 image exactly**. This is a diagnosed temporal reference difference, not permission to mask pixels or shift frames. See `docs/FRAME900_DIAGNOSIS.md` and B16 in `mamebug.md`. Full paired scanline-time/CPU evidence remains required before closing this graphics limit.

A CPU-only state diagnostic was added (`sim/board_state_main.cpp`, `sim/build_board_state.sh`). Its initial script failed exit2 due CRLF/`pipefail`, then corrected build passed. The Windows-attached run was externally interrupted with STATUS_CONTROL_C_EXIT after225 fields; every recorded main counter matched the completed system run. No frame900 RAM was produced by that attempt; initiator is unproven. Evidence: `research/board_state900_{crlf_build_exit,build_exit,exit,interruption}.json`. The same pinned ELF now runs through an owned detached Linux worker: `research/board_state900_detached_started.json`, expected `research/board_state900_detached_exit.json`, captures `sim/captures/rtl/kyros_board_state900_detached/`. Sound readback is0xFF in this diagnostic; it is not full-system acceptance. Do not restart the active run without checking its exact process/receipt.

The first MAME word observer failed on unavailable `register_stop`; the second exited0 but had callback errors from unavailable hpos/vpos methods. Both failures are retained; neither is counted as a pass. The corrected observer uses the previously established time_until_pos beam calculation and a retained machine-frame notifier. Evidence: `research/pixel_word_mame_exit.json`, `research/pixel_word_mame2_failure.json`, `research/kyros_frame900_mame_word_trace.json`.

Next: inspect the detached diagnostic's terminal and verify all main counters, RAM and late-write timing; then qualify the field900 reference relationship without claiming broad MAME_EXACT. Continue required Kyros features and attract/late-stage/bug coverage before Japan and Stingray. **Quartus remains disabled by the user; no map, synthesis, fit, STA, RBF or hardware pass.**


### Field900 terminal closure (same phase)

The detached CPU diagnostic completed **901 fields, exit0**. All main-CPU counters at every field match the full real-system recording (zero differing counter values). Its entire8192-byte sprite RAM at900 exactly matches MAME (SHA256 `7b6abf06d1668cd9bbe521320f65ff39be5264b742f0c2ee2918e3e3b4bd9f6a`). Native writes20→21 at(311,52), versus MAME(313,52), in the same field900. The two-pixel horizontal difference is retained; both updates occur after the tile's displayed raster lines24–31. The final RAM, late write and isolated pre-write render jointly explain the four live pixels. No RTL timing/data change was made to force a PNG pass. Work RAM retains two differing words: offsets0xF5E (native0x0120/MAME0x0100),0xFF2 (native0x9E8E/MAME0x9E92); no broader CPU-state match is claimed. Evidence: `research/kyros_frame900_native_timing.json`, `research/board_state900_detached_exit.json`.

The required **Kyros attract1800** run is now active using the already qualified native ELF; no redundant rebuild. Actual attract port-trace SHA256 `e1b155565a948d4b1c665c79cfb842be82679ac13a5082055eb1f0002fe22783`. Owned Linux worker/process recovery: `research/system_attract1800_started.json`; expected terminal `research/system_attract1800_exit.json`; log `research/system_attract1800.log`; capture `sim/captures/rtl/kyros_portreplay_attract1800/`. Follow this run to completion and compare canonical checkpoints. Next required software work includes audio fidelity, late-stage/ending/cocktail coverage, MRA labels/CRT/pause/hiscore, then Japan and real Stingray MCU integration. All Quartus operations remain held.


## 2026-10-09 — correct YMFM SSG bias and numerical range

Source baseline `2ae4222`. WAV comparison and primary MAME0.289 source show that the YM2203's YMFM SSG is positive0..16382 per channel, whereas standalone AY uses legacy biased normalization. The old mixer incorrectly subtracted the AY bias from the YM SSG. `rtl/alpha68kn_mixer.sv` now uses Q16 multiplier1263071 and zero YM SSG bias. `sim/mixer_main.cpp` uses an independent source-derived floating oracle, including an isolated SSG peak vector. Seven vectors/35 pulses, both saturation signs,48-kHz cadence and reset pass. Evidence: `research/mixer_ymfm_{build_exit,contracts,contract_manifest}.json`, `research/audio_ymfm_normalization_reference.json`. Older mixer passes do not validate the corrected normalization.

New `sim/audio_replay_main.cpp`/`sim/build_audio_replay.sh` execute the actual sound and mixer RTL from the real CPU recording's post-edge writes, with documented next-edge consumer timing. Full1800-field replay completes exit0, applying all37908 events (7088 I/O,30820 DAC), producing1459814 samples without clipping. Sound-chip counts remain YM3848/AY1=1234/AY2=2006. Quiet means now differ from MAME by one sample unit rather than3687. ELF8700fe96f9f25cc41d0b4aaf5811f85c23ef79d54fafc24291a78e7bb0d0f68c, event trace SHA256c5f4d96bedb2a73b07cbfb9d7805fdb1a46eba1bca0051f826230b9ebc97ce67. This is a write-replay audio diagnostic, not a replacement for CPU/game qualification.

`docs/AUDIO_NORMALIZATION.md` records evidence and remaining limits. `scripts/analyze_audio_spectrum.py` uses a calibrated radix2 FFT and four finite absolute-time windows, with no shift. Early AC ratios1.0068/1.0058 and selected peak differences<0.002Hz are close; late AC ratios1.0927/1.1178 and ambiguous20-second peak matching remain unqualified. Do not tune clocks or global gains to force a total-RMS match. Next: inspect MAME0.289's actual per-device capture/routing API, then isolate component levels/frequencies and finish P5 action/effect coverage. The Lua `hook` property is boolean, not a PCM callback; no Lua output-gain setter was found in the frozen source.

Evidence: `research/audio_ymfm1800_qualification.json`, `research/audio_ymfm_spectrum.json`, `research/audio_replay_ymfm1800_exit.json`, `research/audio_replay_ymfm_inputs.sha256`; large WAV/component CSV ignored under `sim/captures/audio/kyros_ymfm1800/`. The real-core Kyros attract1800 process remains active (worker113162, simulation113163, exact identity in `research/system_attract1800_started.json`). Its earlier mixer revision is explicitly retained; gain-only changes do not supply an audio pass from that old run. Continue the same process/receipt to terminal; do not rebuild/restart it merely for this output-only change. No Japan/Stingray completion, broad MAME_EXACT, resource/timing, RBF or hardware pass. **All Quartus operations remain disabled.**


## Requested MiSTer controls/video/hiscore software phase — 2026-10-09

Source base: `7995cd7c3f1b630819dd44b4b23d599183f74e99` (develop); this phase
retains the concurrent audio normalization work. No sys/ edits, Quartus command,
RBF assembly, remote publication or hardware deployment occurred.

Implemented named Kyros Punch/Jump controls and Pause; standard DIP Switches
submenu with complete MAME DIP names/defaults; standard byte HPS pairing;
integer scaling; CW/CCW framebuffer and native 180-degree rotation; pinned
CRT adjustments and native/direct/analog/Y-C framework paths; pinned hiscore
restore/extract/upload with default autosave on OSD entry. MAME lists no Service
input for these cabinets, so none was invented. Stingray's development MRA has
provisional Fire/Special weapon labels and its rejected P6 profile is unchanged.
Changed wrapper/QSF/QIP, board/system/renderer, CRT/donor modules, simulation
harness/build/lint, MRA generator/records, README and feature/plan/donor docs.

Decisive evidence: `research/feature_qualification.json` records input hashes,
ELF hash, exact snapshot recovery handle and final results. Feature protocol8
exit0: all256 DIP byte values through real HPS;178 synthetic score bytes restored
and uploaded with correct lanes; pause freezes bus writers while raster runs;
changed OSD entry saves and unchanged entry does not; four integer scale modes;
five native/CRT/direct modes with uniform active pixel intervals, sync and frame
period checks; both quarter turns and 180 degrees compared pixel by pixel.
Final Kyros and Japan real-ROM eight-field runs exit0 with327680 paired words,
zero unmapped/deadline/overflow counts, settled core/VGA57344 pixels from field4.
Native and framebuffer production elaboration exit0 (peripheral stubs). Native
line3072/frame811008 master cycles give15,625 Hz/59.1856060606... Hz. These short
boot tests are not all-game attract/gameplay qualification.

Failures retained in `research/feature_runtime_trials.json`: tri0 pause input
prevented Verilator pause propagation (explicit wire fixed); fixture OSD/reset
ordering initially hid donor upload edges (fixture corrected without changing
donor); WSL /tmp filled then GNU Make rejected a path with spaces (owned failed
snapshot removed with receipt; builds moved to `/mnt/d/vibes/fpga/temp`);
enlarged CRT content initially exposed a nonuniform interval at line rephase
(blank the donor two-read pipeline tail at sync; protocol8 cadence checks pass).
The first framework field's57602 samples remain a recorded limitation.

Next action/gates: P6 real Stingray8748/maps and verified cabinet action names;
non-default DIP/cocktail and earned-score save/reload in gameplay for all games;
original PCB sync pulse measurement; physical direct-video/Y-C/DAC/CRT checks.
V-Size is bypassed on direct video, and retimes HSync elsewhere; chassis lock
remains unqualified. Complete-design resources/timing and RBF/hardware release
remain pending the explicit Quartus hold and a separate explicit RBF request.

### 2026-10-09 — long attract evidence and SSG source diagnosis

Base revision ff746d2 (separate frontend commit preserved). Old full-system
ELF e161405f... completed Kyros attract1,800, exit0. All nine saved canonical
checkpoints0/30/90/240/360/600/900/1200/1799 match MAME with zero pixel
differences. All fields have57344 pixels and zero duplicates/unmapped/deadline/
overflow counts; worst line2280/3072. Evidence:
research/kyros_attract1800_qualification.json and system_attract1800_exit.json.
Scope: finite graphics/CPU evidence with the earlier mixer; no current-design
or broad MAME_EXACT pass.

The read-only MAME per-device observer completed1,800 fields with identical
CPU-state rows and mixed WAV. Old SSG AC ratios1.2623/1.1418/1.2517 isolated the
donor compression/index defect. The project now selects reproduced YMFM bank5
while retaining donor defaults/notices. See docs/YM_SSG_CURVE.md and vendor
manifest. First import failed despite exit0: CRLF prevented table insertion,
giving silence. Failure is retained and the new activity guard exits2.
Corrected staging verifies32 entries and both Verilator builds exited0.

Corrected sound worker125737/simulation125837 is active, ELF
04027110e888e5962b9b3bee84a5c290742c4f547717a98bb39a2b11593b43a7.
Inspect its terminal/moments before qualifying. Fresh native full-system build
first failed from /tmp PCH exhaustion; owned cleanup/failure/inputs remain.
The silent-SSG native attempt was explicitly stopped and is unqualified.
Corrected D-volume build passed; worker125738/simulation125976 runs Kyros720
then Japan720. See research/current_system720_curvefixed_job.json,
kyros_current720_curvefixed_started.json and input manifest; hashes bind actual
ROM/input/RTL/ELF, with no scripted CPU.

Next: corrected sound terminal/moments, current Kyros/Japan terminals and
canonical checkpoints. Explicit death/game-over/reset, Stingray MCU, remaining
feature runtime, full resource/timing and hardware gates remain open.
Quartus remains disabled.

#### Corrected audio terminal — same phase

Corrected actual-chip replay completed1,800 fields,37,908 original native CPU
writes and1,459,814 samples, exit0; activity guard passes, zero PCM rail samples.
SSG AC ratios15/20/29:1.004409/0.981642/0.994365. Combined WAV ratios:
1.04128/1.01463/1.01715; quiet means differ by one signed sample unit.
Evidence: research/audio_component_curve_fixed.json,
audio_ymcurve_fixed1800_qualification.json and corrected terminal/input hashes.
Scope remains finite source/mix calibration; combined phase/resampling residuals
and explicit effects remain open. Eight normalized adapted-source comparisons
match the snapshots after whitespace cleanup; no macro-continuation cases.
Current native Kyros startup0/30/90 was compared separately; see
research/kyros_current_curvefixed_startup.json. Kyros/Japan720 workers remain
pending; inspect authoritative terminals before qualification. No Quartus.


### P5 death/game-over oracle and current native Kyros — 2026-10-09

Source revision 75fc12f01f3977d6289485f92d919c0d04d65dfd. Current native
Kyros completed 720 fields, exit 0: all fields contain 57,344 unique pixels,
zero unmapped accesses, deadline misses or row overflows; worst line 2,280
cycles. All six canonical checkpoints 0/30/90/240/360/600 match MAME exactly.
Evidence: research/kyros_current720_curvefixed_exit.json and
research/kyros_current720_qualification.json. This is a finite boot/coin/start/
play check of the corrected design, not death/reset or broad MAME_EXACT.

The real MAME hard-DIP idle-input oracle completed 7,200 fields with IN1=206
in every row, 38 canonical checkpoints, exit 0 and no Lua errors. Observed
knockdown at 2640, continue at 2880/3120, PLAYER-1 GAME OVER at 3360 and
title transition at 3600 bound the requested sequence. No RAM/CPU patches.
See docs/KYROS_DEATH_REFERENCE.md, derived Lua/generator and
research/kyros_idle_death7200_v2_exit.json. Initial unqualified-port Lua
failure and the generic DIP-column validator correction are preserved.

Started the actual RTL 3,601-field replay, using the known executable
54529234af5aa50cb1d486d8f037a7dd8496b0da0f83e399b0cf8eb2094498cf,
recorded port override and a dedicated executable copy. Worker 131142.
Authoritative job/terminal: research/kyros_idle_death3601_job.json and
research/kyros_idle_death3601_exit.json. Native game-over qualification is
pending. Japan's current 720-field run remains pending its checked terminal.

Updated AGENTS.md and plan.md to require the shared host-wide FIFO and one
lease across selected stages/children, never separate stage queue jobs or
raw tools. The permanent two-job limit and explicit final RBF gates apply.
Quartus remains fully disabled. No tool from that flow was invoked.

Next: inspect Japan terminal and the long replay's decisive checkpoints;
continue remaining hit/pickup/reset and Stingray integration. Timing/resource,
paired fidelity, remaining feature runtime and final hardware gates stay open.


### P5 current Japan terminal and ordered sound writes — 2026-10-09

Base revision 1f61239. Current native Kyros Japan completed 720 fields, exit 0,
with 57,344 unique pixels per field, no unmapped accesses, deadline misses or
row overflows, and worst line 2,280 cycles. Canonical MAME checkpoints
0/30/90/240/360/600 all match pixel-for-pixel. ELF remains
54529234af5aa50cb1d486d8f037a7dd8496b0da0f83e399b0cf8eb2094498cf.
Evidence: research/kyrosj_current720_curvefixed_exit.json and
research/kyrosj_current720_qualification.json. Finite boot/coin/start/play
scope only; no Japan long attract/death/reset or broad MAME_EXACT claim.

Added scripts/compare_sound_events.py and docs/SOUND_EVENT_COMPARISON.md.
The bounded comparator preserves ordered accepted writes, reports field
labels separately and exits 2 on unequal event streams. Applied to the first
139 completed native hard-DIP fields: all 114 chip-port writes and four main
sound-latch commands match MAME, including field labels. Evidence:
research/kyros_idle_sound_prefix.json. This window precedes start; it does
not qualify combat/death effects. The long native replay remains pending
under worker 131142 / simulation 131144; it was confirmed live this turn.

Next: finish and compare the long death/continue/game-over sequence, inspect
its sound-event windows, then remaining hit/pickup/jump and warm reset.
Stingray MCU/real gameplay, remaining runtime features, broad paired fidelity,
complete timing/resources and final hardware remain open. Quartus disabled.


### P5 real warm-reset scenario and build — 2026-10-09

Base revision 781bfd9. Added a guarded MAME recorder derivation and explicit
native --warm-reset-after field option. Field 300 releases legal controls and
resets the game; recording/replay then repeat real coin/start/combat. No game
RAM/register patches, ROM reload or fake CPU. Native hold asserts cleared
CPU transaction counters, YM write counter, DAC latch and mixed sample.
Changed sim/system_main.cpp and three reset generator/worker scripts;
docs/KYROS_WARM_RESET.md describes scope and expected evidence.

Initial generator assertion failed before MAME launch because a status-flush
block separates the input call and frame increment. Fixed its guarded anchor
while preserving the block. Both original failure logs are retained.
The actual Verilator build completed exit 0, ELF
88935c4fecb0dd98d5c4f60611122801e0c57bb494f5242e931059f10f6d2c03.
Its worker then stopped on the absent MAME reference, launching no native run.
Verified unchanged harness against the authentic build manifest and retained
the executable/manifest in research/kyros_warm_reset960_build_recovery.json.
The second native attempt can reuse that build; no repeated build needed.

Corrected MAME worker 17544 was launched with durable job/terminal receipts.
Reset recovery remains pending actual completed replay and comparisons.
Death/game-over simulation 131144 was separately confirmed live; its known
executable copy is unaffected by the new harness build. Quartus remains
disabled; timing/resources/final hardware and all other open gates remain.

#### Recorder reset lifecycle and valid reference — same phase

The first MAME process exited 0 but its capture failed: autoboot reattached
the recorder four times after soft reset, reopened files, left 282 rows and
NUL bytes in reset_events.csv. Kept its failed receipt and exact loaded Lua.
Added a persistent Lua attachment guard. This is recorder lifecycle behavior,
not a newly claimed MAME game bug. The fresh reference completed 960 ordered
fields, one attachment, no Lua errors and reset markers at 300/301. Canonical
normalization produced 35 official-PNG-derived checkpoints. Evidence:
research/kyros_warm_reset960_refv2_mame_exit.json and normalization receipt.

Verified prepared build/manifest hashes, then launched native worker 132353 /
simulation 132355 with recorded neutral controls and --warm-reset-after 300.
Both handles were confirmed live, as was death replay 131144. No second RTL
build was performed. New native job/input manifest/verification receipts bind
the actual executable and reference. Native post-reset recovery and event/
graphics comparisons remain pending; no reset pass claimed. Next: inspect
the actual reset hold and post-reset checkpoints, then complete death effects
and remaining combat/pickup coverage. Quartus remains fully disabled.


### P5 reset hold, combat recording and DAC trace — 2026-10-09

Base revision 7dce75a. The actual native reset pulse at field 300 cleared main/
sound transaction counters, YM write counter, DAC (152 to 0) and signed mixed
sample (-7988 to 0), with cold_reset/downloading remaining 0. Early recovery
is NOT qualified: canonical graphics differ by 390 pixels at 330 and 2,104
at 360. Ordered CPU sound writes through 359 match (214 chip writes, five
main sound commands, identical field labels). Preserve and diagnose:
research/kyros_warm_reset_early_recovery.json and
research/kyros_warm_reset_sound360.json. Both reset and death jobs remain
live; the latter's first 600 fields match 114 chip writes/seven main commands.

Added a guarded legal-input combat recorder. Its first derivation removed
the dump helper and failed at the first snapshot; kept failed receipt/capture/
exact Lua. Corrected boundary preserves the helper. Fresh real-MAME recording
completed 3,600 ordered fields, exit 0, no Lua errors, DIPs 142. Visually
observed score progression 200/300/500/800 at 1200/2400/3000/3599. Normalized
66 official-PNG canonical checkpoints. Pickup/jump outcome coverage remains
open; planned button presses alone do not establish outcomes.

Started actual native combat worker 133634 / simulation 133636 from the
verified executable copy, with read-only DAC bus/PCM tracing; no new RTL build
or program/state patches. Both trace filters and control bits were checked
against primary local MAME/board sources. Extended compare_sound_events.py
to include real DAC writes and declare unavailable DAC capture explicitly.
First 60 native combat fields match 100 chip writes and two DAC writes, with
no main sound commands in that window. Evidence:
research/kyros_combat_sound60.json, native job/input hashes and
research/kyros_combat3600_phase_verification.json.
See docs/KYROS_COMBAT_REFERENCE.md for exact recipes and coverage limits.

Next: diagnose post-reset graphics, finish/compare the live combat/death/reset
runs, and establish remaining pickup/jump/effect windows. Original instruction
manual located, but web screenshot retrieval failed; no unread mechanics
claimed. Remaining broad fidelity, Stingray MCU/gameplay, runtime features,
complete timing/resources and hardware remain open. Quartus disabled.


## 2026-10-09 — Quartus resumed; retained background reset diagnosis
Source parent cb65416. The user's explicit resumption is recorded in quartus_hold.json. Strict resource_limits.json and final RBF gates are unchanged. No Quartus compiler stage or RBF ran.
The shared queue admits full compile or pinned registered recipes; it lacks Alpha68k preassembly. A registry-only attempt failed with "Reviewed registry changed". The original registry was restored byte-for-byte to pinned SHA256 d0496cd27fce7c8b92fd57e1f078d0331014742d7d22513d36776abdb91aadc3. Automatic approval review rejected preparing a registry/pin update because it affects the host-wide integrity boundary. Explicit approval is pending. Do not bypass the guard or invoke raw stages.
Local scripts/quartus_preassembly.ps1 and .tcl define the concrete ancestor-guarded map/fit/STA-only recipe. scripts/quartus_develop.py now routes one complete shared-queue job.
The old actual reset960 and frozen330 diagnostic completed exit0. Graphics failures remain recorded. MAME maps background as retained RAM; the RTL now preserves it on warm reset and initializes on power-up/ROM download. The harness exports actual retained RAM/background and accepted writes330..420.
New actual full-system build exited0 and launched421 fields, reset300, dedicated ELF SHA256 46a65f217f6c24f1ba5b5bc6902413bc976ec40b167541ecbe3fb2872813cb2e.
Evidence: docs/BACKGROUND_RESET_DIAGNOSIS.md; research/kyros_background_reset_phase.json; research/kyros_reset_background421_build_exit.json; research/kyros_reset_background421_job.json and source manifest.
Corrected reset, combat3600 and death3601 remain running. No corrected graphics, full resources/timing, Stingray or hardware pass.
Next: compare actual fields330/360/420 and accepted writes; finish combat/death; register/run preassembly only after approval.

Decisive frozen330 result: all8192 sprite RAM bytes and4096 work RAM bytes match MAME exactly; RGB retains390 differing pixels. New replay had112 completed fields at this observation.

## 2026-10-10 — Reset330 corrected; real8748 donor firmware executed
Source parent7e1fea2. Corrected actual CPU field330 matches MAME RGB/sprite/work
RAM exactly; background remains38. Before-fix field330 had390 differing pixels.
Broader checkpoints preserve cold-boot field60 (20835 pixels; final sprite/work
RAM identical) and post-reset360 (2104 pixels; final sprite RAM identical, one
work byte different) as failures. They need accepted-write/raster-time diagnosis,
not an atomic frame match waiver. Latest actual field count and all captured
metric checks are in research/mcu_and_reset_phase_verification.json.

Staged pinned T48 with original license/provenance and only two enabled decoder
write observation ports; reversal proves unchanged CPU/timer logic. Added
alpha68kn_mcu.sv and a standalone firmware probe with six-bit/64-byte data RAM,
1KiB synchronous firmware and9263750Hz fractional oscillator enables. Both
clock inputs use48MHz; donor divide3/five-state timing is preserved.
Verilator build/run exit0.3.5million master cycles yielded exactly675481
oscillator and225160 core enables,2 BUS/10 control writes, one shared write,
three IRQ2 requests, one actual halt/release and zero outside-ROM ticks.
First read response62 released HALT3604 master ticks after the command.
This finite artificial-pin probe is not paired MAME validation or Stingray
gameplay. Production board/files.qip remain unchanged; Kyros bring-up stays first.
Evidence: docs/STINGRAY_MCU_INTERFACE.md; research/t48_probe_*;
research/mcu_and_reset_phase_verification.json. Runtime/build artifacts ignored.

Quartus remains authorized but the Alpha68k preassembly registration approval
is pending. Another project updated the shared registry and its matching pin;
the current valid registry still has no Alpha68k recipe. Do not restore its
historical hash, overwrite other jobs' registration, or bypass the review.
Next: finish reset421 and combat/death, trace raster-time changes at60/360,
then complete Kyros coverage and paired MCU handshakes/production integration.

Staging guards preserved: initial unscoped donor-port declaration matched more than one module and stopped before mutation; scoped adaptation succeeded. Git whitespace check then rejected generated CRLF JSON (exit1); canonical LF repaired it. The successful probe used the copied pre-normalization snapshot in its saved input hashes; the only subsequent source difference is text newline normalization.

The staged whitespace check also identified original donor blank lines at EOF (exit2); trimmed only EOF whitespace and refreshed source pin hashes. The event CSV remains an ignored local capture as required by project policy. Verified donor logic reversal remains exact modulo newline/EOF whitespace.

## 2026-10-10 — Corrected reset421 terminal evidence
Parent84c75e4. Actual CPU replay exited0, completed421 fields, 0 invalid metric fields; worst line 2280 master ticks. RGB checkpoint failures/pass counts and retained-RAM differences are preserved in research/kyros_reset_background421_verification.json. Sound event comparator exit0; evidence research/kyros_reset_background421_sound_comparison.json (scope ordered chip/main writes; DAC capture unavailable for this reset run). Field330 correction is verified; field60/360 remain graphics failures pending actual write/raster-time proof. No complete Kyros/game/hardware gate is closed.

## 2026-10-10 - Actual backdrop timing and fresh MAME raster records
Parent e3c055f. Added only read-only accepted-backdrop logging to the actual CPU harness; real61-field run completed exit0 with no invalid metrics. Field60 native write64->80 at99,97 and ROM PROMs reconstruct every57344 pixel exactly. Canonical atomic image failure20835 remains; fresh MAME timed write81,97 leaves18 pixels different, so horizontal bus phase is still open.
MAME third capture adds X from the existing Y,X beam helper, reproducing361 state rows,741506 original events and60/300/330/360 displayed images. Earlier unsupported hpos/vpos callback attempts had zero coverage despite exit0; both are preserved as failures. Complete sprite write comparison includes positions/tiles1/2/3; the initial incomplete area filter is retained as invalid.10452 ordered writes match, one sentinel write relocates across VBlank and two MAME end-window writes remain; field360 still needs timed renderer proof.
The first copied MAME command accidentally overwrote the original WAV with361 fields. Preserved that file in the new capture, regenerated960 fields separately, verified all960 state rows/35 images and complete361-field PCM prefix, and restored a freshly qualified960 WAV. Copying launch recipes now retargets recording outputs. See docs/RASTER_TIMING_DIAGNOSIS.md and the causal, raster361_v3, write-stream/gap and audio-recovery verification JSONs. No graphics-wide, physical, Quartus or RBF pass is claimed. Queue registration approval remains pending; continue CPU instruction/bus-phase and dynamic renderer diagnosis, then finish combat/death coverage.

## 2026-10-10 - Completed real combat/death runs and retained failures

Parent f6dbcd3. Verified terminal receipts: death3601 and combat3600 both exited0.
All actual field metrics pass (57,344 unique pixels, zero unmapped/deadline/
overflow/duplicates, worst2280 master ticks). Canonical sampled images:
death19 exact/1 differing/3 unavailable; combat56 exact/7 differing/3 unavailable.
Missing checkpoints119/179/1799 were not saved by the original RTL schedule.
No graphics gate is closed. See docs/LONG_GAMEPLAY_EVIDENCE.md and the complete
research/*verification.json records. Verifier separates image availability
from execution metrics and intentionally exits1 for incomplete/failed graphics.

Death ordered sound/latch streams match. Combat main latch157 and DAC42,246
writes match in order; chip I/O22,418-write sequence differs beginning index896,
field787. This is an open comparison failure, not an asserted MAME bug; no
PCM/effects or whole-game audio pass. Decisive comparator exit2 and both
receipts retained. Next diagnose that first sound difference and B16 raster
timing, incorporate missing images into the next necessary native run, then
complete Kyros/Japan and real Stingray MCU board integration. No Quartus stage
or RBF executed; host-wide recipe/trust-pin approval still pending.

### 2026-10-10 - Combat sound chip projection

Parent60018db. All finite within-chip port and decoded register sequences match: YM2203 10,404 / AY1 3,142 / AY2 8,872. Global interleaving comparison remains failed; YM2203 has seven field-label differences. Source map/hash, complete evidence and diagnostic scope are in docs/LONG_GAMEPLAY_EVIDENCE.md and research/kyros_combat3600_sound_interleaving.json. This narrows the next audio diagnosis to inter-chip scheduling/write phase and PCM, without relaxing B03/B04 or changing clocks. Canonical graphics failures/missing checkpoints remain open.

### 2026-10-10 - B16 field360 actual timed renderer proof

Parent2d326a5. Actual10,453 accepted sprite writes reconstruct final360 RAM exactly; recorded reset/master phase predicts every raster coordinate. Actual renderer replay through30 full fields matches every57,344 native360 pixel; exit0,7,920 completed lines, worst2,280 ticks,0 deadline/overflow. Canonical atomic MAME360 still differs2,104 pixels and is not waived. First exact-image run exited1 on an inherited225-line static guard; preserved it and corrected only the full-raster count264*30. Fixed target background64 and isolated SDRAM refresh/controller-state limits are explicit in docs/RESET360_TIMED_RENDERER.md. Complete evidence in research/kyros_reset360_timed_renderer_verification.json. Next use fresh MAME hpos write history and primary CPU/write-phase evidence; no DUT clock/RTL/ROM changes or Quartus/RBF execution.

### 2026-10-10 - B16 MAME-timed field360 and executed backdrop instruction

Parentfb5f1c8. Fresh361-field exact-clock MAME observer reproduces all361 states,741,506 old events and15 canonical images. CURPC identifies field60 backdrop MOVE.B at0x1AE34 (13FC005000060001); native bus phase remains open. MAME10,455 timed sprite writes reconstruct identical start/end RAM and, through the exact qualified real-renderer ELF, match all57,344 native360 pixels, just as native10,453-write replay does. Exit0,7,920 lines,0 deadline/overflow. Atomic MAME360 difference2,104 is retained; finite time-aware field360 agreement is proven under documented projection/background/controller limits, not all-game or physical timing. See docs/MAME_CLOCKED_RESET_EVIDENCE.md and research/kyros_reset360_mame_timed_renderer_verification.json. Next native instruction/bus-phase trace for backdrop60, then time-aware combat/field900 coverage.

## 2026-10-10 - Native instruction probe built; recovery documented

Parent9624866. Added read-only accepted-bus/root-register observation for fields59/60; actual Ubuntu build exit0, dedicated ELF c533e330d5700f1a6172405f76947c5f3e22d2fc4d9e049e3ed2e8e3cf35732d. Corrected real61-field run PID159138 was verified live with intended separate capture/ELF. Terminal metrics/instruction qualification pending. Windows-only setup error and copied hard-coded output error preserved; wrong run terminated-15 and mixed background61 capture quarantined, so that original live capture path requires explicit requalification. Recovered its original ELF with matching receipt hash. See docs/NATIVE_INSTRUCTION60_OBSERVER.md and corresponding pending/recovery receipts. Current loaded runner source frozen; fail-fast Windows guard added for future use. No game RTL/clocks/ROM, Quartus or RBF changes. Next qualify probe and recover fresh capture before bus-phase diagnosis.

Recovery follow-up: the wrong-output clone also overwrote the original background61 input manifest. Restored its exact committed bytes after verifying its C++ source hash against the frozen EBeTXF build source; original ELF likewise matches its old receipt. Mixed capture requalification remains pending. No unrelated edit was reverted.

## 2026-10-10 - Native instruction61 terminal and capture requalification

Parent9d01556. Actual61-field probe exited0, all metrics pass; sole manifest change is read-only system_main.cpp observer. All saved images match archived image files; independent reset421 fields0/30/60 match. Qualified fresh capture restored to original background61 path with explicit new source-ELF marker, old mixed archive retained. Native MOVE.B context Ird13FC/PC1AE3C/FC5 matches MAME operation; preceding work-store to backdrop interval is160 master ticks in both. Offset predates this instruction, so no timing/clock correction is supported here. Backdrop18-pixel timed difference remains open; earlier interrupt/start phase is next. Full bus/image/source proof in research/kyros_instruction60_diagnostic_verification.json and fresh replacement record. No Quartus/RBF or game RTL changes.

### 2026-10-10 - B16 IRQ context upstream of backdrop

Parent831dfcf. Four actual IRQ stack/vector contexts qualify field60 savedPC/SR/stack equivalence; field59 savedPC854 versus858 is retained (diagnostic exit1). Both vector streams occupy80-master-tick grids, corroborated by10-CPU-clock VPA/E synchronization in primary sources. Local frame pacing differs -8/-8/+56/-8 ticks. No physical phase/root-cause or supported clock/IRQ fix is claimed. See docs/IRQ_TIMING_CONTEXT.md and full context/source-grid receipts. Backdrop18 timed pixels remain open. Continue other required bug/graphics coverage, addressing simulator throughput for efficient later-stage execution.
### 2026-10-10 — Qualified real-system host evaluation reduction

Parent e99e548. Added compiler-only gprof build/launcher and explicit neutral
pause/rotation/hiscore inputs plus a missing fx68k runtime-ROM guard in
`sim/system_main.cpp`. Profile attempts 1–3 are invalid: isolated CWD lacked
`microrom.mem`/`nanorom.mem`, with explicit startup warnings and zero CPU
transactions. Profiling flags or game clocks were not established causes.
The launcher now stages and hashes those files. Changed the host tick loop
to omit its second settled half-cycle evaluation only when SDRAM DQ did not
change; retained every actual master edge and device sample, unchanged RTL.

Actual five-field attempts 4 and 5 exit0 and match the earlier native CPU
capture in all 15 RGB/RAM assets, counters/state, accepted bus/audio events,
legal inputs and PCM prefix. Decisive receipt:
`research/system_profile_pair_verification.json`; matched-pair instrumented
wall times 28.105947 s and 17.783467 s. See `docs/SYSTEM_PROFILE.md` for
source/capture handles and limits. This is finite boot-equivalence evidence,
not full gameplay or general throughput qualification. Capsule stats/gain
each attempted once; budget hook withheld both. No savings claim.

Next: qualify the efficient harness on later actual CPU/gameplay cases and
continue the open graphics/bug checks, then Japan and real T48 integration.
Quartus permission is resumed, but the exact preassembly shared registry
change remains awaiting explicit human approval after automatic rejection;
no compiler stage, fitted resource claim or RBF has run in this phase.
### 2026-10-10 — Native host improvement qualified through field60

Parent a0ad21d. New Linux-only, isolated, overwrite-resistant
`scripts/run_system_equivalence61.py` rebuilds the normal native system,
preserves a private ELF/runtime microcode copy and compares the actual run
with `kyros_instruction60_diagnostic`. Actual 61-field exit0; all fields
57,344 unique pixels, zero unmapped/duplicate/deadline/overflow failures.
All 57 checkpoint assets and complete frame/state/bus/epoch/instruction/
audio events, WAV, audio statistics, legal input log and final RAM are
byte-identical to that prior real CPU capture. Runtime 120.852041 s.
Decisive receipt `research/kyros_system_equivalence61_verification.json`;
ELF 03c331692e0329865833b84f03869053dc014ff642993c089c74a23fe8f80885.
Updated `docs/SYSTEM_PROFILE.md`; no game RTL or clock change. Field59 IRQ
and field60 MAME backdrop differences remain intact, not waived. Next:
continue required graphics/bug and gameplay checks using the qualified
efficient harness, followed by Japan and T48 production integration.
### 2026-10-10 — Six combat HUD cases explained by measured late writes

Parent 8b771c4. `scripts/diagnose_combat_hud.py` maps every differing pixel
in fields900/1020/2100/2220/3180/3300 to four HUD words and position0x406C2;
every final opaque decoded layer matches MAME RGB. Ownership report
`research/combat_hud_ownership.json` retains pixel/layer data and asset pins.
Added accepted-write observations for those words and RAM/RGB checkpoints
119/179/1799 to the real system harness; no game RTL, ports or clocks changed.

Qualified a fresh real MAME exact-clock combat oracle: 3600 states, 66 RGB
checkpoints, full WAV and all 8,085,201 original event rows match v2 exactly.
Receipt `research/kyros_combat3600_clocked_verification.json`. First foreground
reduction stopped incompletely; no surviving process and no verified exit
code/cause. Preserved partial CSV/source hashes in the attempt1 failure
receipt. Separately logged v2 background reduction completed: 7761 writes,
all target final RAM words/position reconstructed exactly, all changed HUD
writes after the affected raster rows. See `combat_hud_mame_timing_v2.json`.

Rebuilt the stale actual renderer fixture. Replacing only target HUD words
with independently measured earlier MAME values yields exact complete RGB
agreement with the actual CPU image in all six cases: six exit0, each57344
pixels, zero decode/oracle/renderer mismatch, zero deadline/overflow failures.
Receipt `research/combat_hud_prewrite_fixtures_verification.json`; nine shared
source pins equal the current actual-system build and all eleven fixture pins
match the checkout. Updated `docs/COMBAT_HUD_DIAGNOSIS.md` with recovery paths,
measured words and scope limits. Atomic MAME differences and field60 backdrop
phase residual remain recorded, not waived.

Actual `kyros_combat_hud3301` worker is running; Linux PID166747 and its exact
ELF/ROM/3301-field/input command were revalidated through /proc. Latest observed
completed field652; do not infer terminal state from a timeout or progress
file. Its completed119/179 checkpoints match MAME RGB, sprite RAM and work RAM
byte-for-byte; finite receipt `kyros_combat_hud3301_checkpoints119_179.json`.
Next: finish this same actual run, preserve terminal receipts, qualify all
native-baseline comparisons and1799, then compare actual accepted HUD writes
and RAM with the measured MAME timeline. No Quartus stage/RBF ran. Capsule
stats/gain each attempted once in this turn; budget hook withheld both.
### 2026-10-10 — Actual native HUD causality confirmed at900/1020

Parent5457632. Added `scripts/verify_combat_hud_native_causality.py` to merge
accepted active UDS/LDS writes, track known bits and require stable completed
checkpoints. Both finite actual cases pass: earlier words match the measured
MAME values, changed writes occur after affected raster rows, native write
timelines reconstruct retained RAM, final words/position agree with MAME,
both complete sprite RAMs are identical and new RGB equals the previous
actual CPU/renderer target. Native900 changes0x40EEA 0014→0016 at raw49,241;
native1020 changes0x40EF0 0017→0014→0019 at56,307 and56,345. Decisive receipts
`research/combat_hud_native_causality_through900.json` and `...through1020.json`;
terminal_run_qualified=false is retained. The same3301-field worker is live;
latest observed completed field1312. Do not replace/restart this worker.

Consulted the applicable canonical FX68K strobe-commit lesson8926; IRQ/strobe
interpretation remains separate. Manufacturer manual confirms E period10CPU
clocks (6low/4high), unspecified power-up ring phase and pending interrupt
recognition between instructions. Added reference/limits to
`docs/IRQ_TIMING_CONTEXT.md` and pins in `mc68000_e_clock_reference.json`.
The web source was readable; native PDF staging returned404, so no local PDF
or source hash is claimed. No RTL clock/reset change or phase-fitting was
made; field60 remains open. Two Capsule EPERM reports did not prove checker
nonexecution: the existing receipt was preserved and inspected through the
working native runner; duplicate execution was refused. Updated HUD docs.

Next: finish the same real run, qualify1799/full native prefix and the four
remaining accepted-write cases, then continue required Kyros bug/action
coverage. No Quartus/RBF ran. Capsule stats and gain each attempted once;
budget hook withheld both, with no cost/context savings claim.
### 2026-10-10 — Final missing combat checkpoint1799 captured

Parentd8c33f5. Same actual3301-field CPU run, observed complete through1852.
Stable1799 compares exactly to qualified MAME in all57344 RGB pixels and
all8192 sprite-RAM bytes. Work RAM differs at exactly one byte, offset0xFF3 /
CPU0x20FF3: native0x92 versus MAME0x8E. Cause remains unproved; no whole
work-RAM equality claim. Source-pinned receipts:
`research/kyros_combat_hud3301_checkpoint1799.json` and
`...checkpoint1799_work_difference.json`. Updated HUD diagnosis and plan.
All three previously missing mandatory combat images119/179/1799 are now
captured from the actual CPU and have zero canonical RGB mismatch. Remaining
four native HUD causality cases, terminal/full-prefix qualification and the
field60 timing residual remain open. Continue the same worker; no restart,
RTL clock/reset change, Quartus stage or RBF was performed.
### 2026-10-10 — Four actual native HUD cases qualified

Parentb87aeb2. Same actual CPU run now passes cumulative causal checks through
2100 and2220. Accepted known-byte writes reconstruct retained relevant RAM,
earlier values agree with independently recorded MAME values, every changed
write is after affected rows, full sprite RAM matches MAME and actual RGB
matches the qualified complete renderer target. Decisive receipts:
`research/combat_hud_native_causality_through2100.json` and
`...through2220.json`, both terminal_run_qualified=false. Four of six cases
are qualified;3180/3300 and terminal/native-prefix qualification remain open.
Latest observed completed field2871. The board RAM source was inspected:
arrays are initialized once, not repeatedly reset; no inferred RAM-reset
problem or RTL change was introduced. Updated HUD diagnosis, plan and B16.
Continue the original worker; no restart, Quartus stage or RBF was performed.
# 2026-10-10 — Terminal3301 native run and all six HUD cases qualified

Source parent `aacb98f`. The existing actual worker completed3301 fields,
exit0, executable SHA256
`864ebb2c2e73ca7f743238e4eaf26dd7acd8b5bbaf6845a4a8795b71d203fffa`.
All136 comparisons against the prior actual native combat prefix pass,
including all3301 field metrics, retained RGB, capped bus trace, legal input,
ordered audio events and full PCM prefix. Runtime6611.523 seconds. Every
field has57344 pixels and zero unmapped transactions, duplicate pixels,
deadline misses or row overflows; worst line2280 cycles.
Evidence: `research/kyros_combat_hud3301_exit.json`,
`research/kyros_combat_hud3301_verification.json`, frozen source/runtime
manifests and original private ELF/capture retained in the ignored directory.

New cumulative native HUD receipts through3180 and3300 pass. Final receipt
records terminal qualification and all six900/1020/2100/2220/3180/3300 cases.
Actual accepted writes reconstruct retained RAM, match independently
measured MAME earlier/final values, and change HUD words after affected
scanlines; actual full RGB matches the complete temporal renderer fixtures.
Original atomic MAME image differences are retained. This closes those six
HUD explanations without changing RTL or introducing screenshot masks.

Added `scripts/diagnose_combat1799_stack.py` to pin the sole1799 RAM byte and
ROM/unidasm evidence. Its candidate saved PCs0x9e92/0x9e8e are adjacent
TST/BEQ wait-loop instructions, with identical SR0x2004 and following JSR
return0x9dde. `research/combat1799_stack_interpretation.json` retains the
raw difference and explicitly limits this to snapshot/source interpretation;
native stack-write timing and physical phase cause are not proved.
Updated `docs/COMBAT_HUD_DIAGNOSIS.md` and `plan.md`. Next: remaining finite
timing/fidelity cases and required Kyros stage5/ending/feature coverage.
Japan/Stingray production completion and fitted resource/timing gates remain
open. No Quartus stage or RBF ran in this phase.

The user again explicitly resumed Quartus use on2026-10-10. The control hold
is already released. Automatic approval review rejected correcting the stale
AGENTS suspension paragraph, treating its previous text as authoritative;
specific correction approval was requested. Shared preassembly registry
approval also remains pending. Neither shared boundary was modified.
# 2026-10-10 — Finite late-scene discovery captured; first route stayed early

Source parent4d0fe55. Added `capture_late_scene_candidates.lua` and
`record_late_scene_candidates.py`. Real MAME0.289 completed36000 fields,
exit0, all six integrity checks pass,122 complete snapshots,60.94 seconds.
Every observed field is retained in CSV; finite PNG/RGB/sprite/work assets
are source-hashed in `kyros_late_scene_candidates36000_verification.json`.
Explicit fixture RAM writes are logged separately; this is not legal RTL
gameplay or a late-scene pass. Images6000/18000/35999 stayed in the first
outdoor area; the raw-up route presses the player against the right edge.
Next test the raw-left route and identify actual late scenes before renderer
comparison. B01/B02 remain open.

Official current cheat archive download was HTTP403 via urllib and native
curl. An ignored historical imame4all archive was successfully staged;
`late_scene_cheat_historical_definitions.json` pins source/selected XML and
contains health/ammo/rollkick/speed candidates but no level select.
`docs/LATE_SCENE_FIXTURES.md` records scope and source/input-order limits.
The launcher tool returned EPERM after actually starting the worker; native
runner inspection recovered PID41008/MAME2860 and terminal evidence without
a duplicate launch. No Quartus or RBF ran; prior approval requests remain
pending. `scripts/complete_research.py` is preserved as an unowned change.
# 2026-10-10 — Raw-left fixture route observed and rejected for progression

Parent9de0fbd. Added an explicit route argument and distinct namespace,
preserving the completed first run. The3600-field raw-left MAME probe
completed exit0, all six capture-integrity checks pass,6.196 seconds.
Actual900/3599 PNGs show the first courtyard's left edge, not later scenes;
the raw-left/displayed-up hypothesis is not supported. No input RTL fix or
B01/B02 acceptance follows. Job/exit/verification receipts:
`research/kyros_late_scene_candidates3600_raw_left_*.json`.
Tool EPERM again occurred after successful execution; terminal receipts
were inspected through the native runner rather than restarting the run.
Next remove sideways steering from raw-up in a separate centered-up route.
# 2026-10-10 — Centered-up fixture traversal completed; late scenes still open

Parenta504d58. Added the centered-up route with its own namespace. Actual
MAME completed36000 fields, exit0, all six integrity checks pass,64.207
seconds. Actual24000/35999 images remained in the first outdoor area against
the right edge, so removing sideways steering did not reach stage5/ending.
Receipts: `research/kyros_late_scene_candidates36000_centered_up_*.json`.
Actual worker29376/MAME57452 were observed live at25800 before the terminal
receipt; no process was restarted after an observation failure. The earlier
raw-left phase commit did succeed despite Capsule EPERM, confirmed HEAD
a504d58. Next test pure raw bit2; do not infer a production input fix or a
late-scene pass from these isolated fixture traversals. No Quartus/RBF ran.
# 2026-10-10 — Centered-right fixture route retained; central path next

Parent8e3f2c0. Actual centered-right MAME traversal completed36000 fields,
exit0, all six integrity checks pass,61.900 seconds. Images19800/35999 show
the first courtyard's lower/right corner, so this is not stage5/ending.
Receipts: `research/kyros_late_scene_candidates36000_centered_right_*.json`.
Worker33812/MAME7108 were confirmed live at20400 before terminal evidence.
Next alternate raw bits0/1 to test a central-stairs route; do not replace
earlier evidence or conflate asset integrity with scene/game acceptance.
No Quartus or RBF ran; the full goal and its remaining gates remain active.
# 2026-10-10 — Route sweep closed; ROM scene-selector evidence staged

Parent743c1d7. The6000-field stairs-zigzag MAME attempt completed exit0,
all six integrity checks pass,11.321 seconds. Actual5999 remains in the
initial outdoor area. This closes the blind route attempts without claiming
B01/B02; no further route sweep is planned. Retained job/exit/verification:
`research/kyros_late_scene_candidates6000_stairs_zigzag_*.json`.

Cached official unidasm output for the131072-byte pinned Kyros program ROM;
tool, ROM and ignored disassembly hashes are in
`research/kyros_rom_disassembly_candidates.json`. Source rejects20912 as a
stage selector (four-object iteration loop). Byte($101,A6) instead advances
3,1,2,4,5,3 and selects scene-entry background color; exact instructions,
the candidate CPU address20101 and limits are retained in
`research/kyros_scene_selector_analysis.json`. MAME's stack state name is
SP, confirmed in its0.289 CPU source.

Next trace that scene initialization and prepare a guarded MAME-only
debugger fixture for the fifth scene, requiring valid CPU/return-stack
context. No PC redirection has been performed. Scene identity, stage5 lamp/
block and ending coverage, full renderer comparison and whole-game/core
acceptance remain open. No production RTL, Quartus stage or RBF changed.
# 2026-10-10 — Guarded candidate5 scene reaches corridor; full renderer exact

Source parent361e94e. Added guarded MAME-only candidate5 setup at1a66;
actual frame900 has PC9e90/SR2014/A6=20000/SP20ff4/return9dde before selector
3->5 and the PC redirect. The source transition setup is executed by actual
MAME CPUs. All2400 fields and10 snapshots pass integrity checks. Scene
images1200/2399 show a lamp/flame corridor; this is fixture RAM/register
preparation, not real RTL CPU gameplay acceptance. Source/command/setup:
`research/kyros_late_scene_candidates2400_centered_up_scene5_*.json`.

Added `verify_late_scene_renderer.py`: reused private real renderer/SDRAM
ELF39b91147..., all11 source pins current and9 shared native DUT pins equal.
All57344 pixels match MAME at1200/1500/1800/2100/2399; decoder comparison,
deadlines and overflow checks also pass. No renderer/DUT rebuild or RTL
change. Receipt: `research/kyros_candidate5_entry_renderer_verification.json`.

Added one separate RAM-only obsolete-color-filter negative probe at1500.
Despite4 clipped color-ff tiles, suppression changes zero visible pixels;
`research/kyros_candidate5_color_ff_suppression.json` records passed=false.
Do not qualify B01 from a vacuous tile counter. The later visible head/lamp
and block region, Japan counterpart and ending are still required.
MAME Testers attachments failed web retrieval; no reference-image identity
claim. Updated `mamebug.md`, `docs/LATE_SCENE_FIXTURES.md` and partial
`docs/bug_coverage.json`. Next reach the corridor's later visible regression
region or identify its camera state from source. Full goal remains active;
Quartus/RBF, fitted resource/timing and hardware gates remain unqualified.
# 2026-10-10 — Corridor frames exact; ROM supplies a late-room descriptor

Parent1aecd8f. The moving selector5 corridor capture completes12000 actual
MAME fields, all seven integrity/setup checks pass. Actual renderer/SDRAM
fields3000/6000/9000/11999 each match all57344 MAME pixels; clipped ff tiles
16/28/28/32. A separate obsolete-predicate RAM fault probe at11999 still
changes zero visible pixels and remains passed=false. Evidence:
`kyros_late_scene_candidates12000_corridor_scene5_moving_*.json`,
`kyros_candidate5_corridor_renderer_*.json` and
`kyros_candidate5_corridor_renderer_color_ff_suppression_011999.json`.
No B01 coverage waiver. Added finite field/label selection to the fixture
helpers without changing their positive/negative checks or the private RTL.

ROM room-entry1b90 selects an8-byte descriptor based on scene and room
cursor. Scene5 records8/9 are identical090060b068f00000: room0900, spawn60b0,
layout68/flagsf0. It stores those fields, calls1400 and branches1660, which
re-enters1ac2 for a live player. Exact source/table evidence:
`research/kyros_scene5_room_descriptors.json`. Next perform that source-led
late-room setup only from the validated MAME CPU/return-stack context and
seek a nonvacuous visible lamp/block regression. No production RTL, Quartus
or RBF changed; Japan, ending and complete-core gates remain open.
# 2026-10-10 — Earned-score v3 reset succeeds; donor restore still fails

Source phase parent 82162ff. The completed real-HPS 901-field earned-score
run exited 1: `real donor reload failed after CPU-cleared score`. Its final
read-only reset observation is step2763, best0, first1, last2: the extended
reset bound reached actual CPU initialization. The saved178-byte earned
dump ends in BCD2000. This proves extraction and reset readiness, not
restoration or persistence. Evidence: `research/kyros_earned_wrapper901_v3_exit.json`,
the corresponding run log, and the ignored capture's `reset_probe.csv` and
`earned.nvm`. No score-protocol pass or final acceptance is claimed.

Next inspect the pinned donor's reset/download transition and add a focused
restore diagnostic before another full gameplay replay. Production RTL,
Quartus and RBF remain unchanged. Added `scripts/diagnose_earned_restore.py`
to preserve the terminal observations and relevant donor source transitions.
# 2026-10-10 — Source-led earned-score protocol repair prepared

The pinned donor only arms restoration on a reset falling edge when
`downloaded_dump` is already true (hiscore.v:379); completing a download
only sets that flag (357). Its SM_TIMER also stops under external manual
pause unless its own pause request is active. Failed v3 downloaded after
reset and then retained manual pause while waiting. These are test-protocol
errors, not evidence of a production RAM/CPU fault.

Added `scripts/prepare_earned_wrapper_v4.py`: preserve v3, load the actual
CPU-earned dump before reset, independently observe CPU-cleared best, release
manual pause, and journal the real donor until completion. The donor's actual
configured start/end checks remain active, and all178 restored bytes and
earned best must match. No synthetic writes or production RTL changes.
The repaired real-HPS run remains unverified until its terminal receipt.
# 2026-10-10 — Earned-score v4 launched; host benchmark and audio evidence retained

Prepared v4 source pins in `research/kyros_earned_wrapper_source_v4.json`
and launched its owned worker16091/build16093. Both were independently
observed live while building; no v4 simulation or restore pass yet. Follow
`research/kyros_earned_wrapper901_v4_job.json` and its terminal receipts;
never restart from an observation timeout. Separate v1/v2/v3 failures remain
preserved. The production donor/RTL and complete-core acceptance gates are
unchanged; no Quartus or RBF ran.

The earlier private host-compiler A/B benchmark completed: both62-field
real-HPS boots exit0, identical metrics and14 raw core/VGA captures, unchanged
generated-model objects. Baseline149.982s versus candidate156.237s gives
speedup0.959964, so host-O3 was not adopted. This one boot pair is not a
gameplay performance result. The initial ccache-command parser failure and
its repair are preserved in the benchmark failure and v2 receipts. Helper:
`scripts/benchmark_wrapper_host.py`; result:
`research/kyros_wrapper_host_O3_bench62_v2_verification.json`.

Actual3301-field combat audio analysis completes: per-chip writes/data match
MAME (AY1=2818, AY2=7732, YM=9322), global ordering first differs at896,
and seven YM event field labels differ. Native PCM has2677137 samples at
48kHz with zero clipped samples. Early spectral peaks agree closely; the
late29-second nearest-peak discrepancy remains ambiguous and is not a full
pitch/effect-termination pass. Evidence:
`research/kyros_combat_hud3301_sound_interleaving.json` and
`research/kyros_combat_hud3301_audio_spectrum.json`.
# 2026-10-10 — v4 worker stopped before simulation; source-record reference repaired

Source parent2156d55. Authoritative worker16091/build16093 are both absent;
the build receipt is exit0 but there is no simulation PID, log or result.
The worker traceback is FileNotFoundError for the v4 manifest. Its runner
still selected `kyros_earned_wrapper_source_v3.json`, so it compiled the
v3 source instead of v4. No v4 gameplay replay occurred; the copied original
v3 capture and failure evidence remain preserved. The stopped worker's
actual OS exit code was not captured and is not invented.

Repaired `scripts/prepare_earned_wrapper_v4.py` to explicitly replace and
assert the source-record path, with a separate v5 namespace. The proposed
real-donor protocol and production RTL are unchanged. Prepare/launch v5
once, follow its actual process and terminal receipt, then verify earned
score restoration before claiming persistence. No Quartus/RBF ran.
# 2026-10-10 — v5 source namespace verified; terminal verifier extended

Prepared and launched the corrected v5 worker. Its job records the intended
`sim/captures/diagnostics/earned_wrapper_v5/build.sh`; worker18626/build18649
were present in the launch record. Confirm actual process liveness and follow
that job until terminal; no simulation/persistence pass yet. Preserved v4's
stopped-worker evidence in
`research/kyros_earned_wrapper901_v4_prelaunch_failure.json`.

Extended `scripts/verify_kyros_feature_terminal.py` to select each version's
actual executable/manifest. v4/v5 additionally require exact saved/restored
178-byte artifacts with matching earned best, the read-only reset-clear
journal, and monotonic real donor transitions from restoring to complete.
The existing source pins, actual CPU/input/pixel checks and canonical image
comparisons remain required. No acceptance is derived from these checks
until an actual terminal simulation result exists.
# 2026-10-10 — Corrected earned-score v5 build passes; real replay starts

The v5 build exits0. Worker18626 and simulation19893 are independently
observed live (simulation stateR); build18649 is absent after its terminal
receipt. Actual early settled fields4–7 each report core57344/VGA57344 and
zero misses. The earned upload/reset/restore assertions occur after901
gameplay fields and have not executed yet. Follow this existing job through
its terminal receipt; do not restart or claim score persistence from boot.
Evidence: `research/kyros_earned_wrapper901_v5_job.json`,
`research/kyros_earned_wrapper901_v5_build_exit.json` and its run log.
Compiled source parent2156d55 is recorded by the job; later verifier/progress
changes do not alter the production design or this private host's input pins.
Local verifier/namespace repair commit95f0ab5; no Quartus/RBF ran.
# 2026-10-10 — Focused B03 punch-release oracle added during earned replay

Actual combat reference inputs contain426 control transitions with repeated
14-field punches and four-field release gaps. They do not isolate a long
post-punch termination tail. Added `scripts/record_punch_release_reference.py`
to derive the existing legal-input MAME capture: coin/start, one punch at
requested260–273, then released controls through600. Actual port samples,
not the request labels, must show punch261–274 and a fully released tail.
This addresses the open B03 persistence check without modifying game RAM,
CPU registers or production RTL. Capture integrity alone is not a sound or
bug-termination pass; compare the actual effect and real RTL replay next.
The separate earned-score v5 simulation19893 was confirmed live when this
work began and is not restarted. No Quartus/RBF ran.
# 2026-10-10 — Single-punch MAME oracle complete; real CPU replay prepared

`kyros_punch_release601` completes actual MAME exit0, all six capture-integrity
checks pass. Actual pins show one punch pulse261–274 and released controls
through600. This is more than five seconds of released input; sound-effect
activation and termination remain separate required checks. Receipts:
`research/kyros_punch_release601_job.json` and `*_exit.json`.

Added `scripts/run_punch_release_native.py`: normalize the canonical displayed
reference, reuse the exact combat/cocktail-qualified executable only if its
current source pins still match, and replay all601 actual input samples
through real CPUs. Record native metrics/images and per-chip sound sequences
after actual terminal completion, retaining all mismatches. No production
RTL change or redundant model rebuild; B03 is still open until the actual
effect and termination checks pass. Earned-score v5 continues separately.
# 2026-10-10 — Early punch oracle is vacuous; its owned RTL run stopped

Bounded `rg` of actual sound-latch writes proves the601 single-pulse oracle
has the identical command sequence to combat through600: commands at60,
75,103,122,295,376,448. Combat's first repeated0x3535 punch commands begin
at702, then714/732/750, consistent with its18-field button cadence. Thus
the early261–274 pulse did not activate the required punch sound. Capture
integrity is retained, but it cannot qualify B03.

After verifying Linux PID24943's complete argv belongs to this owned601
capture and input file, requested SIGTERM for that child only. Preserved
`research/kyros_punch_release601_native_stop_request.json`; inspect its
terminal receipt next. Earned-score v5 is untouched. Added `--late` to the
MAME recorder: pulse710–723 after observed initialization, total1081 fields,
and require an actual0x3535 command around the pulse before scheduling its
RTL replay. Preserve the early oracle/derived Lua and stopped run; no pass
is inferred from the replacement input sequence. No Quartus/RBF ran.
# 2026-10-10 — Nonvacuous single-punch oracle passes;1081 RTL replay selected

The replacement MAME1081-field capture exits0 and passes all seven checks:
one actual punch pulse711–724, released input725–1080, default DIPs, complete
field sequence, no Lua error and an actual main0x3535 command around the
pulse. This establishes effect-command activation missing from the early
601 capture; it does not yet prove chip noise termination or reset/death.
Receipts: `research/kyros_punch_release1081_job.json` and `*_exit.json`.

Extended the existing native runner with `--late`, gated on that observed
command. Reuse the qualified combat/cocktail executable and exact current
source pins, retain canonical graphics differences, and use the explicit
Ubuntu path for MAME source in post-run sound analysis. The ineffective601
child was stopped after full argv identity verification; preserve its
terminal result. Earned-score v5 continues; no production RTL, Quartus or
RBF changes. Follow the1081 job to actual completion before claiming B03.
# 2026-10-10 — Punch replacement live; early run terminal evidence preserved

Authoritative final observation: early601 worker24933 and simulation24943
are absent, receipt exit-15 after the scoped SIGTERM. Replacement1081
worker25322 and simulation25324 are both live, with early field6 reporting
57344 unique pixels and zero misses. Exact qualified executable/source pins
passed before launch; there was no model rebuild. Earned-score v5 worker18626
and simulation19893 remain live, with field150 core/VGA57344 and zero misses.
Neither current run is terminal or accepted yet. The failed early coverage
attempt, positive MAME replacement and both ongoing jobs are recorded without
graphics masks, artificial game state or a B03 waiver. Updated the canonical
bug catalogue with this finite scope. Follow these exact jobs next; no
Quartus/RBF ran. Source phase parentf53a627; changed helpers, two derived
MAME scripts, bug catalogue, progress and compact receipts are committed locally.
# 2026-10-10 — Punch per-channel observer prepared without changing its inputs

Added `scripts/record_punch_components.py`, deriving the existing read-only
sound hook to measure all nine PSG output channels individually alongside
the six existing source/mix labels. It reuses the proven1081-field Lua and
requires exact input CSV, WAV and sampled raw-image equality against that
oracle. This distinguishes punch-channel envelopes from continuing music;
neither observer fidelity nor register equality alone closes B03. Its finite
MAME run and terminal observer result remain pending at preparation.

Existing score and punch RTL jobs remain live (19893 and25324 respectively);
their last observed fields150/30 had full pixel coverage and zero misses.
No model rebuild or production RTL changes. Moved the finite B03 setup note
under its own canonical catalogue heading. Source phase parenta0efa67;
next inspect the actual observer result and continue both owned replays.


## 2026-10-10 — meatsauce repository migration

Source revision `a0efa67a27d230ee4d89d64ddc01024a0a991cb2`; destination parent `b8d6e8182905d933c577779ebc3a7d3ad376fc8f`. Copied 909 tracked and nonignored working files to `cores/Alpha68k_N`, including the existing script change and new punch component helpers/receipt. Source files were SHA-256 checked during copying. Updated AGENTS.md and the plan working root for the new canonical location. ROMs, donor working copies, generated files and large evidence retain their ignore rules and remain accessible through local junctions/hard links. The original checkout and active simulation paths are retained. No RTL, simulation or Quartus run was needed for this repository-only change. Exact file hashes and recovery paths: `artifacts/git-migration/meatsauce-migration.json` in the original checkout (also available through the new folder's ignored artifacts link). Next action: commit/push this folder to meatsauce main, then continue the recorded simulation work from the canonical game folder.

## 2026-10-10 — Completed CPU replays and parallel Kyros closure

Source parent `6d064db` in the retained recovery checkout. The completed
replays remain authoritative at their recorded recovery paths; migration of
receipts does not create a new simulation run or claim a new source revision.

- Earned-wrapper v5 completed 901 real CPU fields with exit 0. Its actual
  earned-score protocol saved 178 bytes at BCD 2000, observed CPU reset clear
  the best score, and restored every byte through the real HPS donor protocol.
  No synthetic RAM writes. The broader terminal verifier has 16/17 checks
  true; missing canonical captures at fields 119/179 keep finite feature
  acceptance false. Canonical graphics also remain false: field 60 has 20835
  differing pixels and field 900 has 8. Evidence:
  `research/kyros_earned_wrapper901_v5_{exit,feature_terminal}.json`.
- Punch-release completed 1081 real CPU fields with exit 0. All 2750 sound
  writes and their field labels agree (AY1 480, AY2 452, YM 1818).
  The native verification has all five metrics true and all 23 requested
  reference images available, but graphics still fail at fields 60 (20835
  pixels) and 900 (4). The cleanup composition has all 13 checks true, actual
  onset 715/cleanup 733, and the unchanged production-chip output contract.
  Full B03, precise PCM alignment, death/reset, Japan and whole-game
  acceptance remain false or unqualified. Evidence:
  `research/kyros_punch_release1081_native_{exit,verification,sound_interleaving,noise_cleanup}.json`.
- The private 61-field E/VPA observer completed with exit 0. All 15 fidelity
  checks pass, all 19 overlapping RGB images and the instruction trace are
  byte-identical to the earlier CPU probe, and the measured E period is 80
  master ticks. This observation is no timing correction or B16 closure:
  native request acceptance and a MAME memory callback are not yet proved to
  be the same CPU data-sampling edge. Evidence:
  `research/kyros_irq_e_phase61_{build_exit,exit,job,launcher,verification}.json`.

The user explicitly authorized parallel agents. Three workers have disjoint
ownership: a short real wrapper capture of fields 119/179; read-only IRQ/data
sampling-edge diagnosis and its documentation; completed bug/feature records.
The parent owns integration and this progress entry. The previous report turn
provided new terminal evidence that changed the next actions and launched
these concrete tasks. No Quartus, assembly or hardware test ran. Resource and
timing compliance remain unqualified; the shared preassembly trust-registry
approval is still pending. Next integrate the evidence in the canonical
checkout, close the Kyros fidelity gaps, then continue Japan and Super Stingray.

## 2026-10-10 — Missing wrapper images and actual IRQ/depletion evidence closed

Canonical source parent `668ec0ff`; production RTL and clock constraints did
not change. Completed captures use the original recovery source revision and
explicit retained path/hash provenance. No result has been backfilled into a
different capture or rewritten as a broader pass.

The short earned-prefix replay actually exited 0 after 181 fields. All 14
checks pass: every field's statistics and applied input ticks match frozen v5,
all 14 overlapping RGB files are byte-identical, and canonical displayed
fields 119/179 each have zero differences over 57344 pixels. The separate
aggregate has all 32 checks true, with
`finite_earned_protocol_and_capture_coverage_pass=true`. Original v5 receipts
stay immutable. Graphics/full-feature/whole-game acceptance remain false:
field 60 still differs by 20835 pixels and field 900 by 8. Evidence:
`research/kyros_earned_prefix181_{exit,verification}.json` and
`research/kyros_earned_v5_prefix181_aggregate.json`.

Native latch61 and its automatic postcheck both actually exited 0; all 16
fidelity checks pass with 19 unchanged images, 64 instruction-latch and 31
data-latch qualifications. Matched MAME61 exited 0 and passed all 12 observer
checks. All eight vector words match; native request-to-qualified DBIN
observations occur at +3/+11/+19 ticks without variable extra vector-ROM
DTACK wait. Native IACK completion to final high-word latch is 128 ticks;
MAME CPU-space callback to program-space callback is 136. These are different
boundaries. Callback minus native IACK completion is +2 ticks in field 59
and -158 in field 60, so the remaining discrepancy is already present by
IACK. No clock, phase or CPU correction follows solely from these results.
B16 and the 18-pixel time-aware field60 residual remain open. Evidence:
`research/irq_sampling_edge_latch61_{verification,boundaries,interpretation}.json`
and `research/irq_sampling_edge_mame61_verification.json`.

ROM-backed markers identify byte 0x20103 as packed BCD lives, 0x20105 as
energy, and 0x20414 as energy-depletion processing. All 23 opcode cases and
61 overlapping MAME/native marker snapshots agree. Byte 0x20009 has no
qualified game-mode meaning; localization v2 explicitly supersedes that
earlier interpretation. The first depletion is bounded by fields1260/1290:
energy2/flag0 and active AY2-B noise become energy0/flag1 with noise disabled.
All 58 subsequent mixer/volume states disable noise through the first life
decrement at1380. The finite composition has 14/14 checks and all 49 sound
source pins unchanged. Legitimate tone remains allowed; no exact death edge
or zero-PCM claim. Second-depletion behavior and active-noise CPU reset stay
unqualified. Evidence: `research/kyros_death_marker_localization_v2.json`,
`research/kyros_death_marker_post_depletion_composition.json` and
`research/b03_death_reset_gap.json`. Full B03 remains false.

The latest user instructions explicitly permit unqueued direct check-only
Quartus map/synthesis/fit/STA from D:\q17\quartus\bin64. The earlier shared
recipe-registration rejection no longer blocks those checks; no shared trust
registry modification or bypass is needed. Assembly/full compile still uses
the shared queue and remains gated on complete acceptance. Complete current
design resource/timing checks are being scoped, and a nonvacuous CPU reset
capture is being prepared from the qualified punch prefix. No Quartus or RBF
has run during this phase. Continue Kyros fidelity closure before Japan and
Super Stingray; resource compliance remains unproven until actual fit reports.

## 2026-10-10 — Standing parallel work and continuous Quartus checks

The user explicitly authorized agents in parallel wherever useful, ongoing Quartus
checks, and use of the shared build queue when required. Updated AGENTS.md to remove
the stale hold/agent prohibition and reflect direct, unqueued check-only stages versus
queued full compiles/assembly. Preserve all strict resource limits and aim for margin;
check the complete fitted design after material RTL/clock/memory/constraint changes.
Resource and timing qualification remain pending actual reports. No RBF was assembled
or hardware acceptance declared by this instruction update. Source revision: 6f5cd32d741ca53244c7cd01726fd19eeab5a533.
Next: finish the assigned resource/timing baseline, SDRAM review, startup IRQ
write-order diagnosis and active-noise reset qualification; integrate their actual results.

## 2026-10-10 — Deferred-write cause boundary and remaining qualification scope

Source parent: 8fb5e6b6b48af628bc82bdd271cb7e387d36a759. Imported12 research helpers/receipts/notes and updated IRQ
context and bug coverage, without changing production RTL, clocks, constraints or
ROMs. Root deferred-write join passes8 checks; independent review passes20. Corrected
bus scope has10606 writes per trace/10598 ordered matches, with two field59 tile
writes observed on opposite sides of IRQ handling. Source-qualified ROM/MOVEM and
savedPC/A0 corroborate96masterticks of relative growth. The initial asymmetric
tile selector remains unqualified; it is not imported as accepted evidence. Exact
paths/hashes are recorded in research/completed_phase3_integration.json.

The complete-current Quartus scope review passes10 static checks. SDRAM constraint
specification records actual posedge DQ/command/address paths and related48MHz clocks;
device grade/board-flight/load bounds remain missing, so numerical external delays
and complete timing closure are not qualified. Direct check-only map was attempted
and returned Error132005 before synthesis; worker investigates project/output access.
No resource measurement, fit, STA or RBF acceptance is claimed by static checks.

The late-game audit proves existing130 combat snapshots do not reach stage5/ending;
15 exact renderer fixture fields remain narrower evidence. A control-only MAME route
is being developed before one necessary actualCPU late-game replay. Active-noise
resetv3 built with actualexit0; parent observed simulation77945/worker77807 live.
Its reset/terminal qualification remains pending, with earlier failures preserved.

Next: resolve direct-map access, collect complete fitted resources/timing, observe
IPL recognition at the deferred-write boundary, and finish actual-noise/late-game
coverage. B16, B01/B02 actualCPU coverage and whole-game acceptance remain open.

### Late-scene requirement correction, 2026-10-10

The phase-3 late-game gap note overstated natural CPU progression into stage 5
and the ending as a required next gate. The approved plan explicitly permits
debugger/Lua-created rendering fixtures (P1) alongside real CPU attract and
controllable gameplay (P7). The retained three fixture cases cover B01 for Kyros
and Japan Kyros, and B02's Kyros ending text/character overlap. The audit rechecked
all 15 complete 256 x 224 RGB fields: zero differences, actual exit 0, matching
fixture executable hashes, 11 compiled and 9 current shared source pins per case.
Reuse this finite evidence unless an affected source change invalidates it.

This supersedes only the extra natural-playthrough requirement, preserving the
earlier actual CPU RAM observations. Natural stage-5/ending progression remains
unproven; fixtures do not replace real CPU gameplay. P7, whole-game acceptance,
the genuine startup graphics/timing differences, remaining game/profile/features,
audio qualification, and full current-design resource/timing closure remain open.
Evidence: research/kyros_late_scene_contract_audit.json and its paired note;
reproducible audit: scripts/audit_kyros_late_scene_contract.py.

### Actual IRQ recognition and active-noise reset terminals, 2026-10-10

Source parent: 2313e350d9c200c3fa90eb62919c358f5e71517a. The actual private IPL replay exited 0. Its 69 source
pins, all 19 native RGB images and complete inputs/frames/instruction/bus/E/latch
observations match the frozen reference. All 4,745 read-only observer rows follow
the actual fx68k update rules. Six IRQ assertions have five subsequent paired
IACKs; the last field-60 IRQ1 acknowledgement is outside the finite stop. The
original frame-label coverage predicate is preserved and explicitly superseded
by the tick-paired timeline. The corrected verifier was syntax checked, not rerun.
At the two disputed tile writes, actual pending/inl offsets from assertion are
20/24 and 21/33 master ticks. These observations do not establish a physical
cause, justify a phase change, close B16 or prove full graphics acceptance.

The real-CPU active-noise reset replay also exited 0. Noise and channel-B outputs
each made 70 pre-reset transitions, with 362,880 nonzero channel ticks. Reset was
asserted after field 715 for 64 master ticks, followed by 500,000 checked ticks;
held/post channel samples and post-reset AY2 writes are zero. The original
verification's truthy integer precondition is retained; the separate strict
qualification records its Boolean interpretation and authentic terminal checks.
This is finite active-noise reset coverage, not complete B03 or PCM acceptance.

Evidence: research/irq_ipl_recognition61_{import_manifest,timeline,verification}.json
and the reset import manifest/terminal qualification imported in this phase.
Production RTL, ROMs, clocks and constraints are unchanged. Current full-design
mapping is separate; final fitted resources and timing remain pending.

### Diagnostic helper relocation and interrupt boundary source review, 2026-10-10

Source parent: ad6d6800bee52a64c9a0057cc757d0aa9dde2557. Corrected the three imported IPL helpers' fixed-depth
root assumption for scripts/diagnostics. Probe/verifier now use a validated
absolute ALPHA68KN_EVIDENCE_ROOT or the nearest marked project ancestor within
eight levels; repair shares the guarded probe's resolver. Nine staged checks
cover root lookup, invalid overrides, syntax and immutable runtime provenance.
Parent AST inspection confirms probe/repair main routines are guarded; importing
the resolver does not launch a build or replay. Original receipts retain their
actual runtime hashes and capture paths; adapted helper hashes are distinct.
No past verification was rerun or rewritten.

The pinned MAME0.289 and fx68k source comparison passes five finite checks and
finds all 1,024 microcode words equal. MAME snapshots pending interrupts at
IR-to-IRD transfer; the generated MOVE.W destination write precedes that point.
fx68k separately samples/stabilizes IPL and captures pending state at its enabled
group-one boundary. This is a concrete candidate explanation for the observed
pre/post-MOVE ordering, not proof of a defect in either implementation. Exact
MAME pending state and native dispatch remain outside the retained observer;
internal PC and repeated microcode words cannot uniquely identify dispatch.
Do not use this review to justify a clock/phase adjustment or close B16.

Evidence: research/irq_ipl_recognition61_adapted_import_manifest.json,
irq_ipl_recognition61_adaptation_review.json, irq_mame_fx68k_boundary_review.json;
integration provenance: research/completed_ipl_helper_adaptation.json.
Production RTL/QSF/SDC/ROMs are unchanged; current fitted resource/timing and
all-game acceptance remain pending.

### Complete Japan720 sound event reference and finite IRQ state join, 2026-10-10

Source parent: 578c9dfd038587dffa21bf847ac113e86e0804c7. One official pinned MAME Japan Kyros run completed 720
fields with an unconditional event tap and actual exit 0; its verifier exited 0
with 23 strict checks true. All 406 chip writes, 9 main sound-latch writes and 29,549
DAC writes match the retained native 720 run in order and field labels. Applied
inputs, Japan profile/ROM regions and original MAME state prefix match. No RTL
replay or production edit was needed. The original 114-versus-406 audit used
intentionally sparse events (capture.lua detailed windows); it is retained and
explicitly corrected, not evidence of an RTL or oracle-input defect.

This qualifies the frozen native run's finite sound event sequence. Current
compiled-source parity, hit/jump/pickup/game-over/restart semantic action windows,
calibrated audio and full P5/B03-B06 acceptance remain pending. Phase-identical
MAME/JT PCM is not required by the approved plan.

The existing 4,745 IPL rows yield a finite state-set join with zero contradictions;
23 ambiguous state rows and four ambiguous enT3 rows remain explicit. Thirteen
group-one assignments are unique. Critical source-predicted assignments are
ticks 47849497/48000041, each 112 ticks before its actual IACK. Their predicted
rInterrupt_after is 1; rInterrupt_before is unknown. These are inferred source
assignments, not observed signal edges or proven dispatch. All 336 compact
nanocode words match MAME across 544 explicitly mapped microaddresses; 480 default
or unmapped addresses remain outside that comparison. Matching micro/nanocode
does not establish identical forwarding or interrupt timing, B16 closure or a
physical cause. An isolated import also confirms the adapted probe/repair do not
launch main; original runtime evidence remains unchanged.

Evidence: research/kyrosj_sound_fulltap720_verification.json and its paired
kyrosj_sound_fulltap720_correction.md, kyros_sound_acceptance_stage_import_manifest.json,
irq_ipl_recognition61_state_join.json,
irq_fx_mame_nanocode_comparison.json, irq_ipl_recognition61_import_safety.json.
Production RTL/ROMs/constraints remain frozen for the current complete-design
Quartus check. Fitted resource/timing, all-game simulation and final RBF/hardware
gates remain open.


## 2026-10-10 — Complete synthesis resource failure and cycle-aligned video memories

Source parent: 433b6b3244bb708c9b28ebd3c91fc99424524974. The complete sys_top
analysis/synthesis actually exited 0 with all 161 input pins unchanged, but
reported 695,378 registers, 1,025,516 raw logic cells and 1,702,698 block-memory
bits. These are synthesis counts, not fitted ALMs or a resource pass. Fitting
and STA were not launched on this unsuitable design. The original database
routing failure and actual retry remain preserved in local diagnostics.

Named report evidence establishes that mainROM already maps to block RAM;
workRAM, stripRAM and soundROM do not appear in the board RAM summary. Their
combined 622,592 storage bits explain nearly all 622,882 board-owned registers,
but that arithmetic is collective attribution, not separate named register
counts. The physical video-ROM entity also uses 44,103 registers. See
research/quartus_check_current_map_terminal.json and
research/quartus_check_current_ram_diagnosis.json/md; the frozen authentic report
is hash-bound in those records. No mainROM patch was made.

Changed rtl/alpha68kn_video_rom.sv to directly register full lookup/color/RGB
memory words and their matching byte/nibble selectors. The CLUT-to-indirect-to-RGB
and color-read cycles are retained. The unchanged original complete module and
the candidate passed actual Icarus compile/run (both exit 0): 131,072 cycles,
18,725 same-address loader/read collisions, exact color/RGB/debug output equality,
and no unknown outputs after complete initialization. Evidence and source pins:
research/video_rom_aligned_candidate/miter_exit.json and import_receipt.json.
This is cycle-equivalence evidence for the exercised module, not a fitted-memory
or complete new-image game-run pass. Dedicated inference qualification is pending.

Imported the authenticated Japan720 compiled-source review (65 compiled HDL
inputs, 9 strict checks). It qualifies the old cold-run source relationship
before this memory change; it does not silently qualify the new image. Imported
the retained action audit: exact game-over RGB at3360 and title return at3600
are established; second-start restart and isolated successful jump/hit/pickup
attribution remain open. All earlier mismatch and verifier-failure evidence is
retained.

Next: qualify and integrate sound/work/strip block-RAM fixes without changing
CPU acceptance or renderer collisions, check the affected real CPU paths, then
run complete current-design synthesis, fit and STA. All hard resource/routing
limits and required setup/hold/external-memory timing must pass before the final
build. No RBF, hardware acceptance or family completion is claimed here.


## 2026-10-10 — Integrated inferred game memories; complete fit/timing next

Source parent e1b71d51c3a23bbd5240d25005a41a2c9af9d3d3. Integrated soundROM
full-word/control captures with unchanged post-edge Z80 DI; workRAM full-byte
banks plus explicit word0x22 and old0x29-high shadow; and two synchronized
sprite-RAM copies for accepted CPU and physical renderer reads. Both sprite
readers retain OLD_DATA. sim/system_main.cpp reconstructs diagnostic RAM dumps
from the actual banks and special word, without changing simulation clocks or
CPU behavior. Video normal reads are identical in hardware and simulation;
only the unused physical diagnostic reader is excluded before RAM inference.
The actual top binds its selector to0 and leaves its output unused.

Authentic isolated synthesis: SoundAligned31 rawcells; guarded video54 rawcells,
12registers,70,656memorybits/all6namedmemories; replicated work/sprite167rawcells,
51registers,163,840memorybits/all6banks. RAM segments are synthesis subdivisions,
not fitted M10K counts. Earlier video96,095cells and duplicated-sprite95,818cells
failures remain preserved. No complete-design fitted resource pass is claimed.

Decisive functional evidence: sound60,000cycles/6,000collisions; video131,072cycles
and18,725collisions in EACH physical and simulation mode; actual two-fx68k
fixture8,852ticks/5,187readchecks with both coin branches, CPU state, memory,
hiscore and renderer agreement; independent replicated-RAM OLD_DATA/mirror
contract8,193edges. The original fixture's24write-DI differences are retained;
the preferred replica restores legacy OLD write-DI through its explicit source
join. It is not falsely substituted for the fixture executable.

Actual Japan61 sound/current-video replay build0/simulation0:900,530ROM CEN
and T2 checks,45,348,857address-hold checks, zero mismatches, all61CPU/frame/input
metrics and retained RGB exact,114chip writes plus1DAC event/ticks exact. The
initial16/17verification failure was a selective logging-scope mismatch. Source-
bound correction retains all135old rows exactly and accounts for all32expanded
observer rows;18main+10observer strict checks pass. Initial failure and rejected
schema hypothesis remain preserved. This finite sound/video run and storage
joins do not constitute a new merged-image gameplay acceptance.

Evidence: research/inferred_game_memories_import_receipt.json, the three import
manifests, research/ram_candidate_word22/qualification.json,
research/kyros_sound_rom_q61_observer_v2_verification.json and the three preferred
inference receipts. Next use QuartusFast DEV_FAST for the COMPLETE current
project map/fit/STA, enforcing every resource/routing cap and setup/hold/clock/
external-memory constraint. Run the merged real game image and remaining action,
restart/audio/graphics checks. All target-game/final RBF/hardware gates remain
open. No assembly or deployment occurred.

## 2026-10-10 — Audio calibration and legal restart oracle imported

Source parent6dfeca51f027e5d431f4ebe68c58f7a3a5df9a68. Imported23
hash-verified portable artifacts and retained225 ignored capture pins. All
artifact/capture hashes, Python syntax and staged copies pass. Production
board/video/host pins are unchanged; one current merged native build is active
and its simulation is held for the extended legal reference input.

The existing10 WAV recordings have monoPCM16/48kHz format and no endpoint
clipping. The finite punch calibration passes6 checks. Its480 pre-write samples
match the floor of MAME's modeled AY1/AY2/DAC routed sum (-27444), with AY2:AY1
ratio2.0. Retain the measured mixed short-window RMS difference13.99percent and
one93.75Hz dominant-bin difference. These do not qualify separate chip pitch,
dynamic gain, random noise phase or whole P5 audio acceptance.

Actual MAME3901 restart reference exits0 and passes13 checks: its first3601
states and retained RGB exactly match the prior idle-death reference. Displayed
GAMEOVER3360/title3600/second-introduction3690 are qualified. Courtyard3900 is
still part of pre-play; right during the transition does not prove movement.
The later agent extension preserves this oracle and moves controls into active
gameplay before the single current native replay begins. Native restart remains
pending. Evidence: research/audio_restart_evidence_import_receipt.json,
research/kyros_restart_acceptance/import_manifest.json and
research/kyros_retained_punch_wav_calibration.json.

The complete current resource/timing check remains pending. QuartusFast's first
attempt rejected the pinned framework PRE_FLOW_SCRIPT_FILE before any map/fit/STA.
The timing agent prepares an explicit check-only overlay retaining every other
assignment and the generated prerequisites, and waits for other host jobs to
finish. No timing pass, final fitted resource count or RBF is claimed.

## 2026-10-10 — Conflicting flow rules reconciled; live checks preserved

Source parent716bfbca. The user explicitly requested full queue-rule repair and
resubmission. Canonical and recovery AGENTS.md now consistently prefer QuartusFast
for DEV_FAST map/fit/STA; check-only jobs are unqueued and full compile/assembly
retain the shared FIFO/two-job ceiling and explicit RBF/current-image gates.
Removed the obsolete hold and queue-only check wording. Both already-resumed
disabled=false hold configurations remain unchanged; original rules are backed
up outside automatic instruction-loading paths. Seven strict rule checks pass.
Evidence: research/unified_flow_rule_repair.json. The agent owns the separate
PreToolUse classifier repair; this doc change does not claim that enforcement
is fixed. The previously justified same-front-end retry was admitted as actual
session96534; preserve it rather than submit a duplicate. Map/fit/STA results
remain pending. The one current native4401 replay is also live (worker102113,
sim102130, authenticated ELF9315e253), with no terminal or full acceptance yet.

## 2026-10-10 — Queue enforcement repaired and evidence integrated

Source parent 3d103d35; production board, video memory and native host pins
remain identical to 6dfeca51. The shared Codex/Claude PreToolUse guard now
recognizes the fixed reviewed QuartusFast entrypoint and read-only evidence
commands. It preserves normal execution review, the full-compile FIFO ceiling
of two, and separate explicit RBF authorization. Raw assembly, encoded commands,
unreviewed executable delegates and script/eval loopholes remain rejected.
The deployed final 2fd6ba7b revision passes 69 pure classification cases.
The exact originally rejected real read-only observation now exits 0 (6ad02a).
The intermediate revision's failed real smoke is retained rather than erased.
Original/intermediate guard backups remain outside automatic loading paths.
Hook targets, configuration, worker and controller hashes are preserved;
the second deployment additionally records the queue-library before/after pin.
No stronger first-deployment queue-library prehash claim is made.

The previously admitted resubmission is session 96534, using the complete
preprocessed current design. It is still mapping; fit, resources and STA are
pending. Preserve this job and current merged Kyros worker 102113/sim 102130;
do not launch duplicate checks or replays. No assembly occurred.

Imported the actual MAME 4401 restart/action oracle and its preserved 4101
failure, seven current-source audio contract artifacts and the bounded
reference supplementation audit. MAME exits 0; all 4401 state rows are
contiguous, the 4101 prefix and 84 prior displayed images remain exact.
Legal right input during fields 4220-4259 produces visible displacement
(head bounds move 14/16 pixels; red center moves 11). Button 2 has a measured
3-pixel rise, but no successful jump, hit or pickup is claimed. Button 1's
prior visible punch interpretation does not prove a hit. Current native
movement and restart remain pending the existing replay.

The audio reuse audit passes 14 checks with 49 hardware-source pins exact.
Retained chip tone/envelope/noise/timer and seven golden mixer vector contracts
are accepted at their finite scope. Broad P5 and B03-B06 acceptance stay open.
The historical idle_death7200_v2 MAME reference really reaches 7200 fields;
the earlier 3601 stop was native. Its input diverges at field 3621, and other
candidate DIPs differ at field 0. The five-candidate audit supplies zero
qualified extra arrays; 118 native snapshots have no shared oracle arrays.
These omissions are explicit, with no picture masking or field shifting.

Evidence: research/guard_reference_evidence_integration.json,
research/queue_guard_repair/import_manifest.json,
research/kyros_restart_actions4401/import_manifest_v3.json,
research/kyros_audio_existing_contract_reuse_v2.json and
research/kyros_reference_supplement4401/reference_supplement_manifest.json.
Next collect actual terminal reports and replay qualification, address
remaining graphics/audio/clone and Super Stingray gates, and keep final
RBF/hardware work last.

## 2026-10-10 — Complete-design map failure isolated; owned fit stopped

Source parent 1a6ccff9; frozen hardware remains 6dfeca51. Actual session 96534
has terminated with wrapper exit 1. Map itself exits 0 after 36:09 and reports
771,911 logic cells, 548,181 registers and an estimated 372,496 ALMs. These are
mapping estimates, not fitted resource utilization. All 161 production inputs
are unchanged before/after. The authentic map report SHA is
bf6a8f1c5fc6f0ba3434239468528de3acf3d485f7d9e0f6168eaccd8b129af0.

The RAM summary contains main ROM, both strip readers, work banks and normal
video tables. Sound ROM is absent. Its synchronous output instead has a
32768:1 x16 multiplexer costing 349,520 LEs, and the board owns 524,625 registers.
Main ROM inference is healthy; no main-ROM change is justified.
The controller had entered fit automatically. Stopped only verified owned
fit PID 70068 with parent 6448 and exact admitted project/executable checks;
no other job or queue lease was touched. The frontend records failure and
timing_valid=false/accepted=false/successful_rbf=false. STA did not run; fit
was deliberately cancelled, so no fitted resource result is claimed.

A private candidate narrows only the guarded sound loader write index to its
physical 15 bits. All 65,536 accepted byte addresses map to the same 32,768
words. Its matched inference probes are separate evolving evidence, not part
of this immutable failure import. Keep the running native 4401 sources frozen;
do not repeat the complete map until the responsible-layer hypothesis is proven.

Also retained the independent nine-case guard review's previously observed
actual exit-0 output. It supplements the deployed 69 cases and real original
command smoke; the retained file does not claim a new classification run.
Evidence: research/merged_fast_failure_record/import_manifest.json,
research/merged_failure_evidence_integration.json and
research/queue_guard_repair/independent_review9_retained.json.
Next qualify the private write-index fix, obtain a complete candidate fit/STA,
and collect the existing native replay terminal. Resource/timing and final
RBF/hardware gates remain open.

## 2026-10-10 — Embedded SSG corner case proven; P6 candidate retained

Source parent f3f54ef8. Imported 40 hash/size-verified embedded SSG artifacts,
10 private Super Stingray preparation artifacts and their manifests. Production
hardware and current merged 4401 replay sources remain unchanged. These are
private candidate inputs and evidence; no production patch was applied.

The embedded YM2203 SSG's baseline actual build exits 0 and run exits 1:
period 0 produces zero channel-A/divider rises for 500,000 master clocks.
Periods 1/37 produce the correct 768/28,416-tick rising-edge gaps. The current
49-file sound graph matches the compiled 4401 graph. Pinned local MAME YMFM
models tone period 0 as period 1. A one-line private divider correction removes
the forced-low override, preserving its GPL notice. Actual candidate build/run
both exit 0, and the qualifier exits 0 with 21 strict checks. Periods 0/1/37
now have exact gaps 768/768/28,416 at the real clock enables. Nonzero cadence
is unchanged; absolute edge phase/count differences caused by the corrected
default period-0 oscillator during setup are retained. No waveform identity
or broad P5/audio/game acceptance is claimed. Evidence and the unapplied
candidate are in research/ym2203_ssg_pitch_stage/import_manifest.json.

The private P6 patch prepares real T48/8748 firmware loading and enables,
profile-2 command/shared-RAM/IRQ2/flip and sound-map integration, build/QIP
closure and legal recorded harness input. Preparation reports 13 static checks
and eight arbitration model cases. Its first generation is retained externally.
HALTn stays high because the pinned fx68k port serves single stepping; the
candidate instead drains the accepted AS cycle and freezes phase/enables with
AS high. MCU write/hiscore exclusion and profile-2 pause drain are explicit.
This does not establish physical priority or accepted CPU/MCU ordering.
HALT cutoff, MCU pause/resume, IRQ2/IACK coincidence, high command byte,
oscillator accuracy and retained reference provenance remain unqualified.
Evidence: research/stingray_combined_stage/import_manifest.json and
research/stingray_combined_stage/integration_contract.json. A separate bounded
coupled-CPU diagnostic has been authorized; no combined-game pass is claimed.

Next finish the sound-ROM matched inference proof and complete candidate
resource/timing check, obtain the existing native replay terminal and qualify
these fixes before production integration. Whole-game, final RBF and hardware
gates remain open. Integration receipt:
research/private_candidate_evidence_integration.json.

## 2026-10-10 — SSG software-impact scope qualified from retained traces

Source parent 8a00d30b; current canonical hardware remains byte-identical to
6dfeca51. Authoritative continuation observation confirms native worker 102113
and simulator 102130 live, and the unchanged-index inference controller 38544
with map 10180 live. Missing root tool session handle did not trigger a restart.
No native terminal receipt exists at that observation.

Imported the conservative active-period-zero audit and its finite qualification.
The original audit really exits 1 (5/7): each trace has three startup update
classifications before all volume registers are observed. Those uncertainties
are retained. The finite qualifier exits 0 with all six strict checks, scoped
to the known register window beginning field 2 tick 1696970, after observed
R8/R9/R10 volume initialization. No reset assumption fills the earlier gap.

The complete actual 1800-field trace has 914 SSG writes, 912 known-window
updates and 1711 tone-enabled/nonzero-volume channel states. The immutable
current 1127-field prefix has 455 writes, 453 known updates and 838 eligible
states. Both have zero active period-zero candidates in the known window,
zero unresolved known candidates and zero eligible envelope-selected states.
Envelope amplitude remains unobserved. Event coordinates are host IO pulse
boundaries, not sampled internal register latch ticks. Historical input/exit
pins are retained; current source excerpts do not retroactively prove the
historical complete compiled source graph. Other scenes, sets and whole
startup absence remain unproven. No new replay was launched.

Captured CSV/register timelines are hash-verified and retained under ignored
sim/captures/diagnostics/ssg_active_zero. Compact metadata and scripts are
tracked; the original manifest and integration receipt preserve exact recovery
mapping. Evidence: research/kyros_ssg_active_zero_audit/import_manifest.json,
research/kyros_ssg_active_zero_audit/finite_qualification.json and
research/ssg_impact_evidence_integration.json. The donor period-zero correction
remains required for correct chip behavior even though these known windows
show no active software use. Broad P5, current replay, fit/STA and P9 remain open.

## 2026-10-10 — Queue repair completed; direct CPU/MCU evidence retained

Source parent d6c8875; production RTL/harness remain byte-identical to 6dfeca51.
Imported the complete queue follow-up and replaced stale plan/prompt/loader rules.
Development map/fit/STA uses QuartusFast without a production lane or registry
approval; gated full compiles/assembly/conversion retain the shared FIFO and
two-job ceiling. The obsolete leased/raw-shell entrypoints explicitly refuse
execution and point to the current reviewed frontend/preparation contract.

The read-only Capsule search rejection was fixed. Independent review then
found unquoted LF/CRLF accepted as whitespace; the original failed result is
preserved. Final guard f38be3c6 rejects unquoted CR/LF before whitespace while
preserving quoted read-only data/code. Actual qualification passes 98 pure
classification checks and the independent four-case review. No unsafe negative
command was executed, queue worker/controller changed, or assembly authorized.
Evidence: research/queue_guard_followup/import_manifest.json.

The sound-ROM fifteen-bit write-index candidate has an exact 65,536-address
proof and matched isolated maps: cast 22,027 logic cells/524,288 RAM bits versus
uncast 753,954 logic cells/zero RAM bits. The complete candidate map still has
771,962 logic cells/548,181 registers, estimated 372,510 ALMs, and no sound-ROM
RAM node. That isolated fix does not close the integrated inference failure.
Only its owned oversized fit was stopped; no STA/resource/timing pass or RBF.
Evidence: research/sound_write_width/import_manifest.json and
research/sound_write_width/complete_import_manifest.json. All 161 hardware
pins remain exact. The authentic dependency inventory contains 18,607 files/
5.562 GB, including growing live Kyros capture CSVs; five metadata CSVs changed.
The cancelled-fit branch performs no terminal full rehash, so no quarantine
verdict occurred. Metadata changes are not the hardware inference cause.
Next diagnose the extra integrated memory context before another check.

The actual direct IRQ observer builds/runs/verifies with exit 0: all 61 CPU/
renderer rows and 19 native RGB images match the previous qualified run;
13 strict checks pass. Compact acceptance v2 selects original absolute IRQ
ticks, preserving earlier field-label/signal interpretations. IRQ1 at 47849465
is native field 58: pending +20, interrupt latch +32, microsequence entry +40,
IACK signal +136, bus attribute +144 master ticks. IRQ2 at 48000000 is native
field 59: +21/+41/+49/+145/+153 respectively. MAME's internal cutoff is still
missing; the private observer/source build preparation has seven static checks,
not a runtime pass. No CPU/clock correction or B16/whole-graphics closure.
Evidence: research/irq_dispatch61/import_manifest.json and
research/mame_cutoff_observer_stage/import_manifest.json.

Private Super Stingray executes the real coupled CPUs/MCU through 16 and 111
fields, with exact first six software command tuples against retained MAME.
The original failed final-RAM expectation is immutable. A read-only byte-edge
observer resolves it: MCU word ff commits 0000→00ff at 91308612→91308613 and a
later accepted CPU full-word write clears it at 91495636→91495637. MCU word 29
commits 0000→0021 at 92736915→92736916, then an accepted CPU LDS-only write
clears its low byte at 92738355→92738356. High bytes remain unchanged. Actual
build/run/verifier exit 0, all 18 storage/source/prefix checks pass, and all
retained 111-field RGB/RAM/input/MCU/IACK records are exact. No RAM logic fix is
justified. Full attract/gameplay, reference graphics and physical MCU timing
remain open. Evidence: research/stingray_combined_stage/bank_before_after111/
import_manifest.json and the retained earlier coupled-run manifests.

Large raw captures remain in their verified recovery locations; this import
preserves hashes and recovery handles without re-running completed simulations.
The existing merged Kyros4401 continues separately. Next qualify its actual
terminal, complete MAME cutoff observation, integrate only proven final-source
candidates, and finish Japan/Stingray/game/feature and complete fit/STA gates.
Final RBF and MiSTer hardware testing remain the last phase.


## 2026-10-11 — Reader rule repaired; final source replay recovery underway

Source parent c64c46f4. Production RTL remains unchanged from 6dfeca51; this
phase updates policy and retains evidence. The latest V2 partial-check policy
is now reflected in AGENTS.md, plan.md and goal_prompt.md: inspect installed
profile support, select the smallest sufficient partial level, use independent
native databases, force RBF generation off, and preserve preprocessing only in
isolated check workspaces. Full assembly retains its final gates and shared FIFO.

The newer installed guard (baseline 9d979f3f) still rejected legitimate bounded
PowerShell file-read pipelines and local process observations. A finite reader
grammar repairs these forms without changing its V2 check approval, queue or
RBF behavior. Candidate afcf3db2 preserves all original 98 cases and passes
155 total builder checks; the independent frozen review passes 66 classifier
cases through both adapters. Dangerous test commands were never executed.
Compare-and-swap deployment and native review have combined exit 0 (c3660c);
the separately recorded numeric review exit is unavailable, not invented.
The actual previously rejected Capsule reader now returns output successfully.
Evidence: research/queue_guard_read_pipeline/integration_receipt.json.

The full sound-ROM case2 guard candidate is now actually running one direct
MAP-only check, with all 161 assigned sources frozen and no production lane.
It reuses the authentic complete baseline instead of repeating its expensive
map. The candidate explicitly turns RBF generation off. Its terminal RAM
inference, complete resource qualification and fit/STA are still pending.
Recovery: D:/Arcade/AI/aCORES/Alpha68k N/research/sound_write_width/case2_full_map.
There is no new timing-closure or resource-limit pass.

Super Stingray joined181 has authentic build/run/verifier exit 0 and all 15
protocol/source checks: 181 real RTL fields, exact source pins, original111
prefix and coin/start input phases. This is finite protocol evidence, not
whole-game graphics/audio acceptance. Existing RGB30/90 are exact; RGB/strip119
are exact with four work-RAM byte differences; field179 diverges after coin/start.
Its first-field 868-pixel difference also persists under constant exact captured
RAM with the real renderer, ruling out native startup/reset and CPU/RAM
interleaving for that specific mismatch. A mismatch between the MAME first
screen buffer and captured RAM epoch remains possible and is being checked. Decode/layout and gameplay divergence
are being localized separately before a broad Stingray replay or RTL fix.
Terminal evidence: research/coupled181_recovery_integration.json.

The original Kyros4401 epoch was interrupted after 2588 complete fields, without
an authentic terminal receipt. No live worker or full-state restore interface
remains. Its partial evidence is preserved. A separate old-source recovery was
admitted with matching pins; it is being replaced early by one joined-source
replay to avoid repeating 4401 fields after final-source integration. The
existing joined executable is also selected for one affected Japan720 replay.
Admission does not imply a terminal or semantic gameplay pass.

The required B01/B02 finite late-scene fixtures already have their retained
qualified evidence; another natural late-game pilot is unnecessary. Remaining
work includes current-source game/graphics/audio and P8 feature gates, complete
fitted resources/all-corner timing, then the final gated RBF and hardware tests.
No RBF, deployment or publication occurred in this phase.


## 2026-10-11 — Complete sound-ROM RAM inference corrected

Integrated only the qualified fifteen-bit loader index and the VERILATOR guard
around the physical top's unused sound diagnostic reader. The simulated reader
and synchronous CPU full-word read remain available with the same clocks and
latency. The earlier exhaustive legal loader-index proof is retained.

Actual complete sys_top MAP exits 0 (544b0f), in 3m11s. Sound ROM is now a
32768x16 simple dual-port RAM: exactly 524288 bits. Logic cells drop from
771962 to 40662 and registers from 548181 to 24000. Block memory bits increase
by exactly 524288 (1915224 to 2439512); RAM segments increase by 64 (1299 to
1363); DSP count remains 41. These are map figures, not fitted percentages.

The original process-only owned_jobs_observation.json was overwritten by a
later fit admission probe, causing the initial integration to refuse with
exit 1 (e49c47) before any canonical writes. Its exact 314 bytes were recovered
from the original output and verified against SHA20dd4500; all 14 original
manifest pins now qualify. The separate later observation is preserved.
Compiled sources and reports were never changed by these probes.

The matched complete graph proves the additional unused diagnostic reader was
the remaining inference blocker after narrowing the loader index. All 161
frozen assigned sources and effective synthesis settings were retained; only
the candidate reader guard differs from the previous cast baseline. Its check
settings explicitly disable RBF generation. No baseline map was repeated.
Evidence: research/sound_write_width/case2_import_manifest.json and
research/sound_reader_integration.json. Mapped candidate SHA is
7ea61d03b20886e643c5d0be64c9f80bb93923975223f7c272621d3cab05aaa9.
Production retains its original LF line endings; decoded source lines are
identical to the mapped candidate. Its actual normalized SHA is
ba9357acc26ac391c71a01b166e96c7879fed726274eb13c60a25a494093f8fc.

The next incremental check is fitting and all-corner STA on this exact isolated
mapped graph, with complete resources, crossings, unconstrained paths and
critical warnings reviewed. All seven resource limits and timing remain open
until actual fitted reports qualify them. This is not the later all-game final
source qualification. RBF assembly and hardware remain gated.


## 2026-10-11 — Completed display references qualified; affected replays active

Parent 2b34eeb7. Production RTL is unchanged in this evidence phase. The
Stingray false first-field mismatch is resolved: its private checkpoint consumer
selected diagnostic screen:pixels() drawing-buffer RGB instead of the completed
display texture. Driver-declared inverse ROT90 of the completed MAME PNG is
byte-exact with native real-CPU RGB at fields 0/30/90/119. The steady real-renderer
fixture independently reproduces native field0. All five already-normalized
.display.rgb references equal the independent PNG decoder. Canonical capture,
normalizer and analyzer already select completed display output correctly;
they need no implementation rewrite. A minimal future private consumer patch
is retained separately, syntax-qualified but not retroactively executed.
Original false raw-buffer comparisons and authentic failed fixture exit remain.
Evidence: research/completed_display_evidence_integration.json.

All 49 existing Kyros completed-display oracles independently qualify against
their source PNGs. The unchanged live joined verifier already uses these
completed references. Its early four common RGB/work/strip targets are exact,
but the complete run remains pending. The 118 absent reference oracles are
explicitly unknown. B16 is still open: the selected native field60 differs
20835 pixels from its completed PNG; the separate 18-pixel timed bus-phase
residual is also unresolved. The Stingray reference fix does not close B16.

Kyros joined4401 is admitted on the existing 75-source executable, with the
same legal actions and audited ROM. The earlier old-source recovery was stopped
only after exact owned-process identity checks; its genuine exit -15 and 108
completed fields are preserved. Original interrupted2588 evidence also remains.
Japan joined720 is separately admitted on the same executable/profile1 with
original input/reference pins. Each supervisor writes authentic terminal exits
and performs one terminal qualification. Neither admission is a game pass.

The Stingray post-start divergence has a proved input orchestration error:
Lua captures before applying requested actions, and the native host applies
rows after snapshots. Staging also shifted the rows, delaying effective native
coin/start by another field. Corrected rows bind each after-snapshot field f to
the retained MAME ports at f+1; all 1799 prepared effective rows match. One
corrected181 run is active on the same pinned executable and ROM. A separate
append-only completed-display qualifier preserves the original raw comparisons.
Four work-RAM bytes already differed at119 before input; they remain distinct
from this phase error. No CPU/MCU timing or RAM patch is justified by that error.

The corrected181 subsequently completed with actual run/input/display verifier
exit 0, including all 181 effective input rows. The completed-display qualifier
retains a failed graphics gate at179: 49109 differing pixels, plus 1453 work
and 2344 strip bytes. Thus the input staging defect is corrected but does not
explain the gameplay divergence. This is a diagnostic verifier completion,
not a full graphics pass; actual CPU input reads are being investigated next.

The finite old-source Kyros audio audit exits 0, with all 13 checks. The
authentic completed2588-field prefix has 10608 globally ordered chip writes,
32091 DAC accepted writes and 21 masked sound latch writes exact against MAME,
including field labels. Retained combat3301 DAC and 134 latch writes match;
its known seven YM callback/global-order differences remain. The merged prefix binds
the original 6df executable. The separate combat3301 binds parent8b771c4b
and ELF864ebb2c; neither is an invented current-source replay.
Broad effect/semantic action and physical audio gates are still required.

The private observer MAME build has reached actual C++ compilation after
preserved environment failures, using explicit UCRT64 POSIX SHELL and
OS=Windows_NT. Its source closure is frozen; build/cutoff runtime acceptance is
pending. The isolated sound candidate has placed and is routing; complete fit,
all-corner timing, resource limits, current game/audio/feature gates and final
hardware qualification remain open. No RBF or hardware work occurred.


## 2026-10-11 — Complete fitted resource limits pass; timing remains failed

The exact isolated sound-reader candidate FIT exits 0 (f19aa0), in 17m33s,
with zero errors and 1274 warnings. No Critical Warning appears in the fitter
report; STA warnings and actual timing are separate. All seven strict complete
fitted resource limits pass against native device capacities:

| Metric | Fitted use | Hard limit |
| --- | ---: | ---: |
| ALMs | 17377/41910 = 41.46% | <80% |
| Occupied LABs | 2833/4191 = 67.60% | <90% |
| Peak interconnect | H40.3%, V55.8%; max55.8% | <85% |
| Average interconnect | total22.9%; H23.4%, V21.5% | <60% |
| M10K | 331/553 = 59.86% | <90% |
| Block memory bits | 2439512/5662720 = 43.08% | <85% |
| DSP blocks | 41/112 = 36.61% | <90% |

Evidence: research/sound_write_width/fit_import_manifest.json and
research/fit_and_action_evidence_integration.json. This qualifies the complete
mapped/fitted incremental candidate; the later P6/SSG all-game source join will
need its own final resource/timing qualification.

Bare native STA exits 0 (beaca0), but timing FAILS: Critical Warning332148,
reported Slow100C setup -47.980ns on an audio destination and -36.963ns for
game paths; a reported fast recovery game path is -5.346ns. Not all endpoints
are constrained. These are actual failures, not success inferred from exit0.
The actual generated game PLL name differs from an inherited pll_inst clock
group pattern. Exact crossing endpoints and synchronization mechanisms are
being reviewed before any constraint or RTL fix. No false-path mask or clock
change has been applied. The requested all-corner Tcl collector initially hit
a delegated-STA hook refusal before launch; a narrow hash-pinned exception is
under independent review. No RBF, assembly or queue bypass occurred.

The semantic audio addendum qualifies two actual jumps and two successful
enemy hits using retained combat3301 ROM/control-flow, native/MAME RAM and
accepted sound commands. Jump qualifiers exit0; hit qualifiers exit0 with
five main and eighteen target checks. These prove finite actions on parent
8b771c4b/ELF864ebb2c, with current-image source limits stated. Ordinary pickup
command53 and transformation4d are absent from both retained combat3301 and
the completed MAME4401 oracle. One minimal legal item-collision/removal target
is still required; another broad combat replay is unnecessary.
Evidence: research/audio_acceptance_20261011/semantic_addendum_manifest.json.
Current joined-game, broad effects and physical audio acceptance remain open.


## 2026-10-11 — Reviewed report-only STA delegation repaired

The exact native STA collector guard294f6b5d is independently qualified by
52 cases and the preserved181 builder cases, both with actual test exit0.
Compare-and-swap deployment exits0 (02903e), retaining its prior guard backup.
This permits one hash-pinned read-only collector with exact isolated project,
revision and output arguments. Arbitrary Tcl, process control and RBF assembly
remain refused. Static candidate, reviews and deployment receipts are retained
in research/queue_guard_sta_collector and sta_guard_evidence_integration.json.

Before its sole launch, necessary same-game/audio path and clock-group reports
were added to a separately pinned detailed collector, under independent review.
The original collector has not run. Bare STA's real same-game Fmax13.58MHz,
hold -32.121ns and recovery -31.061ns remain failures; correcting asynchronous
group matching alone cannot qualify the 48MHz game clock. No RTL, SDC or clock
change, RBF assembly or queue bypass occurred in this evidence phase.


## 2026-10-11 — Eight-corner timing and genuine IRQ observer completed

Native detailed STA exits0 (c86b66), but timing FAILS across all eight native
operating conditions: global setup -47.980ns, hold -32.141ns, recovery
-31.061ns, removal +0.401ns. Same-game setup worst -36.963ns; same-audio
-0.930ns. Same-domain holds are positive; the global hold failure is a
game/audio crossing. Complete fitted seven-resource results remain passing.
Source161/QSF pins are unchanged and RBF output is OFF. The detailed report
guard is independently qualified53 cases plus204 builder cases and deployed
as a9ee0738 with compare-and-swap; no broader queue/RBF authority was granted.
Evidence: research/sound_write_width/case2_fit_sta/sta_import_manifest.json,
research/queue_guard_sta_detail and terminal_diagnostics_integration.json.

The actual inherited game clock-group pattern matches zero clocks. Reset
paths have2032fanout and97% routing delay; audio critical routes are94%
interconnect. FAST FIT overlays override preserved STANDARD/HIGH PERFORMANCE
settings. A separate original-settings fit is being prepared with the same
mapped source graph and a reviewed missing-game-group correction. No game
clock, datapath latency or production reset change is justified by these
diagnostics yet. External I/O inventory classifies all20inputs/85outputs;
SDRAM installed part/physical timing and HDMI mode/skew qualification remain
unresolved, with no blanket unused-pad or false-path masking.
Evidence: research/timing_io_bounds_20261011/import_manifest.json.

Private MAME observer build, genuine61field replay and qualifier all exit0.
Twelve checks qualify61states, twelve referenceCSVs, nine retained raw arrays
and130 contiguous cutoff records. Both observed IRQ-taking IR-to-IRD
transfers occur22ticks later in MAME than native. Native transfers opcode
30fc; MAME transfers51c8. Input delivery offsets are +6/-1ticks and remain
distinct from sampling latency; IACK interfaces are not conflated. This
establishes scheduling/order divergence, without proving physical fault or
closing B16/the18pixel residual. No CPU clock or forced timer patch occurred.
Evidence: research/mame_cutoff_observer_stage/terminal_import_manifest.json
and boundary_comparison_import_manifest.json.

## 2026-10-11 — Joined Japan720 graphics/audio pass; strict RAM remains open

Genuine joined profile1 native replay exits0 with720 full fields, no renderer
protocol errors and worstline2280cycles. The first verifier exits1/13of14
after mistakenly choosing MAME diagnostic RGB. A separately pinned minimal
consumer fix selects canonical completed-PNG display RGB and exits1/15of17:
all six whole RGB and six strip snapshots pass; three work snapshots differ
by3/1/4bytes at fields240/360/600. No replay was repeated. All406chip writes,
29549DAC writes and nine latches match; source75/ELF/ROM/input/protocol pass.
Upper-RAM addresses and values are retained; activeSP/stale-stack cause is
unproven. Strict joined-Japan acceptance stays false. Both original failures
and corrected domain results are preserved; no RTL fix or relaxed RAM gate.
Evidence: research/remaining_gates_20261011/japan_joined720/import_manifest.json,
supplement_import_manifest.json and canonical_v2_import_manifest.json.
Next: source-level IRQ/CPU ordering review, finite wrapper qualification,
Stingray P2 sampling fix, standard fit/STA, and final joined Kyros terminal.


## 2026-10-11 — Reviewed standard timing, component and wrapper evidence retained

The same complete161-source board graph now has an original-settings STANDARD
fit and native eight-corner STA receipt: STA exits0 and all seven complete-fit
resource ceilings pass. Independent review finds all64timed tables positive
across all eight conditions, unchanged114HDL assignments/161source closure,
and the genuine same-HDMI critical setup margin+0.060ns. Overall timing
acceptance remains false. The reviewed
additive game-clock group correction does not alter clock frequency or RTL.
External I/O, unconstrained endpoint, warning and current-image requirements
remain open. This fitted graph excludes the proposed P6/P2/SSG join and cannot
qualify that next image. Evidence: research/sound_write_width/
case2_standard_fit_evidence/standard_fit_sta_import_manifest.json and
research/timing_crossings_20261011/standard_review_import_manifest.json.

The standard report-only STA guard5adad4cd is retained with its historical
compare-and-swap deployment and231 builder/52 independent review cases. Existing
failures and inherited argument-normalization behavior are preserved. This
repair grants no new queue, arbitrary Tcl, assembly or RBF authority.

The independently reviewed Stingray P2 transaction proposal qualifies four
actual genuine-firmware component build/run exits0. Its wrapper consumes the
architectural P2 latch at the existing delayed write strobe, preserving physical
P2 output and CPU/timer/clock logic. Approval is for a bounded genuine-game
replay, not a gameplay or timing pass. Original and P2-rebound finite realHPS
wrapper qualifiers each pass14checks and are retained separately; profile2 admission remains a private
test change. Static metadata audit needs no correction and establishes no
runtime acceptance. Mutable gameplay181 and later ordinary61 work are excluded
from this frozen evidence phase.

Kyros target-scope review and finite MAME MOVE-boundary/ordinary-cycle coverage
analyses are retained without closing B16, the18pixel residual or strict joined
RAM gates. Missing ordinary native latch/MAME ROM-read coverage is a recorded
evidence gap; no speculative CPU timer or phase patch follows from it.

The proposed final join preserves both sound ROM inference fixes, adds genuine
profile2 MCU dependencies and the shared SSG correction, and stages accurate
provenance/docs. Structural profile0/1 board specialization matches all4780
legacy tokens;1024 finite arbitration cases and65536 legal sound-loader address
cases pass. This is prepare-only source evidence, not a new native replay or
sequential formal proof. Shared SSG behavior changes all profiles and still
needs final-source acceptance. Candidate tree stays in recovery; profile2 enable
is a separate conditional patch. Canonical RTL, pinned sys and release outputs
are unchanged. No RBF, hardware deployment or remote publication occurred.
Evidence: research/reviewed_terminal_phase_v2_integration.json and frozen
research/final_source_join_20261011/import_manifest.json.

Next: use genuine181 gameplay results and complete current-source wrapper,
graphics/audio/bug acceptance before central source integration; map/fit/STA the
changed complete graph and resolve remaining constraints before any final RBF.


## 2026-10-11 — Genuine Stingray graph integrated with inferred MCU ROM banks

Baseline main a07e396c. The canonical source now joins the P6 board, reviewed P2 architectural transaction-data fork, native MCU/T48 dependency recipe and shared YM2203 SSG period-zero correction. Original donor notices remain. The JT49 fork record names deployed LF divider e2258ad7 separately from qualified CRLF divider2c4e8f79; normalization changes line endings only. Pinned sys/framework, original core/sys constraints, one48MHz game clock with enables and other donor modules are preserved. The additive game clock-group SDC8ef8f941 is assigned immediately after source files.qip. Profile admission<=2 and exact CONF_STR O5→H0O5 are integrated without private observer aliases/configs.

MCU program storage now uses two2048x8 parity banks, registered reads and captured address bit0, preserving all4096 bytes, adjacent-loader lane order, FFF wrap and one-cycle program read. Source-extracted paired RTL smoke passed79875 comparisons with actual build/run0; independent parity review approved the bounded source join. The historical v3 diagnostic-guard-only change had byte-identical Verilator preprocessing. The current bank change alters storage structure in both simulation and synthesis and is qualified by the paired proof; byte-identical preprocessing is not claimed for it. Sound ROM inference fixes and diagnostic VERILATOR guards remain.

Banked complete-MAP native exit0 proves two inferred MCU RAM atoms and eliminates the4096:1 FF/mux program ROM. Available estimates: ALMs19012/41910=45.36%, registers26184, block memory bits2470744 and DSPs41. Only the three available MAP resource checks are qualified; four other resource limits require FIT. Earlier complete-MAP MCU inference failures at98.65% and98.8046% estimated ALMs remain as superseded failures; neither graph proceeded to FIT. The older STANDARD fit/all-corner STA applies to its original161-source graph and does not qualify the changed graph. Current complete FIT/STA, I/O constraints, all seven resource limits and critical-warning acceptance remain open.

The historical genuine181 source-bound run passes fifteen protocol/graphics checks: five completed-display RGB/strip targets, ordered38 credit/start replies and real firmware/CPU execution. Its twelve work-RAM byte differences remain unresolved. Finite real HPS profile2 admission passes fourteen checks; transport/display passes sixteen checks, including actual CONF_STR/menu-mask commands. These gates do not qualify guest DIP/cocktail/lives effects, physical display/I/O or the current banked full-game lifecycle. Japan720 finite RGB/audio evidence remains separate from strict Japan RAM differences. Ordinary61, current bug audit and Japan RAM diagnosis are retained with their source/fidelity limits. B16 and the eighteen-pixel residual remain open.

Next: compile the actual integrated native graph and execute the single root-released full1800 Stingray attract/gameplay lifecycle, finish current Kyros/Japan graphics/audio/RAM and documented bug gates, qualify game effects/pickup and genuine hiscore behavior, then finish current complete-design FIT/all-corner timing/resources/I/O review. Existing Japan601/Kyros4401 runs retain their own source-bound status and are not restarted by this integration. RBF assembly requires an explicit user request and remains a final conditional phase. No assembly, hardware or publication was performed by this source integration.

Evidence: research/functional_integration_v4_receipt.json. The original held v4 delivery67957255, plan0b6f2231 and helper10635ac5 remain immutable. Original490 evidence pins and exact historical progress recovery are retained; the release supplement adds only bounded parity/MAP metadata. This phase records source integration and available synthesis estimates; release readiness remains unqualified.


## 2026-10-11 - Source integration, fit and finite diagnostic status

Canonical source commit: 6cafdc7d5edac7a5403ac7224b74c996921de966. Root applied 15 updates, retained 493 evidence pins and 169 compact records, and verified 185 exact index files before the clean local commit. Final root activation, application and commit receipts are bound separately from the earlier frozen helper deliveries. The original Git whitespace rejection remains recoverable from capsule cap_f9732ef064ede351; no separate receipt is invented.

The banked MCU graph completed STANDARD fit and eight STA corners, both with native exit 0. All seven resource limits pass: ALMs 43.76%, LABs 69.72%, M10K blocks 60.58%, block memory bits 43.63%, DSPs 36.61%, average interconnect 17.0% and peak interconnect 33.7%. Fit reported zero critical warnings. Independent review accepts 64 positive timed tables across eight corners. Global minima are setup +0.341 ns, hold +0.076 ns, recovery +4.114 ns and removal +0.341 ns; game setup/hold are +4.585/+0.082 ns. Compiler warnings and inherited unconstrained I/O remain recorded. External electrical, physical CDC and current-gameplay acceptance remain open.

Independent epoch proof f016e846 accounts for the fitted sources: native 160 has 156 exact files, three HDL files differing only by CRLF-to-LF normalization, and the reviewed QSF overlay. Origin 161 has 157 exact files plus the same differences. All 116 flattened HDL assignments bind to canonical paths, with no missing or unexplained source differences. This proves source semantic equivalence; it does not claim an exact-byte canonical post-commit FIT or an additional compile. The pinned framework, original constraints and additive SDC remain intact.

Japan's paired 601-field runs both exited 0. Six RGB and six strip comparisons are exact; finite audio, input and protocol comparisons pass. Strict RAM remains failed: verifier exit 1, 14 of 15 checks, with eight differing bytes in seven words. Diagnosis be778dbd traces these selected differences to retired stack spills or exception frames below identical active supervisor A7, using actual lane writes and later MOVEM/RTE reads. This is a source-backed diagnosis, not a RAM waiver, physical IRQ timing proof or explanation of Stingray's separate twelve-byte gap. Original disassembly and consumer failures are preserved.

Corrected startup evidence distinguishes the callback-to-AS offset of 42 master ticks and callback-to-acceptance offset of 43 master ticks from the later ROM-period offset of 66 master ticks. All three use the 48 MHz master clock, not 68000 CPU cycles. The finite exact transaction and RAM-write prefixes do not qualify the first IRQ's AS/DTACK timing or close B16. No speculative CPU, IRQ, timer or clock correction was made.

The corrected pickup reference completed 2,400 fields with 18 of 18 finite observer checks and no pickup. Active input and sound taps validate the observation, but finite absence does not satisfy B04/P5. Source analysis distinguishes tile pickup 0x53 from transformed enemy types 0x24/0x25; retained snapshots prove neither an actual opportunity nor a shortest route. The failed first reference and superseded table coincidences remain recorded.

The historical Kyros observation at 2026-10-10 18:46 UTC records 3,439 of 4,401 fields, 57,344 pixels and zero renderer errors, with existing finishers alive. It is a partial observation of the original 75-source executable, not a terminal 4,401-field result or a current banked-graph graphics, audio or gameplay pass. Earlier process-probe denials remain inconclusive.

Current runtime admission: the corrected reference v5 completed 1,800 fields but missed the required Stingray player-two turn, death and earned-148 lifecycle targets. The costly current-source native Stingray 1,800 replay remains unreleased; reference completion does not authorize it. Japan 1,201 independent shared-native preparation remains source-only. No new native replay was launched by this phase.

The narrow joined-v2 STA permission was deployed with 262 regression checks and 48 independent checks, preserving the legitimate other-chat guard additions. This neither authorizes RBF assembly nor changes the two-job full-build queue ceiling. The bank-inference lesson receipt is retained without copying the global lessons corpus.

Next: obtain the missing genuine lifecycle coverage before any root-released Stingray native run; complete the prepared Japan hiscore/game-effect gates, strict Japan/Stingray RAM, B16, pickup/audio and final I/O/CDC/UCP acceptance. RBF assembly still requires an explicit user request. This phase updates progress and compact archives only. Evidence: research/post_join_status_phase_20261011/root_apply_receipt.json. Its preparation EPERM and missing shorthand exit-receipt filename failures remain recorded; both preceded any canonical write.


## 2026-10-11 - Native build and finite reference diagnostics

Baseline commit: 49042f1fbe5976f90010fe4c066850c65e4f97d0. Gameplay sources remain the integrated 6caf phase and banked board 43b8c6e7. Existing accepted fit/resource and scoped timing evidence remains separate from current gameplay, strict RAM, physical I/O and release acceptance.

The unified real-emu/HPS native build exited 0 after the producer checked 109 source files and its generator by compare-and-swap. ELF 89c08f5e17b13cff47c201d702f68c7e1a2095b451639e260bd9e56343d9c911 and effective source receipt 47753cdd bind the executable. The sole Japan 1,201-field worker is live, with a bounded observation at field 180 showing 57,344 core/VGA pixels and no renderer misses. This is a live progress observation, not a runtime terminal, hiscore, lifecycle or all-feature pass. Recovery: capsule cap_6fe3892d0950a9d6. No extra worker or replay was started by this evidence phase.

The authorized native first-IRQ 57-field diagnostic completed with build, run, qualifier and controller exits 0; all 13 invariant and coverage checks passed. It preserves the original 69-file temporal baseline, not the current banked whole-game graph. Of the unresolved additional 24 master ticks between startup offset 42 and later offset 66, the compact cause localizes the first eight inside first-IACK E/VPA service; the other sixteen and B16 remain open. These counts use the 48 MHz master clock, not 68000 CPU cycles. Separate later phase offsets are not additive proof of those 24 ticks.

The revised Stingray reference completed 1,800 MAME fields with exit 0. Its readonly qualification remains exit 1, 14 of 17 checks. Genuine player-one death, spare count 3 to 2, player-two turn at field 1,643 and the corresponding MCU command/bank selection are proven. The 284 screen-position writes are mostly X oscillation between 127 and 128: they prove actual control-state changes, not useful traversal or combat success. Score increments, changed earned-148 payload and restart remain absent. All fifteen original boot PNG/work/strip targets remain exact. The costly current-source native Stingray 1,800 replay remains unreleased.

Audio reference V9 completed 1,178 fields and stopped after 48 fields without source motion. MAME, supervisor and analysis exited 0; 17 of 17 finite checks passed. No command 0x53, actual pickup foreground or earned score was observed. These finite observations retain the barrier stop and pickup absence; they do not satisfy B04/P5, prove a complete route or qualify native audio. Source-only terrain/projectile research continues separately; forecasts are not runtime qualification.

The VPA proposal2 is source-only. It retains exact source-restoration checks, unchanged baseline host/header/build recipe, existing IACK joins and failed preparation receipts. No CPU/IRQ retiming patch, native replay or B16 closure is applied. The NXP E/VPA manual evidence leaves power-on E phase unspecified and autovector service phase-sensitive. Missing frame-57/58 stack windows prevent the proposed stronger phase proof.

The historical Kyros observation at 2026-10-10 19:15:46 UTC records 4,092 of 4,401 fields, 57,344 pixels and zero renderer errors, with the original native worker and finishers alive. Its ELF 8aeaa8d8 and 75-file closure remain distinct from the current banked graph. No terminal result, all-game graphics/audio pass or resolution of diagnostic unknowns is inferred.

The verified attotime lesson V3 was appended and indexed by root with actual exit 0. Only its local entry, manifest and apply receipt are retained; the global corpus is neither read nor copied. Prior invalid V2 path receipts remain producer recovery evidence.

Next: finish the already-owned Japan and Kyros runs; obtain the missing genuine Stingray score/earned-payload/restart coverage before any native 1,800 admission; continue strict Japan/Stingray RAM, B16, pickup and physical I/O/CDC acceptance. This phase retains compact metadata and progress only, skips existing archive copies, and leaves large captures/source/raw reports as producer recovery pins. No RTL, clock, donor/framework edit, Git operation, build, replay, RBF or hardware test is performed by the retention phase.


## 2026-10-11 - Sealed Kyros run and finite combat/input diagnostics

Baseline commit: 33abac86939e71cff65592e37596b957b07cedc2. Current gameplay sources remain the integrated 6caf phase and banked board 43b8c6e7. The following source-bound results do not establish all-game or release acceptance.

The historical Kyros native run completed all 4,401 fields with exit 0; metadata freezing also exited 0. Whole qualification failed with exit 1, 28 of 30 checks: two of 49 RGB targets and 37 of 49 work-RAM targets differ. All 49 sprite strip arrays are exact. PNG production qualified, while aggregate PNG comparison remains false. The 75-file closure, 167 native snapshots, 4,402 input rows and renderer checks pass. This is the historical pre-P2 ELF 8aeaa8d8 / closure 76411d80, not the current banked graph.

The first failed work target at field 240 has three bytes in two words; the full work failure scope includes 34 distinct high stack-area words. MAME last-write evidence exists, but native target PC/SP/SR, read and retirement context was not recorded, so stack cannot be waived. HUD candidate geometry and retained writes are identified without the native attributes, positions and pen/priority evidence needed for raster causality. Diagnostic unknowns, B16, audio, combat and P8 limits remain explicit.

One genuine Stingray first-hit reference completed 1,010 MAME fields with exit 0. The original finite terminal qualifier passes 11 of 11. Ordered source data proves the physical award at field 1,008: raw BCD 0010 commits to the score, producing 100 displayed points. The retained precommit score column detects it at field 1,009; the corrected readonly consumer passes without another capture or replay. Earned-148 payload, restart and native first-hit admission remain open. Earlier 284 screen-coordinate writes mostly oscillate between X 127 and 128, but world coordinate advances from 128 to 236. Screen jitter alone therefore proves neither stalled movement nor effective combat. Nine actual shots and sampled terrain-explosion paths do not qualify the full score/rank route or name entry.

The VPA overlay diagnostic compiled and ran; the original qualifier and worker exits 1 remain preserved. Corrected consumers 1 and 2 also failed; consumer 3 exits 0 with all 13 invariant checks. The original 12 CSV streams, nine full arrays, PCM, 130 cutoffs and input Lua remain exact. Its fresh diagnostic/source scope is retained separately from the current banked whole-game graph. The first eight additional master ticks are localized inside first-IACK service; the full additional 24 master ticks and B16 remain unresolved. Counts use the 48 MHz master clock, not 68000 CPU cycles.

Independent source/manual review identifies the actual CPU as FX68K and agrees with native edges. VPA asserted during IACK, with DTACK inactive, matches the physical contract. NXP figures B4/B5/B6 support phase-dependent E waiting and termination while leaving power-on E origin unspecified. No physically justified phase, IRQ, iStop or counter RTL alteration follows from this evidence. No RTL fix or current-graph timing closure is claimed.

Pickup V14 qualified its finite observer but exposed a stale Left input during the requested Up handoff. V15 proves a one-field consumed-input delay using actual CPU input reads. V16 corrects the legal neutral/Punch handoff and confirms settled consumed input before the next route segment. It completes 1,304 fields, stopping after 48 fields without source motion; observers qualify, but no genuine pickup record, command 0x53, earned score or native pickup acceptance occurs. Source-only V17 rules out the proposed camera clamp and player-qualified terrain blockage at that stop, and traces repeated collision flags through the actor-collision branch. Object producer binding remains under investigation; these source conclusions do not prove a completed route.

Japan's sole shared-native worker remains live. The latest already-observed field 540 has 57,344 core/VGA pixels and no misses; no terminal receipt exists. Recovery: capsule cap_40d22ec993dda07a. First-hit native preparation remains unreleased. No new watcher, capture or replay was started by this import phase.

Next: qualify the already-owned Japan terminal when available; continue strict Kyros/Japan/Stingray RAM and raster/audio diagnosis with missing native context explicit; obtain earned payload, restart, rank and pickup coverage before further native admission. Existing fitted resource and scoped timing evidence remains separate from external I/O/CDC and current-gameplay acceptance. This phase changes progress/archive records only, skips existing compact archives, and retains raw failures and large captures as producer recovery handles. No source change, Git commit, build, replay, RBF or hardware test is performed by this retention phase.

Root integration update: earned payload, name entry, restart and pickup remain completion gates. They do not prevent the separately authorized finite current-source Stingray first-hit replay. Its host-only relink and single 1,010-field run require the exact delta review and fresh source/object/ROM checks; no worker is inferred from authorization alone.

The first-hit host review caught a passive observer error before launch: SIM_PORT_DATA is CPU write data, while accepted read results use SIM_PORT_OUT. The live Japan feature-read CSV has the same unqualified data column. Its separate settled physical-work journal already records SIM_PORT_OUT with transaction and architectural context; any terminal consumer repair must bind that journal's actual edge. Physical RAM score, cached DIP, restore and CPU ownership guards remain separate. The live executable is unchanged and has not been restarted.

Pickup source evidence V18 identifies actor 204e0, type 11, as the actual V16 blocker. V19 proves that legal Jump bypasses this actor collision while preserving terrain checks. One corrected reference with at most two bounded jump pulses is authorized; genuine pickup, command 53 and native sound acceptance remain unproven. V18/V19 manifests are retained as additional compact evidence.


## 2026-10-11 - Jump observer correction and execution policy

Baseline documentation commit: 7dc47822b339caff9e347d0c9b315e34119631b4. Functional source remains 6cafdc7d5edac7a5403ac7224b74c996921de966 and banked board 43b8c6e7. This phase does not establish all-game or release acceptance.

Pickup V20 completed 1,264 MAME fields with MAME/supervisor exits 0 but stopped at type11_jump_flag_activation_failed. The observer PC guard was wrong; preserve this failed finite attempt. Source/retained-data consumers V21 and V22 bind actual PC 0x5c18, A4 0x20400 and the high-byte write at 0x2040a: data 0x0303 with mask 0xff00 commits 0x0300. Four consumed input reads of 0x28 in that field and flag bit 1 establish legal Jump and partial actor bypass. They are readonly analyses, not new guest execution.

V23 applies the reviewed guard-only observer correction. The genuine reference terminates after 1,284 fields with MAME/supervisor exits 0 and a qualified observer, stopping at type11_jump_pulse_max24. Final world X is 86, map is 0x01e6 and HP is 80. The legal Jump is observed; full crossing and pickup remain unqualified. No command 0x53 or genuine pickup is reported, and no native pickup acceptance follows. V24 is source-only coverage of all four effect slots at 0x20c40/44/48/4c, including the fourth consumer fallthrough. Absence in the narrow 0x20c40 observer must not be reported as absence in all four slots.

The reviewed first-hit native V2 host relink exits 0 and binds a fresh 28-file CAS, unchanged generated archive/API/runtime objects and isolated ELF b4931523. Its registered 1,010-field worker remains live: the latest already-observed field 60 has 57,344 core/VGA pixels and zero misses. This is not terminal or native first-hit acceptance. The sole Japan worker was already observed at field 870 on ELF 89c08; no terminal result is claimed. No additional watcher or replay is created by this package.

Correction to the historical 7dc root supplement: actual FX68K .iEdb(mdin) carries CPU reads and .oEdb(mdout) carries CPU writes. The earlier claim that mdin carried CPU writes was wrong. Original Japan accepted-feature read records using mdin are valid; the settled mdout write journal cannot repair a read column and does not invalidate those Japan records. First-hit V2 returned-word data is unqualified because its attempted read alias correction was wrong. This observer defect does not alter the running game or retract the physical score award. Preserve frozen admission/review failures; do not restart the live worker solely for this column. Source 6caf remains unchanged.

The frozen name-controller contract passes its finite source qualification: 322 ROM-matched instructions and 18 byte/lane bindings. Name entry requires verified entry/init ancestry; each legal Button1 pulse waits for consumed release and accepted-character count advancement. Source table/lifecycle/extra-life bindings do not qualify runtime name entry, earned-148 payload, persistence/reload or restart. Further score-controller integration is a separate source proposal until frozen and reviewed.

Pinned Lua 5.4.9 tooling records build/version/valid syntax exits 0 and the expected invalid-syntax exit 1. Earlier permission failures remain preserved. Syntax qualification executes no game and establishes no semantic route or runtime acceptance.

The grouped plan, goal prompt and AGENTS policy documents preserve explicit CURRENT build-request and current-image gates, the historical Kyros execution exit 0 versus strict qualification exit 1 (28 of 30 aggregate checks, two of 49 RGB and 37 of 49 raw work targets failing), and pending current-source qualification. One exact reviewed clarification calls the historical ELF an earlier staged HDL source epoch. Frozen producer V2 documents remain unchanged.

Next: analyze the qualified Jump pulse limit before another pickup admission; qualify already-owned native terminal results when available; complete earned payload, name, restart and strict graphics/RAM gates. Existing fitted resource and scoped timing results do not close external I/O/CDC or current gameplay gates. Timing offsets use 48 MHz master ticks. This package stages three policy documents, one minimal local Lua-tool .gitignore entry and new compact evidence only, preserves raw handles and earlier failures, and performs no canonical edits, Git operation, build, replay, RBF or hardware test.

Global prevention lesson appended once with backup outside instruction loading paths; native append and index exited 0. The scoped archive attributes preserve raw evidence bytes and unified-diff context whitespace.


## 2026-10-11 - Native protocol terminal and corrected source models

Baseline commit: 5abb2dc445e06760e1b214db94065264ba83e310. Functional source remains 6cafdc7d5edac7a5403ac7224b74c996921de966 and banked board 43b8c6e7. Existing archives remain exact; this phase does not establish all-game or release acceptance.

Pickup V27 completes 1,546 genuine MAME fields with MAME/supervisor exits 0, stopping at source_no_motion48 with no pickup or command 0x53. V28 proves legal release at 1,283 and actual landing at 1,293: flags, timer and state clear with consumed neutral input. Actual player-qualified terrain reads differ from the earlier static projection. V29 binds the changed terrain writer at field 1,197 and PC 0x2468; the later unchanged RMW is not that producer. V30 corrects the source model's D0-only clear, unmasked A1 and class-0x2000 paired-byte increments, reproducing 512 ordered normal-word writes across eight map rows and actual word 0x0977 at 0x411e4. Independent source review passes 71 ROM-instruction checks and the 512 writes. The actual target is 0x2364 at 0x4101a, superseding the failed 0x2362 assertion. A record observed in effect slot 0x20c44 is an opportunity, not pickup success, earned score or native acceptance. No next pickup runtime is recorded here.

Current Kyros V3 passes its independent source/relink admission review; host-only relink exits 0. Its one registered 4,401-field native worker is live on ELF 76a79426, not a terminal qualification. The recovered observation shows the real HPS ROM release; lack of a completed field in that recovered tail is not a hang diagnosis. First-hit V2 is also live; its already-owned field-450 observation is not terminal acceptance and its returned-word observer column remains unqualified. Historical joined-75/pre-P2 graphics and RAM failures remain strict and do not transfer to this current run. The actual CPU data direction remains mdin for reads and mdout for writes; the previous false direction claim stays retracted.

Japan's native 1,201-field run exits 0. Initial consumer failures remain visible: V2 passed eight of nine checks but used an invalid all-writer owner-cardinality assumption on non-hiscore rows. V3 classifies 13 same-edge source-derived legacy HLE read commands and passes all nine finite protocol checks without a rerun or waiver. The genuine CPU best score is 1,000 and matches the official reference at field 1,200. The exact 178-byte save/restore, reset clearing, grant revocation, exclusive physical hiscore commits and resumed CPU transactions are evidenced. The independent audit passes 24 of 24 checks and accepts the finite 178-byte persistence subgates only. Its evidence includes 1,068 exclusive restore strobes covering exactly 178 bytes, 239 reset/revocation rows and 292 resumed CPU transactions. The run consumes the 1,200-action prefix of an 1,800-action planned route; it does not qualify the unused route tail. Broader graphics, raw RAM, audio, physical MCU timing and B16 remain separate gates. Original Japan mdin read records remain valid; a mdout write journal cannot replace their read column.

Japan finite audio review passes ten integrity checks: 974,020 mono signed-16 samples at 48 kHz, one enable per 1,000 master ticks, 20.292083 seconds, zero clipping/counter reset and exact accepted chip-write counts. It preserves earlier local preparation failures and differs from the official 601-field comparison window; waveform/event equality, warm-reset tail and B03/B04 effects remain unqualified.

The earned-rank V3 supervisor passes independent source review, conditional on fresh source CAS, claim and successful MAME-family scans. Its real preclaim attempt exits 1 after finding an unrelated CrystalSystem MAME process, which was left untouched. No claim, child MAME or game fields were created by that failed admission. Earlier supervisor/consumer findings remain preserved. Any separately authorized resubmission and eventual score/name/earned-148/restart result require their own actual receipts; source PASS is not runtime acceptance.

The historical same-69 IRQ57 review localizes the first extra eight master ticks to completed stack service but leaves 16 master ticks unlocalized because four native service windows were not captured. These are 48 MHz master ticks. No current-bank timing qualification or IRQ/phase/RTL fix follows from those missing windows.

Kyros lifecycle labels and event records bind credit, packed BCD lives, energy and depletion bytes at 49 historical checkpoints, with named bytes matching historical native captures. The required actor erratum identifies ROM 0x48ce as LEA ($400,A6),A4 and a static caller at 0x9e12. The old 'at B04' clause confused a gate identifier with a code address, and the ROM 0x0b04 embedded-data excerpt is superseded. MAME taps lack actual PC/caller and read consumers, so static routines do not prove runtime ownership. Actor state-4 eligibility occurs at field 4,290 only. Complete death/game-over/attract scenes and actual hit/jump/pickup success remain unqualified. No historical-to-current acceptance is implied.

Next: qualify the already-owned current native terminal when available; complete strict graphics/RAM and gameplay gates; use corrected source models before additional route admission. Existing resource and scoped timing results remain separate from external I/O/CDC and current-gameplay acceptance. This phase stages progress and new compact research records only, preserves raw handles and failed qualifiers, and performs no canonical edit, source change, Git mutation, build, runtime, RBF or hardware test.


The subsequent Japan whole-fidelity V2 consumer exits 1 with ten of 13 checks passing. All ten sprite arrays and nine of ten RGB targets are exact. The field-900 RGB failure is exactly four pixels and nine bytes: (26,8), (27,8) and (28,8) are blue versus red; (29,15) is blue versus dd9966. The bounding box is x26..29/y8..15. Strict work differences total 11 bytes across fields 240, 360, 600, 900 and 1,200. The instruction trace is unavailable, not equal. Exactly 1,200 source-epoch post-field input rows pass; V1's wrong expected-row failure remains preserved. The accepted finite 178-byte persistence and audio-integrity scopes do not waive these full-game failures or transfer the historical 601-field retired-stack diagnosis.

The separately admitted ONE earned-rank reference attempt is now used. After the unrelated process closed and fresh admission succeeded, MAME exits 0 after 3,782 fields with the honest early stop score_progress_unmet600_fields. Genuine scores reach P1 400 and P2 200; rank, name/earned-148, game-over and restart remain false. The original consumer exception on preboot BCD b8b8b9b9 is preserved. A minimal readonly post-init valid-rank guard allows reporting without another capture: the corrected consumer still exits 1, eleven of 16 checks passing, with all five rank/name/earned-148/game-over/restart checks false. Physical first hit at field 1,008, original actions, boot, source/input/ports and oracles pass within that finite scope. Both the earlier preclaim failure and this original consumer failure remain visible. No retry, extension or further game run is authorized by this supplement.

Latest already-owned observations at 20:46 UTC show first-hit V2 field 780 and current Kyros V3 field 270, both with 57,344 core/VGA pixels and zero misses. Both remain live with no terminal or probe acceptance; this observation supersedes the earlier recovered tail without diagnosing a hang. The source direction retraction remains authoritative, and first-hit's returned-word observer stays unqualified. This V2 supplement preserves the frozen base packet, reuses its 42 records and raw handles without producer revalidation, and adds only compact finite outcomes. No source, plan, canonical, Git, build or runtime mutation is performed here.


Finite read-sampling and first-hit evidence phase, 2026-10-11

The functional source remains 6cafdc7d5edac7a5403ac7224b74c996921de966, with banked MCU board 43b8c6e7600e4c4089f0d3c0e4a15637be8bfcbdd626ddd0bc0e222b7b1553ce. This phase changes progress and compact evidence only. It does not alter RTL, constraints, framework sources or release outputs.

The current-source Kyros field-240 comparison has exact core/VGA RGB and sprites but still fails strict work RAM by three bytes. The temporal V2 correction requires completion of the entire 30-word register save and an intervening SSP transition before selecting later equality. It supersedes the original equality/restoration interpretation, which could select an ongoing save. All saved-word board-read requests and subsequent 15-register/anchor-SSP equality are observed under the corrected selection. PRE-edge mdin is a board-service sample, not proof of the final FX68K read latch, RTE control retirement or MAME architectural ownership. The strict RAM failure remains open. The global read-latch lesson was already appended and indexed once; only its compact applied receipt and entry are retained here.

The Stingray first-hit native run ended with actual exit 1: the host compared assembled DIP word 9300 with byte 93. The genuine CPU writes score 0010 at field 1008, representing 100 points, but no result/first_hit.json was produced. The separate whole V2 consumer exits 1 with ten of 15 checks passing. Seven of eleven RGB targets and seven of eleven sprite arrays are exact; only three of eleven work targets are exact. Late RGB, sprite and RAM failures remain strict. Its V1 post-callback input-representation failure is preserved. Original PRE-callback tape and 1009 post-field HPS rows match transport, without proving guest input/beam timing equivalence. Source localization places the first sampled work failure at field 119 before either retained tape becomes nonzero, with RGB/sprites exact through 360 and the first sampled graphics failure at 600. The precise divergence cycle between 360 and 600 and its cause remain unknown; input delay or a renderer defect is not established.

Pickup work advanced from source preparation to one bounded official reference. V31 records a finite normal-plane search gap; its separate vertical ceiling is unqualified. V32 and its mandatory corrigendum bind the actual animation/age records to PCs C210 and 5146, preserving the wrong original narrative strings. The V33 candidate route uses 2250 fields within the existing 2318 bound and recognizes phase-equivalent normal 2360/2364 from table 28. V35 already guarded its whole frame step with xpcall; V36 scalar guards are defensive clarification. V36's concrete consumer correction requires exact ordered/projected/committed +100 score evidence. Syntax, AST and source CAS checks pass, and independent V36 review passes all 14 source pins. The one official reference was subsequently admitted after fresh CAS, successful MAME-family scans and an exclusive owner claim. Actual MAME and supervisor exits are 0 after 1822 fields, stopping at pickup_owner_generation_invalidated. The observer is qualified, while tracked semantic pickup and native acceptance remain false. Actual target access and a raw queued 53 occur at field 1821; these do not qualify tracked-generation acceptance, consumption or earned score. Global queued-53 absence must not be inferred. No retry or native run is admitted by this evidence phase.

The source-only Stingray score-stall diagnosis separates world movement from screen oscillation and identifies a controller policy gap, without proving the physical collision/input-read cause. Independent V1 review required reverse-stop priority and inactive/reentry history resets. Corrected V2 stages those changes with syntax checks, and independent V2 source rereview passes all 24 pins. Behavioral Lua cases remain unexecuted; source review does not establish runtime readiness or authorize another score attempt. It does not authorize another reference game or establish rank, name, earned-148, game-over, persistence or restart acceptance.

The external I/O review accounts for the exact port/path classes and finds no missing internal clock. Its source-supported LED exception is an unapplied candidate; complete numeric I/O constraints still require the physical interface contracts. The HUD review passes 13 static contracts with no definite RTL bug: native game RGB precedes the framework, while the winning generation/PROM/pixel-phase evidence remains incomplete. Compiled wrapper differences are read-only VERILATOR aliases, not a new functional change. Current probe coverage at Kyros y19 does not cover the Japan y8..15 mismatch.

The existing performance record describes first-hit native exit 1 at about 3.83 seconds per field and then-observed current Kyros field 720 at about 3.76 seconds per field. A roughly 4.6-hour projection for 4401 fields is an observation, not a benchmark or acceptance result. Both hosts already conditionally reevaluate SDRAM DQ; no new optimization, speedup or dominant cost is proved. Current Kyros remains live with no whole-run acceptance. Timing/resource scopes remain as previously recorded; external I/O, strict game fidelity and current-image gates remain open. No RBF was requested or built.

The finite Stingray MCU source audit passes ten source checks. Official MAME uses the real I8748 at 9263750 Hz divided by 15, matching the physical T48 contract; the 800 kHz IRQ/HLE description applies to Kyros only. Logical command, coin, DIP and player-two interfaces and nominal raster match. MAME callback/HALT scheduling and registered RTL bus/MCU phases differ; AS-high enable freeze is documented. No clock, input or RTL correction, phase causality or whole-game fidelity follows from this source audit. Strict field-119 work and field-600 sprite/RGB failures remain open.


HALT source and finite reference phase, 2026-10-11

Root applied the reviewed HALT board delta to the source graph derived from functional revision 6cafdc7d5edac7a5403ac7224b74c996921de966. The pending board SHA is 63999966e2b74ca1f524dfba36e6bba9ebbe0eed4a04ed16a73e83bbeec647c2; wrapper 894197513ff916c2df0bf8783bf0bfe0903a4bb577b7464b85e1356cf1c5da30 and the pinned framework remain unchanged. The source review supports the FX68K pin-HALT control and free-running E implementation, while actual PCB wiring and the cause of strict work/graphics differences remain unproven. Static profile-0/1 equivalence does not transfer dynamic game acceptance.

The new HALT source graph has actual map, fit and built-in eight-corner STA exits 0. All seven resource limits pass. The compiler distinguishes logic-needed 18276/41910 (43.61 percent) from physical placed ALMs 22130/41910 (52.80 percent); both are retained. LAB use is 2949, M10K use 335, block bits 2470744 and DSP use 41. Average interconnect is 17.6 percent and peak interconnect 34 percent. Built-in worst setup/hold/recovery/removal/pulse slack is +0.303/+0.079/+3.908/+0.400/+1.041 ns. These are the new graph's scoped results, not transferred old-graph timing. The frontend and supervisor exit 1 because external paths remain unconstrained: 20 input ports, 85 output ports, 179 setup paths (30 input and 149 output) plus 179 hold paths, 358 total. Critical warnings are absent; full external-I/O timing and release acceptance remain open. The owned detailed STA supplement exits 0 using the same fitted database without refitting, after its preserved initial project-open permission failure. All eight corners have game setup/hold minima +4.399/+0.113 ns, audio +14.290/+0.162 ns and pulse +1.041 ns. The final compact qualifier passes 72 checks. A full clock-transfer matrix was not collected; no CDC, hardware or release timing acceptance follows. No RBF was requested or produced.

Current-source Kyros field 900 still fails strict comparison by four RGB pixels and one raw work byte. Core and VGA agree and all 8192 sprite bytes are exact. The frozen prefix has no closed bus/IRQ/HUD journal and both HUD streams are empty; standalone 900 register arrays are absent. It cannot establish winning pixel generation, read consumption, RTE retirement or a RAM waiver. The pre-HALT 4401 run remains separate and unaccepted, with latest owned live progress at field 1890. A future private observer passes source review and host-only compilation, yielding isolated ELF 384a838b2cc0c1e4a1780823d1c3e876319c5fbc5d784f01768093bac3326f2b, with the original WSL inventory failure preserved. Compiler exit 0 is not gameplay admission or acceptance. Root reports current-HALT model code generation/API checks and make-only recovery exit 0 after a preserved PCH/tmpfs-full failure; gameplay was not launched at that observation. The combined 180-field model (fields 0 through 179) is not a game or physical timing acceptance result.

The official MAME pickup V40 reference now passes its finite semantic gate: actual MAME and supervisor exits 0 after 1853 fields, with 30 post-event fields. The same 20c44 generation born at 1371 shows target access/clear, real queue/buffer handoff and ordered/committed +100 at 1821, followed by actual accepted and consumed command 53 at 1822. Native pickup and audio qualification remain open. V37 proves the legal low-word-first CLR followed by its high-word clear, preserving original V36 semanticfalse and preparation failures. V38 is a source/observer correction and V39 establishes the TRAP4 copy/queue clear plus conditional dispatcher contract; neither independently proves consumption. Official Lua BUS/P2 callbacks bypass AS_IO MOVX taps and a P2 latch is not an edge. Callback capture coverage must match those source interfaces.

The separately authorized ONE rank reference ends with actual MAME exit 0 after 3764 fields and supervisor exit 1 because the global post-exit inventory is UNKNOWN. The first strict readonly terminal consumer exits 1 with ten of 16 checks passing, preserving its lane-false and game failures; the causal consumer exits 0 within its narrower source scope. Genuine scores reach 400/400, but rank, name/earned-148, game-over and restart remain false. There are 601 scoreless fields; quarantine events and 34 fire requests/shot-pipeline evidence prevent transferring the previous no-fire explanation to the whole new interval. Projection/later-read/collision limits and 135 coverage gaps remain explicit. No retry or extension is implied.

The IRQ residuals are 24 total, eight localized and 16 unresolved 48 MHz master ticks, equivalent to three, one and two nominal 6 MHz CPU clocks. Four missing service windows and the separate frame-56 detailed-clock gap remain limitations; this is not a current-graph timing or causality pass. Strict field-119 work and field-600 sprite/RGB failures, physical I/O, complete game lifecycle, native pickup/audio and current-image release gates remain open. This grouped phase retains new compact metadata with producer recovery handles, preserving prior archives and raw captures without revalidation or duplicate runtime/builds.


Runtime asset and bounded evidence phase, 2026-10-11

The source baseline is clean main d079d62f61fe72a0e19bd8aac4db4b11a054d176. Board 63999966e2b74ca1f524dfba36e6bba9ebbe0eed4a04ed16a73e83bbeec647c2 and wrapper 894197513ff916c2df0bf8783bf0bfe0903a4bb577b7464b85e1356cf1c5da30 are unchanged. This phase updates progress and compact evidence only, preserving the previous timing/resource and external-I/O qualification limits.

The first combined runtime is frozen as invalid: native exit 15/SIGTERM15, supervisor exit 1 and both consumers exit 1. The compiled FX68K readmem assets were missing from its working directory, with authentic loader warnings retained. This does not prove a HALT regression. The isolated compilation has code generation, API and make-only recovery exits 0; its PCH/tmpfs-full failure remains preserved. The corrected V2 uses the same ELF7238 and unchanged source113 with exactly two relative readmem assets, microrom and nanorom, in the correct working directory. Their immutable sizes/hashes and source/runtime admission are retained as recovery handles; no binary or ROM data is archived here. Early counters show healthy CPU service but do not independently qualify a terminal game.

The corrected V2 runtime uses the same compiled ELF and source graph as the invalid first attempt, with both required FX68K readmem assets present. Its authentic native exit is 1: "HALT boundary event cap exceeded; no truncation". The last retained field is 118. This diagnostic cap failure does not establish a HALT or core regression.

Both first consumers exit 1 with empty stderr. All nine available full RGB, work RAM and sprite comparisons at fields 0, 30 and 90 are exact. Six target files for fields 119 and 179 are missing; their checks are false. All nine aggregate array/protocol gates are false and the summary is empty. No complete 180-field endpoint or whole-game acceptance is claimed.

Four finite latch checks pass over 4253 events and 8778 actual captures, with model_bad=0 and physical_commit_bad=0. The missing field 119 cut and four producer checks remain false. These finite observations do not transfer acceptance to the missing endpoints, physical PCB wiring or broader timing and gameplay gates. Canonical board639 and isolated model7238 remain unchanged.


Rank V5 admission ended with authentic supervisor45568 exit 1 before claim, child MAME or capture. The fresh inventory identified external mame.exe PID52048 at D:/Arcade/AI/mameexe/mame.exe, owner unknown; its path differs from the pinned reference binary. It was left untouched. This known-process failure is separate from the earlier postscan UNKNOWN. The exact root_admit_once.py producer pin remains bound, without invocation or retry by this phase.

The approved B04 materialization exits 0, emitting 1853 tape rows and 99 full target arrays, 33 each for RGB/work/sprites. It follows the explicitly reviewed REQUESTED_AFTER_CALLBACK_F contract: seed0 plus postF0..1851, leaving source row1852 unconsumed. Materialization, compilation and transport records are not native semantic or gameplay qualification. Actual guest input/latch/beam epoch, strict native B04 pickup, audio rate/mix/clipping and gameplay qualification remain open; no bit-identical PCM claim. Preserve every original failure, source epoch and strict RAM/RGB/sprite limit; no old array archive or large journal is reread by this package. No RBF build, push, additional model generation, MAME run or native replay is authorized or performed here.

The current HALT external-I/O source review passes 19 finite checks. All eight current unconstrained-path edge tables remain identical at 179 setup plus 179 hold paths; physical interface facts are absent and the external-I/O gate remains open. The indicator-only constraint is an unapplied candidate. No numeric I/O timing, full transfer-matrix, CDC, hardware or release acceptance follows from this metadata review.


Component and host preparation phase, 2026-10-11

The source baseline is clean main 7ce66ae862a55b0541131afb7974915e256bdae4. Board639 and wrapper894 are unchanged. This phase retains compact completed evidence and updates progress only. The current internal timing checks and all seven resource limits remain passed within their recorded scope; the 358 external-I/O setup/hold paths and physical hardware contracts remain open.

B11 V4 completed the actual isolated renderer component compilation and execution with native/build/root exits 0. Its independent scoped qualification passes nine cases, 2304 exact pens and 28 request acknowledgements with ACK+1/READY+2 timing, matching source CAS and no warning lines. This closes only the recorded component fixture requirement. It does not qualify a whole game, gameplay, current-image graphics or Quartus resources.

The minimal HALT recorder host relink V3 completed with child exit 0 and empty stderr. Its closed binding retains original generated verification, unchanged protected source/header/archive hashes and both required FX68K micro/nano assets in the runtime working directory. The new isolated ELF is 28b4842c5c76b5833c2c7ea993af6e4f9654afe395db2434f541b42d0ed0fe81. The host remains byte-identical to V6; the recorder-header change creates no HDL generation, clock or core change. Independent source review passes only this preparation scope. The future corrected 180-field runtime remains preparation; no game or consumer acceptance is claimed here.

B04 strict consumer V50 passes independent source review after three preserved V49 causal guard corrections. The consumer has not executed and no native 1853-field pickup replay has run. Input, DIP and coin equivalence, actual FX latch/retirement evidence and strict native B04 qualification remain open. Prefetch is not retirement and no bit-identical PCM claim is made. Audio readiness remains open for B03, B05, B06 and B13; rate, mix, clipping and gameplay effects require their applicable evidence.

All original failures, source epochs and strict RAM/RGB/sprite differences remain preserved. Raw captures, journals, ELF binaries and prior archives are recovery handles only and are not recopied or rehashed. No source change, new runtime, model generation, Quartus job, RBF build, hardware acceptance or push is performed or authorized by this package.


Kyros-only finish and release scope, human instructions 2026-10-11

Active work and required completion gates are now Kyros only. Keep the Japan MRA intact; retain existing Japan/Super Stingray sources, MRAs and evidence without new development or tests. Finish tasks already underway within their current authorization and preserve actual terminal results. The main plan now reflects this scope.

The reported current Kyros field900 four-pixel difference, x26..29/y19 with blue/red colors, is PASSED_BY_USER_ACCEPTANCE. Keep its exact mismatch count, coordinates and functional6caf/ELF76a79426 source epoch. It is not byte-exact equality, is no longer a graphics blocker and needs no pixel-fix work. Do not mark Japan graphics passed or accept any additional/undiscovered graphics differences through this instruction. RAM, CPU/IRQ, inputs, audio, hiscore/reset/restart and timing remain independent gates. The existing long Kyros4401 task continues because RAM, gameplay and IRQ evidence is still needed.

The user explicitly requested finishing current work, then building one release RBF and stopping. Final assembly is authorized only after applicable current Kyros gates are closed, using the reviewed complete release recipe, QuartusFast --mode release --allow-rbf and the host-wide FIFO/two-job ceiling. No deployment or push is requested. This metadata proposal makes no source/runtime/compiler change or acceptance transfer; source baseline f0068ee9d0a40a73d4332720516e2be746513cbd, board639 and wrapper894 are unchanged.

## User-requested Kyros RBF — 2026-10-11

Built current source `78442adefdf39b23456681fa1dc7a66c2332868b` through QuartusFast RELEASE and the shared FIFO. Canonical RTL and original release outputs were preserved. Native compile and eight-corner checks exit 0; RBF generation succeeds. Frontend exit 1 retains the known 358 unconstrained external I/O paths (20 input/85 output ports), so full timing/release qualification remains open. No critical warnings. All eight constrained corners pass: setup +0.132 ns, hold +0.079 ns, recovery +3.474 ns, removal +0.314 ns, pulse +1.041 ns.

All seven strict resource limits pass: physical ALMs 52.92%, LABs 69.79%, peak H/V 35.1%, average worst H/V 17.4%, M10K 60.58%, allocated block-memory bits 60.58%, DSP 36.61%.

Artifact: `D:\Arcade\AI\aCORES\Alpha68k N\research\kyros_rbf_requested_20261011\final_artifact\Alpha68k_N.rbf` (3618076 bytes), SHA256 `ff4a7268f782f0ea60500d09b1a9125c2edd79774dd936ab33cff5f85fcf096e`. Receipt: `D:\Arcade\AI\aCORES\Alpha68k N\research\kyros_rbf_requested_20261011\final_artifact\build_receipt.json`. Graphics retain the accepted four-pixel tolerance; outstanding functional/RAM/IRQ/audio checks remain unqualified. Japan MRA unchanged. No deployment, push or automatic rebuild. Build work stopped after artifact and report capture.


## 2026-10-11 — Credits, OSD behavior, Stingray MRA and Kyros audio audit

Source entering this phase: `41e0f0465d44ea44df161a1ac1956c353891d4e8`. Integrated the full supplied CREDITS package, supporter list, native 256x224 credits screen, Credits menu entry and themed OSD background; preserved the original OSD source and chained the original build-ID preprocessing. Menu opening no longer requests game pause or the hiscore save pause; mapped manual Pause and safe hiscore transactions remain.

Generated `releases/Super Stingray (Japan).mra` with Main weapon/Sub weapon labels, profile2, exact audited 655360-byte ROM expansion, original DIPs and 148-byte hiscore configuration. Control provenance and literal printed-label limitation are recorded in `docs/sstingry_controls.md`. Kyros and Japan MRAs were not rewritten; the independent Kyros Demo Sounds polarity audit passed without changes.

The online audio audit added six report dispositions to `mamebug.md`; `docs/kyros_audio_audit.md` records measured scope and limits. ROM/DAC/rate checks passed; first-eight-second native PCM has zero rails and the closed capture has zero mixer clipping. Four offline diagnostic tests passed. No verified voice fault justified an audio RTL change. MT02868 confirms the original coin laugh, not Demo Sounds Off behavior.

Decisive current-source credits/component evidence: `D:\Arcade\AI\aCORES\Alpha68k N\research\credits_integration_20261011\minimum_qualification.json` SHA256 `401477e61a9da0491541b108663843441bef4bc3a42c899b8beb4d3d0713048c`. Current-source isolated check-only timing/resource evidence: `D:\Arcade\AI\aCORES\Alpha68k N\research\current_credits_audio_timing_run_20261011_v4\qualification_final.json` SHA256 `e5293941bc94312fbd9d2e79b3f523de011e42c669a641ea5058155055f336e9`; preserve its actual results and qualification limits. No RBF was built or hardware settings changed for this phase. The existing ff4a7268... RBF predates the credits and OSD pause source changes. Next action: a separately requested RBF rebuild can include these changes; a claimed sound repair still requires a reproduced audio divergence.

Actual timing/resource result: Native synthesis/fit/STA/eight-corner collection all exit0; frontend exit1 retains 358 external I/O paths OPEN. Internal minima ns: setup +0.406, hold +0.070, recovery +4.417, removal +0.344, pulse +1.041. All seven strict caps PASS: ALMs needed18519/41910=44.19%, physical22389=53.42%; LAB2934/4191=70.01%; M10K338/553=61.12%; logical memory2497368/5662720=44.10%, allocated3461120=61.12%; DSP41/112=36.61%; peak H31.6/V40.7%=40.7%; average H18.1/V16.8%=18.1%. Zero critical warnings. No full timing closure, hardware qualification or RBF claim.


## Dual-game release audit resumed — 2026-10-11

Human request now includes Kyros and Super Stingray correctness, MRA controls, and a shared release RBF after confirmation. Japan MRA remains retained. Baseline HEAD379864d4c379f5349b1d520b570d3fadce18e5c4. Parallel agents own game/RAM diagnosis, MRA audit, current wrapper preflight, bug obligations, timing constraints and isolated release recipe. Root integrates shared functional changes.

Both release MRAs passed source-level action/direction/start/coin/pause mapping, clockwise rotation, all DIP masks/settings/defaults, profile bytes and exact audited 655360-byte ROM expansion. No MRA edit needed. Evidence: D:/Arcade/AI/aCORES/Alpha68k N/research/dual_release_20261011/mra/import_manifest.json SHA4899417a7d523df7258fb91b201a6ceba6be51c28e0d12364631c8d71f36a2b6. Actual Button2/cocktail guest behavior and firmware label override remain separate runtime checks.

The closed4401 native Kyros run exits0 but its reviewed strict consumer exits1, six of eight checks passing. The already-accepted field900 four pixels remain accepted; field4400 eight pixels and raw work differences remain separate and unqualified. New readonly consumer evidence: research/dual_release_20261011/kyros/closed4401_qualification_v1/qualification.json SHAb169ca3d2213463990ed9f31e86ba28849966c459203ac5aadf037c149cca262. Current Stingray first119 RAM and later600 graphics causes remain under investigation.

Current internal eight-corner timing and all seven resource caps pass within the existing receipt scope; 358 external I/O paths remain open. Source audit: research/dual_release_20261011/timing/source_constraint_audit_v1/import_manifest.json SHA64cd004e1e4d7dc40479c5805f0f4084e5c556415a8a2ab58fc20475823096d6. Installed SDRAM details requested; independently supported board/interface constraints are being investigated. No guessed timing exceptions.

The release frontend omits .txt inputs. A reviewed isolated-only byte-identical .dat credits input and filename-only Tcl patch preserve the original preprocessing chain and all five generated 40-column outputs; actual native Tcl preflow exits0. Recipe is held pending game and timing gates: research/dual_release_20261011/build/recipe_v2_import_manifest.json SHA7b300494dff13454f6ef57386c364c56ece9cf6f30a9ad0aae4c4da88e97646c. No RBF or Quartus job launched for this request yet. Generic current-source preflight reported zero frames and incomplete SDRAM loading; contract/cause diagnosis and current wrapper harness repair remain underway, with original report preserved.


## Dual-profile wrapper protocol qualification — 2026-10-11

Baseline HEAD379864. Updated only simulation harness files sim/build_wrapper.sh and sim/wrapper_main.cpp: complete current MCU/T48/credits/readmem source closure, durable ext4 generated-model storage, explicit six-field protocol mode, real HPS credits/menu interaction, OSD gameplay continuation, manual Pause and exact synthetic hiscore restore/save checks. The full video/features suite is retained. Production RTL and MRAs unchanged.

Kyros and Super Stingray each completed six fields with actual native exit0 on one current-source ELF db549c984fa57106a7911de43427af41093bca58f65809f96968916c7caefea6. All 92 compiled source pins match canonical; core/VGA equality at settled fields4/5, no unmapped/deadline/overflow/duplicates, all DIP transports and actual credits/OSD/manual-pause protocol checks passed. Synthetic restore/save payloads were byte-exact at178/148 bytes. Evidence: D:/Arcade/AI/aCORES/Alpha68k N/research/dual_release_20261011/wrapper/wrapper_protocol_import_manifest_v3.json SHA1bf5999ab78b4efbed6f61fe7f269a06507a5aec6abb1ecdd5e920903b24a79a; qualification SHAb627580e3c9fe66495968f6c3c0e10c54a01eb05aede8bb3ab7c29b17447818f. Independent review found no blocking issue and checked39 manifest pins.

Preserved original generic preflight failure, first native restore fixture failure, missing temporary-model relink failure and corrected recovery. This is finite wrapper protocol qualification using an ideal PLL/framework adapter; it does not establish earned-score persistence, whole gameplay, physical hardware or full video-feature runtime qualification.

One genuine221-field MAME CPU-context reference exited0 and preserved the original input/DIPCE,25 snapshot products,467701 ordered events and actual PCM prefix. It confirms native217 return05AA/A0020706 versus reference05AC/A0020708 around ADDQ.W #2,A0 and a different subsequent stack-save generation. Physical IRQ cause and strict RAM remain open. Evidence: research/dual_release_20261011/kyros_irq_reference/interpretation_manifest.json SHAe192163375b815e0f5332da7471aaac130abd9e0f1de849bc8c8c3b88ae83ac5.

Existing current-board Stingray180 capture actual0 has all five sampled RGB/sprite arrays exact; raw work differs at119/179 and remains unqualified. Evidence: research/dual_release_20261011/stingray/closed180_qualification_v2/import_manifest.json SHA944f57c8331cdfc18dfdc99cfef3cd9e1153dd6215bbcb056cfdcd75cb5cacbe. A single host-only extended1010 firing/hit replay and a single Kyros1853 genuine B04 pickup replay are owned and underway; no terminal success is inferred.

External timing remains open. A source-supported HF1 SDRAM wait candidate is being tested against actual whole-controller pad commands and the -7 chip21ns command requirements before any production change. No timing budget, exception, resource waiver, RBF or hardware qualification is fabricated. Release recipe remains held pending required game and timing results.


## 2026-10-11 dual-release SDRAM candidate review and module scope

Source baseline: `5d4af899f133287ae3ec37989f33e180488a2dac`. Production RTL is unchanged in this phase. User explicitly requests parallel Kyros/Stingray validation followed by their shared release RBF, conditional on confirmation. Japan remains MRA-only.

- Both MRA controls/DIPs and both current six-field wrapper protocol tests passed; evidence remains the dual_release_20261011/mra and wrapper manifests recorded above.
- Isolated HF1 component recipe and strict consumer exited 0, all 12 checks passed. Real HF0 pad tRCD/tRP minima were one 48 MHz cycle (20.833 ns), shorter than the common -7 grade 21 ns requirement; HF1 minima were two cycles (41.667 ns). Complete graphics data and recorded Kyros/Stingray RGB matched. Evidence: local staging research/dual_release_20261011/sdram_hf1_v2/terminal_import_manifest.json SHA bc5c2c21dd4d521b94a11ac95c0724f7625af11cd26ce7dac7816fa42bf57a30; artifact addendum eab34b9b83ca5e8a13ebdf21f75e6ec009c541514b8c302c6934e723f1519627.
- Independent review found the worst Kyros stress line at 3065/3072 cycles uses one fixed refresh phase; a finite worst-phase check remains required before applying HF1. The refresh-window checker also needs 8193 commands to prove 8192 same-row intervals. Physical retention/electrical qualification is not inferred from these component checks.
- User replied that this must support any module and instructed us to disregard the installed-module identification request. Do not wait for an installed chip identity; target conservative standard MiSTer SDRAM compatibility rather than module-specific tuning. This is not evidence that arbitrary electrical paths have been measured.
- Genuine Kyros 1853-field pickup and Stingray 1010-field firing/hit replays remain live; neither is a pass until its actual terminal result and scoped consumer exist. A finite unchanged-source O3/ext4 host benchmark is authorized separately; live jobs remain untouched until exact-prefix equality and measured benefit are reviewed.
- Saved-register evidence supports treating raw interrupt-stack equality as a diagnostic rather than automatically identifying bad CPU writes. The possible MAME pending-interrupt loss remains unconfirmed; no functional MAME or FPGA IRQ phase change is authorized by a hypothesis.

Next: close refresh-phase and wrapper integration checks, evaluate meaningful gameplay/graphics results, preserve accepted internal timing and seven resource caps in an isolated check-only fit, then perform the expressly requested queued release assembly only after applicable gates pass. No release assembly or deployment occurred in this phase.


## 2026-10-11 accepted graphics exceptions and verified B16 reference issue

Production RTL remains unchanged from 5d4af899 in this document phase. Changed files: plan.md, mamebug.md and progress.md.

- User explicitly accepted the additional eight HUD pixels at Kyros field4400. Scoped graphics PASS now records accepted field900 four-pixel and field4400 eight-pixel exceptions. The raw failed comparisons and descriptor-generation evidence remain unchanged; no general pixel waiver exists.
- Added B16 after independent passive-source and actual causal review: eligible IRQ2 pending state is cleared during resumed IRQ1 acknowledgement and recognized again only at IRQ1 RTE. One actual private221 run exited0, preserved39 raw products and qualified1753 records/876 pairs; manifest ec4f1da7c80ff76a2102d1074ad0068072d3ba20c4c28a5dc0a6526df2d7b906. No FPGA IRQ or functional MAME patch.
- HF1 current-wrapper compile and both six-field runs exited0, all eight saved RGB arrays match HF0; source mismatch exactly the HF parameter. Qualification4d8434b5ebe933799a5574acb0571ec3fa4a443299543f509f34cc42a46c06c5; terminal manifest6d9954d07c4074abad627e31677d29e6ac00edcfe58c834ea791fa387e1e1deb. Remaining bounded phase check and isolated fit are live, not terminal passes.
- B04 genuine1853 attempt closed at209 with native/worker/consumer1 after the observer's2,000,001-row hard cap. Retained tail proves counter020000 polling dominates this unrelated diagnostic. Terminal d52db584d42f07a4311cbd9fd3d44fda242f5226f768eb3d20aa8503c7b66c2e; minimal exact-consumer selector proposal8782ae6624feacf2727b7d2243819611c3555a0cfa3c9da010e3d135dfa78cf4 is under independent review. Do not call this a demonstrated gameplay failure or waive missing pickup targets.
- Finite paired host optimization benchmark passed original11 and paired27 exact outputs; hostOs→O3 gives141.526→136.048s (3.87%). Generated model was already effectivelyO3. No live replacement is justified by that modest startup result; no more optimization permutations planned. Manifest b4041bd952438fb5d19fd2ef3c863861cd5d6c18bf93731c16caf80fb959743c.
- Generic preflight audit confirms its packed-ROM SDRAM search ignores local ROM partition and gfx bit0/3 physical permutation;0/1122 does not prove corruption. Its noVS cause remains unresolved and preserved as a tool-limited diagnostic. Do not require a duplicate generic run when the current genuine wrapper's scoped boot/HPS/video evidence passes. Audit manifest83f6d01fbae3f7624b1cfc0be2860b0dcb12156e934220da857407ceed83e515.

Next: complete corrected pickup, original Stingray gameplay, realistic refresh-phase and timing checks; integrate the justified fix and requested queued shared release with qualified MRAs. No RBF or deployment in this phase.


## 2026-10-11 integrated conservative SDRAM command spacing

Source base: fe9a195ce9a991a51cd0eb3d0fb1a55ec55ef2ca. Changed production file: rtl/alpha68kn_gfxmem.sv, sole byte .HF(0)→.HF(1), exact tested SHA9607ecc29d12a7a271c09204fd017ee70daa938ca74aa7ddfa723df5b3076ffb. Updated donormap/progress provenance; no donor/sys/clock changes.

The independently reviewed phase supplement exited0 with16 checks passing: selected critical line3072 phases with cold/eight warm histories,34017 total records, maximum3068/3072 (four cycles spare), no overflow/deadline failures. Corrected8193-command/8192-interval retention checker has4887 complete windows, maximum2798540 cycles58.3029ms<64ms. Terminal manifest2beb16112969fc2d36458881c821c0bcb952f48eafeb4e335ff4b1f2a0d6222d; independent882e4f7685f4c6a5c6cce3d601dc2af4b214486e2deb2c1a369f321d618bc8aa. No concrete uncovered reachable failure blocks this repair; finite selected-line/history scope remains explicit.

Current HF1 wrapper both profiles passed with eight saved RGB arrays exact to HF0; recipe/consumer native0 as previously recorded. Matching isolated Quartus fit has actual0 and is completing its STA/resource receipts; do not transfer previousHF0 slacks or call the new timing gate passed before terminal qualification. Interface pad contracts remain under source-qualified preparation. Corrected pickup retry and original Stingray gameplay consumer remain pending. No assembly/RBF/deployment occurred.


## 2026-10-11 — reviewed video/PAD composite integrated; release gates remain open

Source base: 6c5c2eeef9c8e69a0287542a13ac3ad566082782. Added the core-owned video mixer and five constraints, and redirected the QSF through the pinned framework binding. Original sys/ bytes and HF1 graphics memory remain unchanged. V8 independent source review approved this grouped change for a fresh isolated fit, not timing or release acceptance. Source manifest: local staging research/dual_release_20261011/timing/supported_io_pad_contract_v8/import_manifest.json, SHA c00ce1d8fe58940404fef115a2af1b2612363194c1f0bb8c2de280e54bfcd1da.

The exact canonical framework mixer declared RGB buses inside anonymous generate branches but referenced them outside; Verilator created scalar implicit nets. V66 genuinely rendered 1,176 colored core pixels while VGA was black. The core-owned replacement declares correctly sized shared buses and retains the branch expressions, pipeline and notices. V67 five-field native/worker checks exited 0; field4 core and VGA are byte-exact, including all 1,176 colored pixels, with the original guard and guest epochs unchanged. Terminal8c09f618f72104b1dd223173013938027169e6521673dffc093c8382a630601a; colored qualifier12efa186bd0de8f04077b06034e56f2199fa9496da1eac53e7b299bd3ef90c8b, under kyros/b04_rgb_fix_hf1_v67/. The previous six-field wrapper used a private preprocessing repair (mixer183a46fc...), so its earlier all-canonical-source description is corrected here. Its colored checks were nonvacuous. The full genuine1853 V67 pickup replay is underway; startup is not a pickup/gameplay pass.

V7 native STA exited3 before corners because Quartus17 rejected set_load. V8 removes exactly those three commands and provides 67 explicit BOARD_MODEL_FAR_C receiver caps in farads (SDRAM6e-12, HDMI2e-12), supported for Cyclone V. Existing Near End endpoint is retained. This is a declared component/PAD contract; unmeasured board flight, skew, additional loading and peripheral electrical behavior are not universally qualified. The joined video graph requires a new isolated fit and all eight reannotated corners, operative load evidence, actual serializer/CE edge witnesses, zero unconstrained paths, reviewed warnings and all seven resource caps. The earlier internal HF1 fit is not final composite timing acceptance.

Stingray's genuine1010 replay closed native0 but strict consumer1: RGB/sprites match through360, with later active-RAM/graphics differences. Existing native and reference journals localize the first counter difference to391: native makes one update each108..1009; MAME has no counter update391 and remains one behind. No native duplicate or renderer fault is proven. A bounded passive MAME393 IRQ/HALT discriminator is being prepared; neither a blanket B16 transfer nor frame/RAM masks are permitted. Evidence: stingray/firsthit1010_qualification_v4/import_manifest.json76ad1c66131a8bfa627ae8d1c7674735419e29604a6b80ec64355a47c598a6ae and counter391_causal_scope_v1/import_manifest.json17fd3584cf883c90464f5a3ca4e7ba5c15ef388d9fea6dfb09217117e3cb3dec.

MRAs/controls/DIPs already passed the bounded audit: Kyros Punch/Jump; Super Stingray Main weapon/Sub weapon; Japan retained as an MRA only. Release assembly is explicitly requested but not started. Next: finish the existing pickup replay, resolve the Stingray391 causal classification, qualify the fresh composite fit, then build one queued release RBF and package the three MRAs/credits/licenses. No push or deployment requested.


## 2026-10-11 — user stops development and requests the named RBF/MRAs

The user explicitly ordered all current tasks to end, requested immediate RBF/MRA construction, and specified Arcade-Alpha68kN.rbf. Owned Kyros native/worker/supervisor/observer were stopped and verified closed; all diagnostic, audio, hiscore, timing and framebuffer agents stopped. Partial and failed consumers remain retained. No phase90/FIFO/unvalidated proposal is included.

Integrated only the already validated stable QIP-path correction (ab61be68265b3cd355333c1d39dc3e30658d36d9483daadf84f5c71b6dde086f), which preserves the sys/ source bytes and restores the PLL QIP separator. Changed the exact three MRA rbf tags from Alpha68k_N to Alpha68kN; MiSTer's arcade loader resolves that fragment to Arcade-Alpha68kN.rbf. All remaining ROM, controls, DIP and high-score metadata bytes are unchanged. Kyros Japan remains MRA-only. Core RTL, HF1 and original10416ps SDRAM phase are unchanged.

The requested image is an explicitly requested build, not a timing/gameplay-qualified release. Existing corrected-source MAP/FIT/STA exited0 and all seven resource caps passed; actual SDRAM setup is -3.816ns and unconstrained endpoints/crossing limits remain open. Kyros full pickup was stopped at89fields (native-15/strict1); full Stingray post391 RAM/RGB equality remains unqualified. Synthetic hiscore protocol passes but genuine earned lifecycle is unqualified; finite audio evidence retains its original bounds. These limits are not silently changed into passes by assembly.

Stingray's closed passive393 diagnostic proves local MAME generic on_vblank suppression during HALT: expected IRQ1 at317104127 lies inside deliveredHALT317101607..317105417; surrounding IRQ1 deliveries are two811008periods apart. The responsible generic diexec.cpp551..563 callback guard differs from KyrosB16. Physical PCB IRQ retention and full downstream equality remain outside this finite proof. No native IRQ patch was made.

Next: stage immutable current inputs and reviewed credits/DAT preprocessing, submit one complete job through current QuartusFast and the canonical shared FIFO/two-job queue, retain authentic results, rename the generated artifact Arcade-Alpha68kN.rbf and package the exact MRAs/credits/licenses. No deployment or push requested.

## 2026-10-11 — requested Arcade-Alpha68kN engineering artifact complete

The user ended further development and explicitly requested the current RBF/MRAs. Exactly one full QuartusFast `build --mode release --allow-rbf` job ran through the shared canonical FIFO, with no queue override, build retry, deployment or push. Frozen compiled source: `f3bfc23c0eb968e1309e3316810535ebeb993687`; private313 canonical/316 build inputs, reviewed DAT credits filename substitution and vendor micro/nano ROM copies. Original source/sys bytes remained unchanged.

Actual outcomes: map/fit/assembler completed successfully; native full compilation exit3, frontend exit1, TimeQuest failed. **This artifact is unqualified; it is not a timing-closed release.** Native slack minima observed in the compiler log: setup -8.306ns, hold -6.221ns, recovery 3.392ns, removal 0.329ns, minimum pulse width 1.041ns. Exact TimeQuest errors, remaining unconstrained notices, current resource-report lines and acceptance=false are retained in `D:\Arcade\AI\aCORES\Alpha68k N\research\requested_Arcade_Alpha68kN_20261011\final_verification.json`. No compiler gate was relabelled as passed.

Requested RBF: `D:\Arcade\AI\aCORES\Alpha68k N\research\requested_Arcade_Alpha68kN_20261011\package\_Arcade\cores\Arcade-Alpha68kN.rbf`, 3659432bytes, SHA256 `3aef6a2dfe1b25436bc9378281595d420fc7cbfec1302fbba81fc1d9075d534e`. Renamed artifact is byte-identical to the one freshly generated in this job's private native workspace. Exact3 current MRAs reference fragment `Alpha68kN`; Kyros and Super Stingray control/ROM/DIP/HS metadata are preserved. Kyros Japan remains MRA-only. Package includes credits/notices/provenance and an engineering-artifact guide, no ROMs. Package verification exit0, 25 pinned files. Package manifest SHA256 `f99facb75d2aee02d9cf9dd2c882f82812e04ed50652f84620386f3a458337ee`. Existing gameplay/audio/earned-score qualification gaps remain recorded; no hardware qualification is claimed. Further development/build tasks stopped after packaging.


## 2026-10-11 — requested credits overlay 90-degree counterclockwise rotation

Source base `023bcce2e8ea21b8ba11f71d243f28ea21fc4289`. Added parameterized inverse-coordinate rotation to the credits overlay and enabled it only in this core. Panel, ornaments, letters and scrolling use a 224x256 logical canvas in the native256x224 raster; full contributor text is regenerated at34columns to fit. Video sync/latency, game raster and MiSTer rotation settings are preserved. Actual Icarus rendered comparison:57344pixels, zero differences versus exact90degree CCW rotation of the same unrotated logical canvas. Evidence `D:\Arcade\AI\aCORES\Alpha68k N\research\credits_ccw_20261011`. User explicitly requested a rebuilt Arcade-Alpha68kN.rbf; next one isolated queued full build using reviewed preprocessing. Prior timing failures remain unresolved and are not claimed passed.


### 2026-10-11 — rebuild held by user

The user instructed not to build a new RBF yet after the credits CCW change passed the 57344-pixel rendered rotation comparison. No Quartus submission, compile or assembly was started for this change. Rotation source commit c3e48cbd7676a5ea24399ce59e7614eb18824b61 is retained; rebuild requires a new explicit user request.


## 2026-10-11 — portrait credits layout refinement; RBF hold retained

Base `a750c39437bcd323ef83d07fce2aea15cb9eb27c`. Portrait224x256 credits now use32columns, one centered contributor column and an208pixel card with8pixel outer margins. Names wrap without truncation, preserving the complete credits source SHA256 `2918a1f11228ac305b4fff6c29762decdbaca0c6c79f6e7a4bd3788f689eccc8`. Opening title starts below the top fade rather than in the middle; title/subtitle, tier colors/underlines, ornaments and scrolling are retained. Actual Icarus render:57344pixels, zero differences against exact90degree CCW reference. Preview and receipt: `D:\Arcade\AI\aCORES\Alpha68k N\research\credits_portrait_layout_20261011`. No Quartus submission/RBF assembly was started; the user rebuild hold remains active.


## 2026-10-12 — reported Kyros overlaps and Stingray startup pan

Completed the reported sprite-priority investigation at source `d1c82c9b2ad4cdcb7994ce5e8b37651c65375633`. Changed `mamebug.md` and this progress record only. The user's supplied Kyros PCB stills establish normal door/wall and barrel overlap for the pictured interactions; preserve the renderer's priority order.

Owned vanilla MAME0.289 startup run completed600 fields, actual exit0, coin/start only,450 full RGB/RAM captures. Eight current-source actual renderer/palette/SDRAM fixtures match MAME at every57,344 pixel after the independently identified one-field callback capture phase is aligned. Every fixture has zero deadline misses/row overflows; worst line1609 master cycles against3072 available. Original unaligned native exits1 and their full mismatch counts remain retained. These are finite renderer checks, not full-core gameplay/hardware acceptance. Stingray's general startup bottom-edge pattern is present in MAME; direct PCB confirmation remains open. No matching confirmed online bug report was found.

Evidence: `D:/Arcade/AI/aCORES/Alpha68k N/research/sprite_repair_20261011/findings.json`, `startup_rtl_comparison.json`, `mame_startup/process.json`, `mame_startup/terminal.json`, and `stingray_startup_contact.png`. No sprite RTL, clocks, constraints or ROM changes; existing release timing/acceptance limits remain unchanged. No RBF rebuild is authorized or started. Next action for this phase: locally commit the records and push the completed branch as explicitly requested.
