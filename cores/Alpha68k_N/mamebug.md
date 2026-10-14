# MAME bugs and fidelity risks: Alpha68k N

Research date: 9 October 2026, Australia/Sydney. Scope: `kyros`, `kyrosj`, `sstingry`; baseline: the supplied MAME 0.289 driver. Its text matches upstream `mame0289` after CRLF normalization. Historical reports often name `alpha68k.c` or `alpha/alpha68k.cpp`; the applicable current file is `src/mame/alpha/alpha68k_n.cpp`.

This catalogue distinguishes fixed emulation defects, original-game behavior and unresolved modeling limits. Searches covered MAME Testers, MAME release notes, current and former driver commit histories, GitHub, the MAME timing wiki, board research, MiSTer donors and Jotego's public Patreon material. Five applicable formal MAME Testers reports were found. This is a documented search result, not a guarantee that every unindexed/private report has been discovered.

Evidence is retained in `research/online/`, with URLs/hashes in `research/online_manifest.json`; relevant commit JSON is named `commit_<full-sha>.json`. Source hashes and local recovery paths are in `research/source_manifest.json`. ROM definitions and CRC/SHA1 results are in `research/rom_manifest.json`. Some web-tool fetches failed, but direct bounded retrieval saved all five Testers reports. The old raw-tag whatsnew URLs for 0.138u3 and 0.164 returned 404; the Testers records themselves establish their fix versions. Public Patreon text was readable through web search; its direct archive request returned 403.

## Issue register and action

| ID | Sets | Evidence/type | Status at baseline | Core action and plan phase |
|---|---|---|---|---|
| B01 | Kyros, Japan | MT01148: stage 5 sprites/blocks | Fixed in 0.281 | Preserve the corrected color handling; qualified finite stage-5 fixtures in P4/P7 |
| B02 | Kyros | MT01149: ending characters cover text | Original behavior, closed BTANB | Preserve priority; qualified finite ending fixture in P7 |
| B03 | Kyros, Japan | MT03912: persistent punch noise | Fixed in 0.138u3 | Correct PSG/DAC/latch state and acknowledge behavior; P5/P7 |
| B04 | Kyros, Japan; Stingray implicated in note | MT05959: missing effects | Fixed in 0.164 | Z80 IRQ once per vblank, distinct 4 kHz NMI; P3/P5/P7 |
| B05 | All three | MT02099: clipped mixed audio | Fixed by 2021 commit | Wide signed mixer, calibrated levels, no arithmetic wrap; P5/P7 |
| B06 | All three | Wrong sound chips/clocks in older drivers | Corrected in 0.242-era changes | One YM2203 plus two AY-3-8910, actual per-set clocks; P2/P5 |
| B07 | Stingray | MCU communication and coin DIP defects | Fixed in 2019 | Correct HALT/IRQ/shared-RAM handshake and Stingray DIP mapping; P6 |
| B08 | Stingray | Incorrect colors with old PROM dumps | Fixed in 0.88u7 | Use audited 0.289 PROMs and exact CLUT; P4/P6 |
| B09 | Kyros, Japan | Original MCU underdump and HLE | Still a fidelity limitation | Separate raw bootleg dump from overlapping MAME region; explicit compatibility strategy; P1/P3 |
| B10 | Stingray | MCU clock/timer speed | Still `MACHINE_IMPERFECT_TIMING` | Match 0.289 first, isolate clock parameter; PCB correction requires evidence; P6/P9 |
| B11 | Stingray; shared renderer | Horizontal wrap and transparency TODOs | Unresolved source doubts | Match current formulas first; focused boundary fixtures; P4/P6 |
| B12 | All three | Raw raster versus older approximate board notes | Research uncertainty | Use current raw raster for simulation; preserve physical timing uncertainty; P1/P2/P9 |
| B13 | All three | Ignored sound-board I/O / DAC analog identity | Source modeling limits | Trace accessed ports and implement documented digital behavior; P5/P9 |
| B14 | Kyros | Sound SRAM capacity/mirroring | Unconfirmed PCB/model discrepancy | 2 x 2114 imply 1 KiB; MAME maps 2 KiB. Inspect usage before claiming a correction; P1/P3 |
| B15 | All three | Watchdog byte is modeled as RAM | Incomplete documented board behavior | Preserve byte lanes; determine reset semantics only from evidence; P3/P7 |
| B16 | Kyros observed; shared M68000 reference | Eligible higher IRQ deferred by vector-lookup pending-state clear | Locally reproduced against 0.289 source; no upstream report ID | Preserve correct FPGA nesting; classify reference stack-generation differences without copying the emulator defect |

## Current verification disposition — 2026-10-11

The current canonical source checkpoint is `6caf` (full source/evidence bindings remain in `progress.md`). The frozen B01/B02 target audit qualifies fifteen complete RGB fixtures: five nonvacuous stage-5 late-room fields for each Kyros set, plus five Kyros ending fields. Each set's CLUT255 suppression probe changes500 pixels. This completes the required finite late-scene graphics regressions; natural CPU progression to stage5 or the ending is not an added acceptance gate. Real RTL attract/gameplay and final affected-source binding remain required.

B04 ordinary pickup remains unqualified; jump/hit and ordered sound events do not substitute for its semantic effect. Audio acceptance uses measured per-profile rates, mix, clipping and reset/effect behavior, not phase-identical MAME/JT PCM. B16 retains the timed18-pixel residual and unresolved CPU/IRQ/bus phase relationship. Japan's raw8-byte endpoint difference is explained as retired stack; this does not resolve its control/timing relationship or rewrite the historical strict RAM failure. Stingray's12-byte RAM difference remains unresolved. Its finite native181 credit/start and displayed-frame evidence do not qualify a complete181/1800 attract/gameplay lifecycle.

All seven complete-design resource limits and every required timed corner must remain source-bound. Internal timing or diagnostic SDC evidence does not qualify external I/O/CDC hardware bounds. No RBF, hardware readiness or all-game acceptance is claimed. Exact audit/recovery handles: `research/current_bug_gate_audit_20261011/import_manifest.json` (b998485f…), `research/kyros_graphics_target_scope_v1` primary04949aa1… / supplement8b06f900…. Historical failures below remain dated evidence.

## B01 — stage 5 graphics, MT01148

Finite regression coverage,2026-10-10: guarded ROM-derived scene5/room9
fixtures now qualify both Kyros ROM sets. Five complete actual RTL-rendered
fields per set match MAME0.289 exactly. Suppressing CLUT255 through separate
RAM-only fault fixtures changes500 pixels at1500 in each set, demonstrating
visible sensitivity to the old color predicate. Source pins, complete RGB
and expected negative-test failures are retained in
`research/kyros_candidate5_lastroom_renderer_verification.json`, its Japan
counterpart and both `*_color_ff_suppression_001500.json` receipts. See
`docs/LATE_SCENE_FIXTURES.md` and `docs/bug_coverage.json` for guards, failed
earlier probes and scope. Real RTL CPU attract/gameplay acceptance remains
separate; natural late-stage progression is not an additional required gate.
Unavailable report attachments remain an explicit research limit.

[MAME Testers 01148](https://mametesters.org/view.php?id=1148) reports faulty flashing head/lamp graphics and opaque grey blocks in stage 5. It was verified against original-board video and fixed in **0.281**, commit [d7d8318ad10e14e95465801e978b7be70f594f22](https://github.com/mamedev/mame/commit/d7d8318ad10e14e95465801e978b7be70f594f22). [Official 0.281 release notes](https://www.mamedev.org/?p=555) list the fix.

The fix changes the color rejection predicate to `color != 0xff || !m_is_super_stingray`. Kyros must render a CLUT value of `0xff`; treating it as an invisible tile creates the stage-5 defect. Pen zero remains transparent within a tile, and the sentinel tile checks remain separate. Implement the 8-bit indirect lookup as it exists in 0.289, rather than applying a generic SNK sprite transparency rule. Exit evidence: a synchronized stage-5 raw frame with the lamp and grey-block region matching MAME 0.289 for both Kyros sets.

Historical entry probe, superseded by the late-room/ending fixtures above:
the guarded MAME selector5 corridor fixture matched five complete fields in all
57344 pixels (`kyros_candidate5_entry_renderer_verification.json`), but its four
clipped color-ff tiles changed zero visible pixels when suppressed at1500.
That zero-visible-pixel negative result did not qualify the reported lamp/block
regression. Retain it as a failed coverage probe; the later nonvacuous receipts
qualify both Kyros sets and the ending. See `docs/LATE_SCENE_FIXTURES.md`.

## B02 — ending priority is original behavior, MT01149

[MAME Testers 01149](https://mametesters.org/view.php?id=1149&nbn=1) was resolved on 4 September 2025 as **Bugs That Aren't Bugs**, with original-board verification. The ending characters covering text should not receive a speculative priority correction. Keep N-board strip order `(2,0x800)`, `(3,0xc00)`, `(1,0x400)` and preserve later-pixel overwrite behavior. One ending-scene fixture is needed because attract frames cannot exercise this scene.

Finite ending coverage,2026-10-10: the guarded final-boss state fixture
executes the actual ROM staff-roll dispatcher without an additional PC
redirect. Actual2400/3600 images show characters covering staff text. The
unchanged real RTL renderer matches every57344-pixel field at
2400/3000/3600/4200/5399, preserving the above priority without masks or an
RTL change. See `research/kyros_ending_renderer_verification.json`,
`research/kyros_ending_fixture_profile.json` and `docs/LATE_SCENE_FIXTURES.md`.
This qualifies the finite ending rendering/reference requirement. Natural RTL
CPU progression to the ending remains unproven and is not an added plan gate;
real CPU attract/gameplay and the complete all-game audit remain required.

## B03 — persistent punch noise, MT03912

[MAME Testers 03912](https://mametesters.org/view.php?id=3912) records a regression introduced in 0.129u4 during sound device conversion and fixed in **0.138u3**. After punching, a noise remained active. Avoid stale register selection, dropped Z80 writes, latch-clear errors and retained DAC values across resets. These are implementation checks, not assertions that the MAME bug had all those causes. A short action replay covering punch, release, death and reset should prove the noise terminates and audio state resets correctly.

Completed finite B03 case,2026-10-10: the replacement1081-field actual
MAME/RTL CPU replay finished with native exit0. The real pulse711–724,
released controls725–1080 and main0x3535 sound command are nonvacuous.
All2750 ordered sound writes match globally: AY1=480, AY2=452,
YM2203=1818. Per-chip port/register-data sequences and field labels also
match exactly. AY2-B noise starts at715 (mixerEF, volume2) and cleans up
at733 (mixerFF, volume0). All13 cleanup-composition checks pass, including
unchanged source/executable pins and the same production chip output
contract, which separately qualifies cleanup silence and warm reset.

This proves single_punch_cleanup_composition_pass only.
full_B03_acceptance and whole_game_acceptance remain false for this dated
producer scope. Final-source death/reset and semantic effect coverage remain
required. The current contract uses measured rates/mix and clipping/reset
behavior; phase-identical MAME/JT PCM is not an additional gate. Later AY2-B tone
activity is legitimate; no blanket tail-silence requirement is imposed.
The native full-image postcheck retains exit1: all five metrics pass and
all23 reference images are available, but atomic field60 differs20835 pixels
and field900 differs4. The sound postcheck exits0. Do not turn that graphics
failure into broad acceptance. The early601-field attempt remains a
non-activating setup with native exit-15, not an effect pass.

Evidence: research/kyros_punch_release1081_native_exit.json,
research/kyros_punch_release1081_native_noise_cleanup.json,
research/kyros_punch_release1081_native_verification.json,
research/kyros_punch_release1081_native_sound_interleaving.json,
research/kyros_punch_release1081_native_check0_exit.json,
research/kyros_punch_release1081_native_check1_exit.json,
research/kyros_punch_noise_chip_contract_exit.json and the preserved601
receipts. Completed captures/terminal receipts retain their original former
working-folder source paths through local staging.
## B04 — missing sound effects, MT05959

[MAME Testers 05959](https://mametesters.org/view.php?id=5959&nbn=3) lists missing punch swing/hit, jump and pickup effects. Regression: **0.144u2**; official fix: **0.164**. The report's repair replaces twice-per-second-frame periodic Z80 IRQ generation with the screen vblank IRQ. Its note suggests the same correction for Super Stingray.

Current 0.289 uses sound IRQ0 at vblank plus a separate **4000 Hz NMI**. Implement distinct pending/acknowledgement logic and do not substitute a `2*60` periodic sound IRQ. Preserve the main CPU's separate interrupt sources; this fix is specifically about the audio CPU. The action replay for B03 also covers these effects, avoiding a second redundant recording.

## B05 — mixed audio clipping, MT02099

[MAME Testers 02099](https://mametesters.org/view.php?id=2099) explicitly lists Kyros, Japan and Stingray in its clipping data. [d30361b7f003aff1fca171cac83cd9584fae03f1](https://github.com/mamedev/mame/commit/d30361b7f003aff1fca171cac83cd9584fae03f1), dated 27 August 2021, lowers Alpha68k N route gains.

Use the **final 0.289** route balance, not the intermediate historical chip definitions: Kyros YM / AY1 / AY2 / DAC = **0.30 / 0.30 / 0.60 / 0.50**; Stingray = **0.30 / 0.30 / 0.45 / 0.50**. These are MAME route gains, not directly transferable integer multipliers for JT outputs of different widths. Calibrate FM/SSG/PSG scaling, sum in a wide signed accumulator, and saturate once at the output. Record clipping counts in the shared sound replay. Exact PCM identity is not an acceptance claim; register timing, tone rates, effect coverage and relative levels are.

## B06 — older sound hardware descriptions are wrong

[4536b6fbb7d3](https://github.com/mamedev/mame/commit/4536b6fbb7d3) and [PR 9382](https://github.com/mamedev/mame/pull/9382), documented in [MAME's 0.242-era notes](https://www.mamedev.org/?p=511), correct Stingray audio clocks and replace the second and third YM2203s with **AY-3-8910** devices. [102be5fb56385308a4fe3f322fadf2165d154451 / PR 9423](https://github.com/mamedev/mame/commit/102be5fb56385308a4fe3f322fadf2165d154451) supplies original Kyros board clock documentation.

Kyros: 68000 6 MHz; Z80 4 MHz from 16 MHz / 4; YM2203 and both AYs 2 MHz. Stingray's current MAME model: 68000 6 MHz; Z80 3,579,545 Hz; YM and both AYs 2 MHz. Original Kyros measurements are stronger evidence than old generic game databases. Do not borrow the TripleZ80 donor's YM3526 arrangement for this sound PCB. Configure AY behavior rather than blindly using YM2149 volume and clock assumptions.

## B07 — Stingray MCU handshake and coinage

[12cc55a5e8a69d6422ad392ea5a5a30908b74630](https://github.com/mamedev/mame/commit/12cc55a5e8a69d6422ad392ea5a5a30908b74630), 27 September 2019, fixes both MCU communications and coinage DIP settings. [MAME 0.215 notes](https://www.mamedev.org/releases/whatsnew_0215.txt) describe replacing protection simulation with MCU execution.

The 8748 interface must latch address/data/read mode; assert MCU IRQ and main HALT for either operation when control bit 4 enables it; clear both when bit 4 is released; issue 68000 IRQ2 from bit 5; update the shared RAM low byte when bit 6 is low; derive native flip from inverted bit 7. Do not clear HALT merely because RAM was written. Stingray's coin DIP encoding differs from Kyros's. Test both coin slots, multi-coin ratios and one simultaneous command/IRQ case in the gameplay capture.

## B08 — Stingray PROM colors

[MAME 0.88u7 release history](https://wiki.mamedev.org/index.php/MAME_0.88u7) credits the correction to new PROMs. Current files include `ic93` CRC `9af8a375`, `ic92` CRC `e7ce1179`, `ic91` CRC `c3965079`, and CLUT PROMs `ssprom1.bin` / `ssprom2.bin`. Exact load order and every SHA1 are in the ROM manifest. Audit passed for all eighteen Stingray files. Use the N board's PROM palette routine, not the later Alpha68k RAM-palette device or an unverified hardcoded color table.

## B09 — Kyros MCU is not fully modeled by MAME

The 0.289 driver still uses `kyros_alpha_trigger_r` / `alpha_microcontroller_w` high-level behavior and a periodic 60 Hz main IRQ2. The bootleg `kyros_68705u3.bin` is a full 4 KiB dump, CRC `c20880b7`. PCB notes say it was programmed into a genuine MC68705U3 and worked on an original Kyros board. The original `kyros_mcu.bin` is only 2 KiB, CRC `3a902a19`, marked **BAD_DUMP**, with zero-page ROM missing. See [28192a5a65e6bc9d143ab8ccb64589e414847a94](https://github.com/mamedev/mame/commit/28192a5a65e6bc9d143ab8ccb64589e414847a94) and the supplied driver's PCB notes.

Both declarations occupy the same MAME region, and the partial original dump overwrites part of the loaded bootleg image. **Do not execute `roms/kyros/mcu.bin` as if it were a clean bootleg ROM.** Staging retains each original file separately under `roms/<set>/mcu_dumps/`. Use the raw full dump for a real MCU experiment.

Fast path: an explicit MAME compatibility MCU FSM for Kyros, covering all observed transactions and coinage. Hardware path: staged jt6805 plus a correctly adapted U3 peripheral wrapper. Generic P5/R3 wrappers are donors, not drop-in 8511 identities. Select firmware execution as default only after a bounded command/IRQ/gameplay comparison establishes equivalence or documents an evidence-supported improvement. Do not describe compatibility HLE as cycle-exact original MCU hardware.

## B10 — Stingray timer remains uncertain

The [MAME imperfect-timing register](https://wiki.mamedev.org/index.php/MIT) and the driver TODO both say the MCU controls timer speed and its clock is likely wrong. MAME configures **I8748 at 9,263,750 Hz**, divided internally by **3*5**. `sstingry` retains `MACHINE_IMPERFECT_TIMING`.

Implement the actual staged 1 KiB `d8748.bin` firmware with T48 and reproduce this MAME clock initially. Audit internal divider semantics so the factor fifteen is applied once. Keep a named per-set clock parameter and count MCU-driven IRQ2/game timer events. A correction to PCB timing needs measurements for Stingray itself. The Alpha68k donor's Gang Wars MCU interrupt observations concern another board and cannot establish Stingray's rate. If no board evidence becomes available, report the unresolved physical-fidelity limitation while still proving MAME compatibility; do not silently invent a speed.

## B11–B15 — source doubts and board limits

- **B11:** `draw_sprites` questions the Stingray `mx > 0xf8` signed-X wrap and whether sentinel tile suppression should use a transparency mask. Match 0.289's current `0x40` sentinel and pen-zero behavior, then preserve small boundary/overlap fixtures. Any board-based alternate behavior must be isolated and compared without changing Kyros's B01 fix.
- **B12:** The shared raw raster is 6 MHz, 384 clocks per line, 264 lines, visible X 0–255 and Y 16–239, approximately 59.185606 Hz. Early Kyros PCB notes round VSync to 60 Hz and give HSync 15.20 kHz. Treat those notes as a research discrepancy, not authority to emit a 256-line raster. Simulation uses the explicit raw model; final CRT qualification checks the physical output.
- **B13:** Kyros sound writes at `0xe006..0xe00e` are ignored in MAME, although comments associate them with NMI/RST routines. Stingray's DAC type is described as unknown. Record these writes and preserve the modeled digital DAC; an analog filter or clock correction requires component/schematic evidence. YM3014 / LM324 / amplifier support is a digital mixing task, not an invented CPU donor.
- **B14:** Kyros PCB notes identify two 2114 chips as 1 KiB x 4 each, implying 1 KiB x 8 together. MAME allocates a 2 KiB sound RAM window. A missing alias is a hypothesis; check accessed addresses and wiring before altering the map. CPU compatibility initially follows MAME's allocation.
- **B15:** `0x060000..0x060001` is RAM, with MSB documented as watchdog and LSB as background color. There is no watchdog device wired by the N configuration. Preserve write strobes and background behavior; leave original watchdog period/reset wiring explicitly unqualified until measured.

Jongbou's graphics overflow TODO, Gold Medalist timer/palette problems, later Alpha68k RAM-palette shadows, later shared sprite-device savestate changes and Gang Wars MCU clock measurements are excluded unless a specific shared dependency is shown to affect these target games. Generic host-video/backend crashes are not PCB logic defects.

## Minimal regression obligations

Finite B13/B14 usage audit,2026-10-10: the existing complete3600-field real
MAME combat capture writes lowerc000..c3ff2325198 times,1991777 nonzero.
Upperc400..c7ff has exactly one zero write per address and no nonzero writes.
All five documented ignored I/O ports are active. Preserve0.289's2KiB/nopw
baseline; write usage and differing virtual alias values do not prove sound
reads, physical capacity/alias wiring or analog behavior. Exact hashes/counts
and limits: `research/kyros_sound_address_usage3600.json` and
`docs/SOUND_ADDRESS_USAGE.md`. No new capture or native/core correction was
needed for this finite disposition evidence.

Use one deterministic action replay per game profile to cover coin/start, movement, both actions, pickup/explosion, death/reset, sound clear, cabinet/flip, and DIP interpretation. Add only the stage-5 and ending fixtures missing from those runs. Sample the first mismatch, rather than generating endless logs. Full-core boot and gameplay must run real CPU RTL. Every issue above is routed to a phase in `plan.md`; historical fixes are invariants to retain, not patches to reapply blindly.


## B16 — field900 late sprite-word update versus final-frame image

**Classification:** newly measured source-model/capture fidelity limit, not a MAME Testers report or a confirmed physical PCB fault. Kyros gameplay field900 has four native pixels differing from the final MAME image. A fresh read-only trace changes word0x40EEA from20 to21 on raster line52, after that tile's visible lines24–31. The isolated actual RTL rendering of final RAM matches MAME; substituting only the measured pre-write word matches all57344 pixels of the unmodified live RTL capture. See `docs/FRAME900_DIAGNOSIS.md` and its pinned evidence.

**Core handling / plan gate:** preserve real raster timing and live RAM semantics while investigating corresponding scanline-time state. Verify native CPU write timing and RAM with counters matched against the full-system run. Keep the original atomic-image mismatch visible; do not declare it fixed by masks, frame shifts or fabricated CPU behavior. No verified physical latch behavior is inferred. P4/P7 must report final-state renderer agreement separately from live scanline agreement before any whole-game graphics claim. Relevant source: [MAME0.289 Alpha68k N screen_update](https://github.com/mamedev/mame/blob/mame0289/src/mame/alpha/alpha68k_n.cpp#L202).


**B16 native confirmation:** the real-CPU diagnostic completes901 fields with all main counters equal to the full-system replay and all8192 sprite-RAM bytes equal to MAME at900. Native and MAME both update the word on raster52 (X311 versus313). The tile's visible lines24–31 precede both writes. Evidence: `research/kyros_frame900_native_timing.json`. The temporal cause is confirmed; the original four-pixel atomic-image mismatch and two differing work-RAM words remain explicitly recorded. No whole-game or physical-latch pass follows.


**B13 integration note (2026-10-09):** MAME0.289's YMFM SSG positive amplitude table must not inherit the standalone AY legacy bias. The core's mixer error was corrected and tested against that source range; quiet means now agree within one sample unit. This is an integration correction, not a newly asserted MAME bug. See `docs/AUDIO_NORMALIZATION.md`. Per-chip late music calibration and physical analog limits remain open, so B13 is not declared fully closed.

### P5 per-device SSG evidence — 2026-10-09

For B13, the supported sound observer now records reference source moments
without changing CPU states or the mixed WAV. It isolated the level defect to
donor SSG compression/fixed-volume indexing. Classify this as a core integration
defect. Project bank5 uses the actual MAME0.289 YMFM table; corrected replay completed
1,800 fields. Finite SSG level errors are+0.44%/-1.84%/-0.56%, with active output
and zero PCM rail samples. Combined waveform residuals remain unqualified. The first silent import failed the activity guard and is preserved.
B03/B04/B05/B06 action coverage, death/game-over/reset and physical audio are
not closed. See docs/YM_SSG_CURVE.md and research/audio_component_comparison.json.

### B16 follow-up: backdrop and POST timing (2026-10-10)
Field60 changes backdrop mid-field: actual native write99,97; MAME81,97; both64->80. Native ROM/write reconstruction matches57344 pixels, while MAME atomic image differs20835 and the timed MAME reconstruction differs18. Field360 retains2104 atomic pixel differences with identical final sprite RAM. Do not reclassify either as a broad graphics pass. Accepted-write/phase details, invalid observer attempts and verified reference-audio recovery are in docs/RASTER_TIMING_DIAGNOSIS.md. Horizontal CPU/bus phase and full dynamic renderer replay remain open.

### Audio coverage follow-up from native combat (2026-10-10)

B03/B04 remain subject to actual native audio evidence. The finite combat
comparison preserves an ordered22,418-write chip-I/O failure at index896,
field787 (MAME16/1, RTL145/6), despite equal counts. Main latch157 and DAC42,246
write sequences match. This is an observed RTL/MAME divergence requiring cause
diagnosis, not a newly established upstream MAME bug. Death3601 chip/latch
sequences match, with no DAC capture. See docs/LONG_GAMEPLAY_EVIDENCE.md and
research/kyros_combat3600_native_sound_comparison.json. Do not infer all-effects,
PCM or physical-board accuracy from these finite checks.

### 2026-10-10 - Combat sound chip projection

Parent60018db. All finite within-chip port and decoded register sequences match: YM2203 10,404 / AY1 3,142 / AY2 8,872. Global interleaving comparison remains failed; YM2203 has seven field-label differences. Source map/hash, complete evidence and diagnostic scope are in docs/LONG_GAMEPLAY_EVIDENCE.md and research/kyros_combat3600_sound_interleaving.json. This narrows the next audio diagnosis to inter-chip scheduling/write phase and PCM, without relaxing B03/B04 or changing clocks. Canonical graphics failures/missing checkpoints remain open.

### 2026-10-10 - B16 field360 actual timed renderer proof

Parent2d326a5. Actual10,453 accepted sprite writes reconstruct final360 RAM exactly; recorded reset/master phase predicts every raster coordinate. Actual renderer replay through30 full fields matches every57,344 native360 pixel; exit0,7,920 completed lines, worst2,280 ticks,0 deadline/overflow. Canonical atomic MAME360 still differs2,104 pixels and is not waived. First exact-image run exited1 on an inherited225-line static guard; preserved it and corrected only the full-raster count264*30. Fixed target background64 and isolated SDRAM refresh/controller-state limits are explicit in docs/RESET360_TIMED_RENDERER.md. Complete evidence in research/kyros_reset360_timed_renderer_verification.json. Next use fresh MAME hpos write history and primary CPU/write-phase evidence; no DUT clock/RTL/ROM changes or Quartus/RBF execution.

### 2026-10-10 - B16 MAME-timed field360 and executed backdrop instruction

Parentfb5f1c8. Fresh361-field exact-clock MAME observer reproduces all361 states,741,506 old events and15 canonical images. CURPC identifies field60 backdrop MOVE.B at0x1AE34 (13FC005000060001); native bus phase remains open. MAME10,455 timed sprite writes reconstruct identical start/end RAM and, through the exact qualified real-renderer ELF, match all57,344 native360 pixels, just as native10,453-write replay does. Exit0,7,920 lines,0 deadline/overflow. Atomic MAME360 difference2,104 is retained; finite time-aware field360 agreement is proven under documented projection/background/controller limits, not all-game or physical timing. See docs/MAME_CLOCKED_RESET_EVIDENCE.md and research/kyros_reset360_mame_timed_renderer_verification.json. Next native instruction/bus-phase trace for backdrop60, then time-aware combat/field900 coverage.

### 2026-10-10 - B16 IRQ context upstream of backdrop

Parent831dfcf. Four actual IRQ stack/vector contexts qualify field60 savedPC/SR/stack equivalence; field59 savedPC854 versus858 is retained (diagnostic exit1). Both vector streams occupy80-master-tick grids, corroborated by10-CPU-clock VPA/E synchronization in primary sources. Local frame pacing differs -8/-8/+56/-8 ticks. No physical phase/root-cause or supported clock/IRQ fix is claimed. See docs/IRQ_TIMING_CONTEXT.md and full context/source-grid receipts. Backdrop18 timed pixels remain open. Continue other required bug/graphics coverage, addressing simulator throughput for efficient later-stage execution.
### 2026-10-10 — B16 combat HUD temporal evidence

Six retained real CPU combat fields have small HUD atomic-image differences.
The exact-clock MAME observer preserves all original3600 states/66RGB/fullWAV
and8,085,201event rows. Measured changed writes to0x40EEA..0x40EF0 occur after
the affected raster rows. Using only independently recorded earlier words,
the current actual renderer reproduces all57344 native CPU pixels exactly
in all six cases, with no masks/shifts or RTL clock changes. See
`docs/COMBAT_HUD_DIAGNOSIS.md`, `combat_hud_mame_timing_v2.json` and
`combat_hud_prewrite_fixtures_verification.json`. This is finite temporal
pixel proof; the new actual native3301-field accepted-write/RAM audit is still
running. Atomic failures remain recorded; field60 phase residual remains open.
### 2026-10-10 — B16 actual native write/RAM causality at900/1020

Both completed actual CPU cases pass known-byte write reconstruction, matching
MAME earlier words, changed writes after affected rows, identical complete
sprite RAM and full-RGB equivalence to the current real renderer's measured
pre-update fixtures. See `combat_hud_native_causality_through1020.json` and
`docs/COMBAT_HUD_DIAGNOSIS.md`. This closes finite temporal causality for
these two cases; four cases and full live-run qualification remain pending.
The original atomic-image differences stay recorded. Manufacturer E phase
is unspecified at power-up; that fact does not close the field60 residual
or establish an RTL frequency/reset bug. No phase-fitting patch was made.
### 2026-10-10 — B16 native causal proof extended through2220

Cumulative accepted-write/RAM/full-RGB checks pass at900/1020/2100/2220
in the same real CPU run. Every relevant change occurs after affected rows
and agrees with the independently measured earlier MAME values; complete
sprite RAMs match MAME. See `combat_hud_native_causality_through2220.json`.
Last two cases3180/3300 and terminal qualification remain pending. Atomic
failures,1799's work-byte difference and field60 residual are retained.

## Supplemental actual-CPU coverage — 2026-10-10

B16 remains open. The qualified field59 IRQ/write-order join passes8 finite checks
and independent review passes20, with matching10606-write capture scopes. Two
MOVE.W #$20,(A0)+ writes relocate across interrupt handling; savedPC/A0 and96-tick
relative offset growth corroborate the ordering difference. This is neither a
physical timing diagnosis nor a correction; the18-pixel time-aware residual and
canonical atomic failures remain recorded. See docs/IRQ_TIMING_CONTEXT.md and
research/irq_deferred_tile_write_review.json.

B01/B02 renderer fixtures remain exact but do not prove natural CPU progression.
All130 retained combat snapshots stay in scene3 after startup; none show stage5
or ending dispatch. See research/kyros_late_game_acceptance_gap.json. The next
required step is a control-only successful MAME route, then its real RTL CPU replay;
state writes, cheats and synthetic progression cannot close these requirements.

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

## Donor implementation finding — embedded SSG period zero (2026-10-10)

Category: donor implementation discrepancy relevant to P5/B03-B06 audio
qualification. Pinned JT03's embedded jt49 divider forces period-zero tone low.
Actual isolated baseline run exits 1; the private correction exits 0 and the
21-check qualifier proves periods 0/1/37 at the nominal clock enables. Pinned
local MAME YMFM models zero as one. Preserve the donor GPL notice and apply
the recorded minimal correction when integrating the next qualified image.

Exact known-register windows of the retained 1800-field trace and current
1127-field prefix contain no active period-zero tone. Startup uncertainty,
other inputs/sets and envelope amplitude remain explicit. This finite finding
does not close broad audio bugs. Evidence: research/ym2203_ssg_pitch_stage/
qualification.json and research/kyros_ssg_active_zero_audit/finite_qualification.json.


## Reference output selection — verified 2026-10-11

The private Stingray checkpoint consumer used diagnostic Lua screen:pixels()
RGB from the alternate drawing buffer. Its completed screen:snapshot PNG,
normalized by the declared ROT90, matches native fields0/30/90/119 exactly.
Select the existing .display.rgb contract for display comparisons and bind its
source PNG hash; preserve .rgb/.pix32 as diagnostic drawing-buffer evidence.
Canonical capture_oracle.py, normalize_oracle_display.py and
analyze_system_capture.py already follow this contract. The narrow private
consumer correction is staged with syntax qualification. This is a reference
artifact-selection defect; game/PCB bug dispositions and B16 remain separate.
See research/completed_display_evidence_integration.json and the immutable
first_buffer_cause/consumer manifests retained under stingray_combined_stage.


## Additional online audio reports and Kyros intro-voice audit - 2026-10-11

This supplements the original five-report search; B03-B06 retain their existing bug IDs. Primary-source searches found no confirmed report specifically establishing corrupt Kyros intro voices in MAME 0.289. That is a search result, not proof of absence or native-core acceptance.

| Report | Verified scope/status | Version and 0.289 disposition | Core implication |
| --- | --- | --- | --- |
| [MT03582](https://mametesters.org/view.php?id=3582) | Confirmed/open debug clipping after MAME autosave-state loading; explicitly lists `kyros`/`kyrosj`. | Reported 0.135u3; regression field `<0.132u2`; no fix/version recorded. Current 0.289 reproduction unknown. | Keep reset/DAC-held-value and mix-transient checks. MiSTer hiscore restore is not MAME full-machine save-state loading; cold intro corruption does not establish this cause. |
| [MT03043](https://mametesters.org/view.php?id=3043) | AY envelope-register diagnostic at boot lists all three games. Resolved as removed diagnostic logging, not a measured Kyros voice repair. | Reported 0.130. [f87a5de4](https://github.com/mamedev/mame/commit/f87a5de4468cb7949d52d153491d5cf2aa0daa0f) changed popmessage to verbose logging in 2016; [1f786226](https://github.com/mamedev/mame/commit/1f786226cb3b42da77bafef70105311b64166732) removed that logging in 2020. No fixed-version field. | Envelope writes are legitimate; preserve them. Removed warnings do not qualify envelope correctness. |
| [MT02875](https://mametesters.org/view.php?id=2875) | Generic AY note-duration/volume-zero investigation; no Kyros-specific reproduction. | Reported 0.124u5; fixed-version field 0.130u1. Historical device behavior, not an established 0.289 regression. | Candidate donor volume-zero/tone-gating test; do not infer every voice is AY envelope audio. |
| [MT02868](https://mametesters.org/view.php?id=2868) | Kyros/Japan partial coin/demo sound allegation resolved as Bugs That Aren't Bugs after PCB comparison on 2024-12-29. | Reported 0.129u2; no corrective fix. | Coin sound interruption/continuation alone is not a defect. PCB comparison here does not prove all voices are normally distorted. |
| [MT05913](https://mametesters.org/view.php?id=5913) | Kyros/Japan no-sound report closed Invalid; other official/Linux builds did not reproduce. | Reported 0.160; no fix. | Configuration/host issue candidate only; no game RTL correction justified. |
| [MT05438](https://mametesters.org/view.php?id=5438) | Open AY output-load/discrete-filter report confirms 1942/Nemesis hardware; no Alpha68k N evidence. | Reported 0.152; no fix. Kyros applicability unproven. | Analogue-load candidate only; do not transplant another PCB's resistor/filter values. |

### Current sound baseline and smallest responsible diagnosis

B06 version precision: [MAME 0.242 / PR9382](https://www.mamedev.org/?p=511) corrected Stingray clocks/chip types; [MAME 0.243 / PR9423](https://www.mamedev.org/?p=512) corrected Kyros clocks/comments. The [official 0.289 driver](https://raw.githubusercontent.com/mamedev/mame/mame0289/src/mame/alpha/alpha68k_n.cpp) uses Kyros Z80 4 MHz, YM2203 and both AY8910s 2 MHz, vblank IRQ0, separate 4 kHz NMI, and 8-bit DAC writes at `e004`; route gains are 0.30/0.30/0.60/0.50. Its ignored `e006..e00e` I/O remains a documented physical unknown (B13).

For the reported intro, compare real Z80 DAC byte/order/cadence first, then separate chip outputs and signed mixed output for clipping/reset transients (B03/B05/B06). A matching byte stream narrows synthesis/mixing; a mismatch requires sound CPU/ROM/interrupt/write-path diagnosis. No consulted primary source proves the entire original intro recording is inherently poor quality. Preserve any measured original grain; do not excuse extra corruption or add smoothing without evidence. This audit ran no replay/build and closes no native audio gate.


## B16 — eligible higher interrupt deferred during M68000 vector lookup

This is a locally verified reference limitation, not an online MAMETesters report or a confirmed FPGA fault. The 0.289 M68000 source clears `m_int_next_state` in `end_interrupt_vector_lookup` without preserving a higher eligible interrupt that became pending during lower-priority acknowledgement. Partial execution resumes the acknowledgement without recomputing pending state before that clear.

A single private passive-observer 221-field Kyros run recorded IRQ2 ASSERT at master tick 176799999 while IRQ1 was selected, SR=2104 (mask 1), level=2 and pending=02000004. At 176800119, the paired lookup-end observations clear pending to zero while the interrupt level, asserted-line bitmap and SR remain unchanged. Pending IRQ2 is recomputed only during IRQ1 RTE at 176875639 (CURPC=0514, IR/IRD=4E73). The finding establishes delayed recognition, not permanent loss or an exact physical interrupt latency.

The observer preserves guest behavior: 39 raw capture products match the original reference, including inputs, state, events, RAM, sprite/pixel data and PCM. Checks cover 1753 records, 876 complete pairs, continuous per-callsite counters below the 20000 cap and the enclosing observation window. Initial encoded-PNG hash failure is retained; pixel-bearing chunks match and only Software metadata differs. Original official reference and private build inputs are preserved. No functional MAME or RTL change was made. The private source build is observation evidence tied to the original matching reference, not a claim that the official executable exported these internal states.

Evidence in local staging `D:/Arcade/AI/aCORES/Alpha68k N/research/dual_release_20261011/kyros_irq_reference/pending_probe_v1/`: `pending_state_terminal_manifest.json` SHA ec4f1da7c80ff76a2102d1074ad0068072d3ba20c4c28a5dc0a6526df2d7b906; `pending_state_qualification.json` SHA 5c69661b2b1e0b74ca1265baa915b55af2b47a9f0a94cf6df5878759793db409. Independent source/causal review accepted the limitation. Architecture reference: [NXP M68000-core interrupt description](https://www.nxp.com/docs/en/reference-manual/MC68302UM.pdf).

Core disposition: preserve proper live interrupt priority/nesting; do not change FPGA phase or erase a pending interrupt to force MAME stack equality. Retain original raw comparison failures. Source-classified saved-stack generations are diagnostics when real writes match saved registers and no incorrect restored state or game behavior is demonstrated. Persistent game state, controls, scores, lifecycle, audio and graphics remain independently qualified. Application to Stingray is possible through the shared CPU implementation but is not separately reproduced by this probe. This finding does not blanket-waive other RAM differences.


## Current implementation/reference disposition — 2026-10-11

The V66 black VGA symptom is a local framework integration defect, not a MAME bug: branch-local RGB buses became implicit scalar nets outside generate scope. The core-owned mixer repair passed the original V67 five-field transfer guard with1,176 colored pixels exact. The original framework files are preserved; full pickup qualification and joined fit remain pending.

Stingray's retained genuine1010 comparison identifies one missing MAME game-counter write at391, followed by one-update drift and later active graphics/RAM differences. Native writes are one per field108..1009 with no duplicate. The ROM writer is ADDQ.W at101E; prefetched PC1024/IRD522E do not identify its retirement address. IRQ2/MCU HALT activity overlaps late390; current reference products lack delivered IRQ/HALT ancestry. The single passive393 diagnostic will distinguish CPU/MCU timing from a reference limitation. B16 was causally demonstrated for Kyros only and is not automatically a Stingray waiver. No functional reference patch or native IRQ/clock adjustment has been made from this hypothesis.


## Stingray field391 finite reference classification — 2026-10-11

Closed passive393 native0 evidence locates the missing IRQ1 callback in MAME's generic device_execute_interface::on_vblank (diexec.cpp551..563), which excludes HALT/RESET/DISABLE/CLOCK suspension before invoking the bound callback. The Alpha driver binds irq1_line_hold and the inherited callback directly requests level1 HOLD. Expected317104127 falls inside deliveredHALT317101607..317105417; surrounding IRQ1 deliveries have a two-field gap and the original game counter lacks391. This is distinct from the Kyros pending-clear B16 finding. The original strict393 empty Lua-context failure and full1010 post391 comparison failure are retained. No FPGA IRQ change, physical-board retention claim or full post391 equivalence pass follows from this finite diagnosis. User stopped further diagnostics and requested immediate named RBF/MRA construction.


## 2026-10-12 — reported Kyros overlaps and Stingray startup pan

The user confirmed the latest packaged `Arcade-Alpha68kN.rbf` was used for the reported screenshots. The user then supplied [PCB footage](https://www.youtube.com/watch?v=CXavOOQMmTs) and stills showing Kyros characters overlapping both doors/walls and barrels. Preserve this observed priority behavior. B02 already documents separately PCB-verified ending overlap in [MT01149](https://mametesters.org/view.php?id=1149&nbn=1); that ending report alone does not establish every gameplay interaction. The new gameplay classification is based on the supplied PCB comparison.

The bounded online search found no confirmed MAME Testers/GitHub report matching the reported Stingray startup bottom-edge pop-in. B11's horizontal-wrap/transparency TODOs remain unresolved modeling doubts, without a demonstrated correction. A fresh owned vanilla MAME0.289 run used coin/start only and captured every field150..599. Its startup camera return pan exhibits the general bottom-edge appearance pattern.

Eight actual Verilator renderer/palette/SDRAM fixtures sampled both pan directions: sprite-RAM fields390,420,450,456,462,480,486,510. Each matches all57,344 pixels of MAME display field f+1, with zero renderer deadline misses or row overflows. The original same-number comparisons failed (native exit1) and remain retained: this run's machine-frame callback exposes updated RAM alongside the preceding displayed field. This is a capture-phase finding, not permission to shift arbitrary gameplay replays. The independent MAME strip-loop formula also matches every fixture exactly.

No sprite RTL patch is justified by these finite results. They do not qualify full CPU execution, SDRAM hardware timing, or Stingray PCB equivalence. Source checkpoint `d1c82c9b2ad4cdcb7994ce5e8b37651c65375633`; exact source pins, original failures, aligned RGB hashes and owned-run receipts: `D:/Arcade/AI/aCORES/Alpha68k N/research/sprite_repair_20261011/findings.json`. Existing B01 stage5 correction remains preserved. No Quartus/RBF job was launched for this investigation.
