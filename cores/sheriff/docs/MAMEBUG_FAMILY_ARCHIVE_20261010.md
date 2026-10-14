> Archived research and former scope, superseded on 2026-10-10. This is not an active implementation plan. Only the Nintendo Sheriff parent remains in scope.

# MAME bug and limitation register — Nintendo 8080 family

Research date: 2026-10-09. Reference binary: local MAME **0.289 (unknown)**. Exact local source files are saved under `docs/evidence/mame/`; hashes are in `docs/evidence/mame_sources.json` and `preparation_manifest.json`. The source directory is not a Git checkout. Public upstream revisions are evidence links, not a substitute for these hashes.

This register covers all applicable findings obtained from public MAME Testers searches, direct issue pages, current local drivers/device models, and bounded upstream history across both current and historical `drivers`, `audio` and `video` paths. It separates fixed regressions, current documented limitations, and historical reference assumptions. **It is not a claim that every issue ever reported anywhere on the internet has been found.** MAME Testers search/filter requests returned its unfiltered list in this environment; those responses were not interpreted as zero matches. Direct issue pages and source history supplied the confirmed results. No additional Sheriff-specific open issue was confirmed by the searches.

## Fixed regressions to preserve

| ID | Games | Finding and status relative to 0.289 | Core action / focused acceptance |
|---|---|---|---|
| MB-01 | HeliFire sets | [MT09386](https://mametesters.org/view.php?id=9386): pitch roughly three semitones high and tempo fast in 0.285; fixed in **0.286**, [commit 314d9b9](https://github.com/mamedev/mame/commit/314d9b9aa50eaec52b9f2c2f949a07491be9c293). Local sound driver sets the MCU crystal to **5 MHz**, overriding the common 6 MHz. | Profile-specific 5 MHz enable; compare boot melody pitch/tempo. Do not use the older 6 MHz HeliFire setting. Already fixed upstream; no 0.289 patch needed for this clock. |
| MB-02 | Space Launcher | [MT04666](https://mametesters.org/view.php?id=4666): DAC effect missing when killing an upper-formation alien, regression from 0.138u2; fixed in **0.145u1**, [commit 2425771](https://github.com/mamedev/mame/commit/24257711dcb14a8f1d6b90c95fc63b00a9a284fb). | Preserve command/pin behavior and actual MCU ROM execution. Capture that kill event and require its DAC activity. |
| MB-03 | Sheriff/Bandido | Historical missing/scheduled shot and hit effects, sound-CPU hookup and later missing SFX fixes. Older MAMEinfo history reports repairs in 0.80u2 and 0.145u1; no separate matching public ticket was confirmed. Current 0.289 sound implementation is the baseline. | Exercise shot, enemy hit, player death and tunes. Do not copy pre-fix port scheduling or sample-only approximations. Historical lead, not an asserted open 0.289 defect. |
| MB-04 | HeliFire, Space Launcher; shared CPU path | 8080/8085 INTE callback did not reflect IE being cleared on interrupt entry. [Upstream fix 638032f](https://github.com/mamedev/mame/commit/638032fbeb4ee36d43b86bef7e4b52d2f33bcc1e) explicitly names both games. | Clear/propagate INTE at interrupt acknowledge, respect EI delay and HALT wakeup, and avoid repeated IRQ servicing until re-enabled. One short sequence is sufficient; no separate long CPU campaign. |
| MB-05 | HeliFire; shared MCS-48 board logic | Fake 8035 interrupt pulses suppressed effects. [Fix 5cd4c55](https://github.com/mamedev/mame/commit/5cd4c55b9b94d7e59c325ef6a0e1ba1d6583228d) uses the actual IRQ line level. | Drive active-low IRQ for the lifetime implied by sound command pins; do not emit an artificial one-master-cycle pulse. Check retrigger and sustained command sequences. |
| MB-06 | HeliFire | Historical repairs restored shot/death color flashing, volume decay in startup/bonus tunes and starfield speed. Treat the current driver's line counters, envelope and flash path as the reference. | Check death flash, an envelope clip and star displacement across a fixed frame interval. These are regression targets, not proof that all current graphics/audio are accurate. |

MB-03 and MB-06 are historical leads corroborated by the current source behavior, with older release/MAMEinfo descriptions found online. They have lower evidence strength than the linked direct issues/commits; do not invent ticket numbers or exact original-board accuracy from those descriptions.

## Current documented limitations and assumptions

| ID | Games/components | Evidence in the staged 0.289 source | Implementation decision and closure |
|---|---|---|---|
| MB-07 | Space Fever sound; related sound configurations must be checked individually | `n8080.cpp:19` TODO says laser-fire and enemy-explosion pitch is wrong. | Baseline command routing against MAME; tune the relevant VCO/noise path only from board component values or measured original sound. A corrected clip must name its evidence and expected difference. Do not assume the same pitch defect applies to every ROM swap. |
| MB-08 | SN76477 shared analog model, Sheriff/Space Fever | `sn76477.cpp` documents uncertain VCO voltages/duty cycle, approximate VCO and attack/decay capacitor formulas, resistor edge cases and some disconnected-pin behavior. | Implement the pins/functions actually used, with finite fixed-point range and retained model assumptions. Scope tests to connected Sheriff/Space Fever configurations. Laser Battle pin-12/no-cap details are not automatically relevant to these PCBs. Do not call a generic noise/UFO oscillator a complete SN76477. |
| MB-09 | HeliFire | Driver declares `MACHINE_IMPERFECT_SOUND`, `MACHINE_IMPERFECT_GRAPHICS` and `MACHINE_NO_COCKTAIL`. MT09386 also mentions remaining missing effects outside that report. No specific complete repair was established. | Make all three explicit family qualification items: effects, sea/sky/star/flash behavior and cocktail controls/flip. Use exact 0.289 graphics as a baseline; obtain hardware evidence before corrections. A flag alone does not identify a root cause. |
| MB-10 | Space Launcher palette | Its current ROM definition shares the Space Fever PROM. Historical driver updates treated that PROM choice as likely correct; independent Space Launcher PROM evidence was not established here. | Load the specified PROM for MAME equality. Record shared-PROM assumption; replace only after an independently verified dump/schematic proves a difference. |
| MB-11 | Space Fever monochrome/color hardware | Current source distinguishes original B&W and later color variants; [upstream configuration change d7ae941](https://github.com/mamedev/mame/commit/d7ae941798bedefd9f1e2bf858e193cb4d958e78) exposes monochrome selection. | Offer the reference-supported video option. Do not paint a guessed overlay into the raw RGB golden frame. |
| MB-12 | Computer Othello CPU timing | `cothello.cpp:24..29`: CPU speed is wrong; likely 1.79 MHz, while even XTAL/4 is too fast versus footage. The M58741P HOLD arbitration is not emulated. Current CPU setting is **750,000 Hz**. | Retain a 0.289 comparison baseline; model actual HOLD/HLDA and memory ownership after evidence establishes the schedule. Do not “fix” it by another guessed underclock or blindly using 1.79 MHz. |
| MB-13 | Computer Othello video | TODO: verify video timing; monochrome/color and green-tint origin remain uncertain. M58741P supports 3 bpp but fitted DRAM stores 1 bpp. | Implement fitted memory planes, confirm raster/blanking and palette/overlay from primary board/manual evidence. Do not interpret software writes of three bits as proof of three populated video planes. |
| MB-14 | Computer Othello sound | TODO: beeper duration and base frequency approximated; divisor is considered correct. Driver declares imperfect sound/timing. | Reuse divisor/control logic; source actual oscillator/one-shot values or measured pitch/length. Keep approximations named until measured. |
| MB-15 | Computer Othello inputs/counter | TODO questions whether button selection is missing (P1 may move P2 cursor); independent seven-segment timer is not software-controlled. | Check the PCB wiring/manual; emulate input selection and independent counter rather than inventing cabinet behavior. Implement coin handling from the current working driver, not its early nonworking version. |
| MB-16 | Block Fever sound | `blockfvr.cpp` uses three fixed beepers at **1332, 666, 333 Hz** and declares imperfect sound. These are an emulation approximation of the discrete board. | Stage proper discrete oscillator/mixer primitives; implement control/envelopes from board evidence. Compare effects first, then qualify pitch/duration. Do not promise exact analog sound from these three nominal frequencies. |
| MB-17 | Block Fever replay/lamp output | `lamp_w` TODO notes bit 0 is set when replay is reached; its complete output meaning is not implemented. | Observe the replay condition and wire the correct indicator/counter once verified. Preserve unrelated lamp/start outputs and the original ROM. |
| MB-18 | Sheriff 8080 raster IRQ scheduling; locally reproduced in 0.289, not an online MAME Testers report | In the matching 70-frame reference, two RST stack-write timestamps imply instruction start one CPU T state before the raster request. Integer CPU/pixel periods leave the preceding CPU boundary 1.900544/2.017280 ps short of a complete scheduler cycle; `schedule.cpp` skips it, then `i8085.cpp` checks the new IRQ at the old local instruction boundary. A separate frame-103 corner shows JNZ completing before IRQ and RTL executing LDA while MAME interrupts at its older pre-LDA boundary. | Keep real CPU phase sampling. The earlier two ANA/JNZ corners and the separately captured JNZ/LDA corner pass independent ISA/clock predictions. At the latter, native opcode fetches predict final JNZ phi2 at IRQ minus eight clocks, ACK at plus 331, stack writes at plus 494/569 and return PC 0x0ff2 exactly. Raw differences remain visible; no blanket IRQ/graphics waiver. Evidence: `docs/evidence/sheriff_irq_scheduler_corners.json` and `docs/evidence/sheriff_output_irq_sampling.json`; reproduce with `tools/qualify_mame_irq_boundary.py` and `tools/qualify_output_irq_sampling.py`. |
| MB-19 | Sheriff deterministic input capture at a frame boundary; local 0.289 diagnostic, not an upstream ticket | At restart frame 1548 the first unequal input read follows 75,823 matching reads. A shared event-order trace shows MAME reading old port-2 value 1 before applying value 0, although that read's CPU-local timestamp is 100 master clocks after the input callback timestamp. The callback is on the physical frame edge. `i8085.cpp:887..894,1516..1519` executes/debits a whole instruction before returning to the scheduler. | Retain real input timing and CPU bus behavior; never delay controls merely to imitate this instruction-atomic reference artifact. Record applied-event order separately from callback time. This explains the first input-read difference; its contribution to frame-2760/6780 pixel differences remains unqualified. No input, RAM or graphics waiver. Evidence: `docs/evidence/sheriff_input_scheduler_boundary.json`; reproduce with `tools/qualify_input_scheduler_boundary.py`. |

MB-18's physical CPU sampling rule is supported by Intel's
[Intellec 8 Mod 80 Reference Manual, February 1975, Interrupt Sequences and Figure 2-8](https://bitsavers.org/components/intel/MCS80/Intellec_8_Mod_80/Intel_Intellec_8_Mod_80_Reference_Manual_Feb75.pdf):
the enabled asynchronous request is reclocked with phi2 in the final
instruction state. The captured RTL clock epoch is 18 master clocks; this
qualification uses that observed phase, rather than changing reset/raster
timing to match the emulator. MAME decimal timestamps are checked within
their 12-decimal reporting precision. No trace, ROM or FPGA instruction
logic is changed by the diagnostic. Longer replays and other startup clock
epochs retain their own acceptance gates.

The unidentified Universal Computer R-3 relationship in `cothello.cpp` is a preservation/research question outside the requested game's operation, not a blocking bug to solve for this core. Western Gun Part II's guessed 262-line timing is also outside the requested parent selection; do not accidentally inherit it for Sheriff.

## Graphics and correction policy

Sheriff's 0.289 registration has `MACHINE_SUPPORTS_SAVE` and no imperfect graphics/sound flag. That absence is not independent proof of physical accuracy. Its ROM/PROM video path is nevertheless a strong initial baseline: bitmap bit order, PROM protection bit, all color-control modes, red-heart effects, death flash, clipping and flip must match at comparable machine state/frame phase.

A sound defect fixed in MAME before 0.289 is a regression check, not a reason to modify the current oracle. For current known limitations, first reproduce/label the 0.289 behavior, then introduce a correction only with schematics, measured board behavior or a verified upstream repair. Store corrected expectations separately with the reason; permit only those scoped differences in comparison. Never use a blanket “MAME is buggy” exemption.

## Evidence and recovery

- Direct issue HTML: `docs/evidence/mt9386.html`, `mt4666.html`.
- Current source snapshots: `docs/evidence/mame/src/mame/nintendo/` and `docs/evidence/mame/src/devices/`.
- Source histories: `docs/evidence/mame_*_history.json`, `history_src_mame_*_n8080*.json`, `history_src_mame_nintendo_blockfvr.cpp.json`; compact findings in `relevant_history.json`.
- Search coverage: Sheriff/Bandido, Space Fever/spacefev/old set aliases, SF-HiSplitter/highsplt, Space Launcher/spacelnc, HeliFire/helifire/helifirea, Computer Othello/cothello and Block Fever/blockfvr; both `n8080.c` and `n8080.cpp`, shared CPU and SN76477 model history. Public search results can miss unindexed or renamed reports.
- General old MCS-48 cheat/debugger crashes (e.g. MT02672) are emulator-host issues, already historical, and do not need fabricated FPGA fixes. The directly unrelated SN76477 games in MT00745 are not Nintendo reports; use them only if their device-level root cause is independently shown relevant.
- Primary [current MAME driver](https://github.com/mamedev/mame/blob/mame0289/src/mame/nintendo/n8080.cpp), [sound-board model](https://github.com/mamedev/mame/blob/mame0289/src/mame/nintendo/n8080_a.cpp), [Othello driver](https://github.com/mamedev/mame/blob/mame0289/src/mame/nintendo/cothello.cpp) and [Block Fever driver](https://github.com/mamedev/mame/blob/mame0289/src/mame/nintendo/blockfvr.cpp). Local snapshots are the directly inspected 0.289 content if a tag link is unavailable.

## Further Sheriff timing evidence (2026-10-09)

The focused frame-6780 MAME capture is an exact byte prefix of the original restart I/O and RAM-write files. Native and MAME write the same byte at 0x43eb on opposite sides of pixel x95/y31; the preceding IRQ returns at 0x0a03 versus 0x0a06, straddling LXI H (three bytes, ten T states). `docs/evidence/sheriff_pixel_6780_boundary.json` preserves the raw timing, metadata and hashes. The existing native bus window misses the pre-vblank fetches because it starts at the target edge; corrected leading windows are needed in the next necessary replay. This supplements MB-18 without qualifying a new exception.

Primary Sheriff/Bandido manuals also identify the video 198 register at I/O 1L. The current per-pixel functional scanout has not modeled its byte-load/shift boundary. Treat that as an RTL/oracle hardware-assumption gap, not a newly proven MAME bug. Resolve the physical derivation in `docs/HARDWARE_VIDEO.md` before classifying either remaining restart pixel. No graphics, RAM, input or IRQ waiver is applied.

The first third-round pixel corner is now localized separately: frame 2400 x33/y33, RAM 0x4424. The focused 2401-frame reference is byte-prefix-identical to the original static-input capture and identifies MOV M,A at 0x12c3. MAME clears the byte about 88 clocks before the pixel; native clears it 156 clocks after. Its preceding vblank saves 0x0891 versus 0x0894 across a ten-T-state JNZ, with MAME atomic stack writes about +250 and native bus writes +419/+494 clocks. `docs/evidence/sheriff_rounds_pixel_2400_boundary.json` retains the observations and an unqualified cause. A byte load at the first-pixel sample would not resolve this corner; the actual PCB load phase remains open. Add completed-field observer window 2398 in the next necessary replay to obtain independent pre-IRQ native instruction anchors. This supplements MB-18 and does not waive the failed third-round comparison.

## 2026-10-09 clock-waveform and scheduling evidence update

The connected related-Bandido CPU waveform resolves the saved-model first third-round field-2400 pixel corner without changing MAME, raster/IRQ offsets or scanout. Native and MAME both stack PC 0x0891 there; all 45 captured fields through 2401 match exactly. See docs/evidence/sheriff_clock_round2400.json. MB18 scheduler behavior and older-source boundary evidence retain their original scope; this does not close the complete scheduler/graphics gate. Later restart corners, physical DRAM/serializer/READY timing and exact Sheriff net applicability remain open. No mismatch tolerance or reference waiver was introduced.

MB-18 corrected-clock scope update (2026-10-09): immutable cb67879 replay through6781 exits0. Field6780 is now exact under the unchanged timed-write oracle and both IRQ returns are0x0a06; field2760 still differs by one pixel. docs/evidence/sheriff_clock_restart6780.json preserves terminal/source/hash evidence. This supersedes the older wrong-PC explanation at6780 for this saved source only; it does not close MB-18 or the complete graphics gate.

MB-18 upstream scope update (2026-10-09): docs/evidence/sheriff_clock_restart2758_epoch.json verifies a prior field2758 IRQ saving native0x0590 versus MAME0x05a0, with the explicit post-ISR JZ accounting for a250-clock local epoch change. This precedes the remaining field2760 pixel failure. The aligner independently accounts for MAME untaken jump/call operand omissions per i8085.cpp:821-847 and stops at the next unexplained mid-screen difference. Upstream physical/instruction phase remains unqualified; this is diagnostic evidence, not an exception or graphics pass.

MB-18 corrected-clock scheduler symptom (2026-10-09): complete local restart opcode alignment now accounts for all13,372 reference accesses with three explicitly stack-verified IRQ reorderings. At mid-screen edge2259814400, MAME ISR fetch minus11T places atomic RST start approximately25.0034152 master clocks before the physical request; actual native CPI7T/phi2 predicts ACK+27 and stack+194/+269. Evidence: docs/evidence/sheriff_clock_restart2758_epoch.json. The later mid-screen event starts after its request and is not claimed as the same backdating symptom. Upstream vblank phase and the field2760 pixel remain unqualified; no graphics waiver follows.

MB-18 direct leading-window update (2026-10-09): docs/evidence/sheriff_prior_vblank_boundary.json now observes native ANA A0x059f and JZ0x05a0 before the field2758 vblank. Independent4T/10T sampling predicts ACK+152 and stack+319/+394 exactly. MAME ANA is124.9966128 clocks later and its atomic interrupt starts about+24.9966 after the request; do not label this vblank as backdated. The upstream epoch gap and remaining pixel failure remain unqualified. Equal MAME operand/opcode timestamps require preserving CSV access order when identifying the preceding opcode.

### 2026-10-09 first ordered RAM IRQ boundary

The first23,193 writes agree exactly; the next field66 IRQ saves native0x0ff3 versus MAME0x0fef. `docs/evidence/sheriff_first_ram_boundary.json` directly qualifies both exits0, exact native/reference prefixes and ANA A4T/IRQ sampling. MAME executes taken JNZ0x0ff3 ->0x0fef starting about25 clocks before the request and begins RST about225 clocks after it. This is not a backdated-request reproduction of MB-18. Its instruction epoch is about50 clocks earlier before ANA A; absolute boot/raster phase remains open. No timing offset, pixel tolerance or graphics waiver is justified by this observation.

### 2026-10-10 reset timing observables and projection correction

MAME initial PC0 fetch is time0, whereas the saved native first SYNC/DBIN are52/77 and its T1 tag50. A source-level reset model predicts every one of the78 initial pin samples; Intel1975 Figure2-13 includes a recovery interval before M1. This does not establish a donor reset defect or a Sheriff absolute-phase correction. The initial raw ROM difference at0x00e2 is the known MAME omission of untaken JNZ operands, explicitly explained without advancing the comparator. Historical final-phi2 offsets of19 from the T1 tag confused counter phase0 with the actual tag phase7; source gate offset is12. `docs/evidence/sheriff_reset_startup.json` and `docs/CPU_PHASE_ORIGIN.md` supersede that projection, with field66 report updated. Actual ACK/stack ticks, MB-18 observations and the remaining pixel are unchanged.
# Local reference observation: cocktail input callback ordering (2026-10-10)

This is a locally reproduced MAME0.289 reference limitation, not an identified online MAME issue. At the first shared-input value discrepancy (ordinal11044), MAME observes port2=0 at frame3799/y240/x18, CPU-local time61.765082837209. Its frame3800 callback then applies port2=1 at time61.765079364862/y240/x0. Diagnostic sequence597964 precedes597965 despite the inverted times. The next read, sequence597966, sees1. The timed CPU callback crossed the frame boundary before the frame notifier updated the input. Native reads1 at tick3112960177/frame3800/y240/x16, after the input boundary.

An unchanged diagnostic3802-field MAME replay exits0 and its entire I/O stream is an exact prefix of the original8000-field cocktail reference. `tools/record_cocktail_input_boundary.py` binds receipts, callback order and source hashes in `docs/evidence/sheriff_cocktail_input_boundary.json`; local recovery is `sim/results/cocktail-input-boundary-mame-20261010/`. The probe records dispatch sequence independently of CPU-local machine.time. Do not add a CPU/raster offset, delay the FPGA input, shift streams or claim complete I/O equivalence from the captured-frame match. Retain the original negative and qualify later comparisons with an explicit input-scheduling contract. This explains this first reference mismatch; it does not close other CPU/IRQ/RAM timing questions.

## Local SN conversion correction (2026-10-10)

This is a core implementation correction, not an asserted upstream MAME bug:
the original Sheriff gain ROM rounded32767-scaled PCM, while MAME0.289 stores
the normalized device sample as float and truncates the32768-scaled output
after float route gain. Source-derived conversion now changes38 of90 ROM
words; the96000-sample native component corpus has zero PCM/comparator errors.
See `docs/evidence/sheriff_sn_pcm_quantization.json` and
`docs/AUDIO_COMPARE_CONTRACT.md`. The separately observed Q32/binary64 gain
boundary and full mixed-gameplay waveform remain unqualified; neither an
arbitrary timing shift nor a gain bias is an approved bug workaround.
## Sheriff SN comparison follow-up (2026-10-10)

The actual dual-chip recorded-write replay completes with exit 0 and matches
all 937,008 original native SN samples. Corrected PCM conversion leaves a
gain-index boundary (native Q32 AD 3.700000047683716 V versus source-calculated
binary64 below 3.7 V) and a larger waveform difference in the second mono1
burst. Source-derived native/MAME trigger and expiry sample positions differ
by one sample in that burst; exact private MAME timer/stream state is not yet
observed. These are comparison/arithmetic/timing findings, not newly confirmed
MAME hardware defects. Preserve the hardware evidence requirement and whole
sound gate. See `docs/evidence/sheriff_sn_gameplay_replay.json`,
`docs/evidence/sheriff_sn_control_sampling.json` and
`docs/AUDIO_COMPARE_CONTRACT.md`. No fitted delay or gain bias was applied.

The source-derived control sampling hypothesis now reproduces all 936,961
original reference PCM samples, across all five mono1 bursts, using binary64
device equations and the independently qualified DAC/float mixer. Native
control positions plus the same equations explain the larger waveform
differences; a Q32 shadow matches every actual native chip sample and differs
from native-timed binary64 at only two gain-index samples. Evidence:
`docs/evidence/sheriff_sn_control_waveform_all_mono1.json`. This is finite
analytical comparison evidence, not a newly confirmed MAME hardware defect,
a physical timing qualification, or a whole-sound pass. Other sound classes
and exact board timing remain open; production RTL is unchanged.

## 2026-10-10 MB-08 mixed sound reference behaviour and timestamp limits

Local MAME 0.289 `n8080_a.cpp:286..293` calls `stop_mono_flop(1)` before `start_mono_flop(0)`. Each invokes `update_sn_status` (`:133..149`, `:274..279`). `sn76477.cpp:953..975` resets the AD capacitor and starts the SN one-shot on re-enable. When mono1 was active and mono0 inactive, these successive setters create an intermediate disabled state at the same emulated timestamp. Atomic native timer updates preserve enable instead. The complete recorded mixed/retrigger control stream produces 132 versus 106 envelope restarts; the two source models differ on 644,340 samples, first at 831863. This is a verified reference-model difference with unresolved physical applicability, not a newly confirmed MAME hardware defect or a hardware-correct RTL change.

`docs/evidence/sheriff_mixed_sound_checkpoint.json` binds actual analysis exits 0. The generalized native Q32 shadow matches all 1,439,875 saved mixed-prefix samples. The source-ordered mixed model leaves 4,553 WAV differences with nominal printed DAC timestamps; the first is before any SN trigger. The independent 738,245-sample DAC-only check has 130 nominal-index differences and zero under a uniform lower bound at ambiguous integer source-grid edges. Applying that same bound uniformly to 1,113 DAC events plus source setter order matches all 12,482,881 WAV samples, including 35 mono0 triggers, 26 cancellations, 13 overlaps and two mono1 retriggers. No PCM shift, per-event selection or fitted parameter was used. This explains the saved reference without qualifying exact event times.

Correction policy: retain MAME setter order in the independent oracle; obtain integer seconds/attoseconds during the next otherwise-required reference capture; qualify the actual Sheriff trigger/clear/diode-enable propagation before changing core envelope retrigger behaviour. Related Exidy Bandido audio wiring is documented in `docs/evidence/sheriff_sound_enable_network.json`; it does not establish Sheriff pulse timing. Preserve original negatives and the missing native OS receipt. Whole-audio, physical sound and release gates remain open.

### MB-18 reference observation context extension (2026-10-10)
A new optional exact callback ledger observes sequence2663 frame entry after a RAM write whose CPU-local timestamp is about150 master clocks later than the frame callback time. MAME0.289 device_scheduler::time explicitly selects timer expiration, executing-device local time, or global base time by context; see sheriff_scheduler_time_context.json. This confirms that timestamp order across callbacks is not state observation order and narrows the retained frame6240 RAM chronology discrepancy. The short real Sheriff instrumentation test preserves all original outputs. See docs/EXACT_REFERENCE_OBSERVATIONS.md. Capture exact integer timestamps/common sequence in the next required scenario; do not shift physical raster/IRQ, alter reference payloads, retroactively qualify old logs or waive field2760. This is a reference-observation limitation, not a newly established PCB defect.

### MB-18 first return-PC boundary localized (2026-10-10)
The first saved return-PC split is at field66 after82 equal IRQ returns, well before the field2760 pixel negative. Real native/exact MAME captures show reference LDA/ANA50 master clocks earlier: MAME starts JNZ25 clocks before IRQ and returns to0fef after it; native finishes ANA25 clocks after IRQ and saves0ff3 before JNZ. First82 inferred RST epochs differ consistently by-50 clocks, then+200 at this branch crossing. docs/FIRST_IRQ_BOUNDARY.md and sheriff_first_irq_boundary.json bind the successful68-field diagnostic and original source identities. This is an observed origin difference and instruction-boundary consequence, not a proven ANA defect or physical phase correction. Resolve CPU/video/reset origin before an RTL phase change; retain all later graphics/IRQ/DRAM and audio negatives.

## First-IRQ observation projection correction (2026-10-10)

The newer field66 diagnostic reused the earlier bus tags but regressed their phi2 projection to+19. It now binds the completed reset audit: counter phase7 implies final phi2 at tag+12. The recorded return PCs, ACK and stack events are unchanged. MAME atomic opcode callbacks and native bus-derived tags have different origins; their startup difference is not proof of a CPU reset defect or authority for a raster offset. This retains the IRQ/reference-observation limitations and field2760 graphics failure. See docs/CPU_PHASE_ORIGIN.md, docs/FIRST_IRQ_BOUNDARY.md and docs/evidence/sheriff_first_irq_boundary.json.

## MB-08 current-board gain correction evidence (2026-10-10)

Current real parent-ROM/8035 execution through1201 fields reproduces every predicted SN gain-conversion delta:937008 samples,25485 changed, zero unexplained differences from the qualified component replay plus unchanged DAC. Startup/I/O/memory/sound journals and25 RGB/25 RAM snapshots match the prior native source. Actual native/workflow exits0; source/model/artifact hashes verify. This closes the core gain-table integration defect for the mono1 scenario, not MAME analog-model uncertainty, hardware enable/retrigger behavior, mixed/full-wrapper audio or the raw-versus-resampled WAV comparison. The original MAME waveform negative remains preserved. Evidence docs/evidence/sheriff_current_gain_integration.json.


## MB-20 candidate — physical READY service versus the reference (2026-10-10)

The local Nintendo8080 driver maps4000..7fff directly as RAM (`n8080.cpp:680`), clocks Sheriff at20.160MHz/10 (`:1188`) and contains no READY service. The complete local8080 device implementation/header also contain no READY-named interface/model. Exact hashes and callback declarations are in `docs/evidence/sheriff_ready_reference_gap.json`; interpretation and next acceptance are in `docs/READY_REFERENCE_GAP.md`.

Related-Bandido source explicitly drives8080 READY through3D/4F/4G memory-service circuitry for A14 reads and writes. Exact Sheriff revision, physical4116 DO/CAS/WE/write timing, asynchronous pin conflicts and reset alignment remain unresolved, so this is a conditional reference-timing limitation, **not a confirmed open Sheriff MAME bug or a measured wait-count correction**. Preserve the original captures and field66/2760 negatives. Connect the source-supported service and diagnose its first affected boundary; do not add fixed waits or shift raster/IRQ to imitate MAME. Any justified reference correction needs a separately identified real-ROM/input capture and explicit source/evidence closure, with the complete graphics gate retained.
