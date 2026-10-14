# Zero Team USA progress

Last updated: 2026-10-05 (Australia/Sydney).

## Current state

**Phases 3–6 in progress: real V30/COP/video/sound board running in Verilator.**
The target map, native raster, sprite cipher and target audio are integrated.
Early boot buffers and the SEIBU PRESENTS scene match MAME; the cipher matches
every region word. The US COP distance trigger now passes 78 observed cases.
The corrected live title now matches MAME exactly across all 320×256 pixels.
Full attract, gameplay, natural progression and four-player operation remain
unproved. Development Quartus analysis/synthesis is now running under the
2026-10-05 user instruction; timing closure is pending. No RBF build or
MiSTer test has occurred.

## Completed

- Created this workspace from the requested Template_MiSTer repository;
  renamed the Quartus 17 project to `ZeroTeam`, preserved original template
  files and unchanged `sys/` hashes.
- Downloaded both Raiden II donors, Cup Soccer, Raiden and the relevant
  Seibu, NEC CPU, Jotego sound/JTFRAME, T80, high-score and CRT dependencies.
  Exact successful checkout count/revisions are in `donors/manifest.json`.
- Selected rmonic79's Raiden II implementation as the primary hardware base.
  Its integrated V30 `ucore` is preferable to the spacestate donor's documented
  V33 adaptation; both remain available for component reuse.
- Staged local MAME 0.289 target XML and relevant driver/device source with
  SHA-256 provenance. Located the full reference executable at
  `D:\Arcade\AI\mameexe\mame.exe`; the source-tree executable lacks the target.
- Staged the merged `zeroteam.zip` and all 13 dumped target ROMs, verified
  against MAME CRC/size/SHA-1. Four PALs are `NO_DUMP` and explicitly tracked.
- Assembled exact encrypted region images, including program byte lanes,
  sprite word lanes, sound continue/copy and erased holes. Mapping/hashes:
  `reference/rom_layout.json`.
- Wrote `plan.md`, the board inventory, donor/gap matrix, attribution and
  `goal-prompt.md`. RBF builds and all MiSTer testing are in the final phase.

## Evidence / useful recovery handles

| Evidence | Exact path |
| --- | --- |
| Public source pins / submodules | `donors/manifest.json` |
| Original template pin | `reference/research/template.json` |
| Framework preservation | `reference/template/sys-sha256.json` |
| Target identity / ROM hashes / source pins | `reference/mame/manifest.json` |
| MAME 0.289 raw metadata | `reference/mame/zeroteam.xml` |
| ROM region assembly | `reference/rom_layout.json` |
| Decisive preparation check | `reference/research/preparation-check.json` |
| Hardware facts / exact driver entry points | `docs/HARDWARE_NOTES.md` |
| Donor rationale / adaptation gaps | `docs/DONOR_MAP.md` |

## Open implementation work

- Resolve remaining observed US COP/sort/DMA blockers (Phase 3); the sprite
  region cipher and observed distance cases are already checked.
- Verify the richer live attract scene, then resolve
  remaining tile/sprite priority or placement differences (Phase 4).
- Validate integrated music/samples and physical two-/four-player inputs
  during gameplay (Phase 5); real TV80/OPL2/one-OKI RTL is integrated.
- Prove natural gameplay progression and eliminate target blockers (Phase 6).
- Finish MRA/MiSTer features and pass the simulation release gate (Phase 7).
- Only then build/test/release the RBF on MiSTer (Phase 8).

## Known limitations, not completed milestones

MAME 0.289 marks `zeroteam` as not working and documents sort/priority
shortcomings. The exact SEI251 gate implementation and four PAL netlists
are not available in the staged source. The plan names the behavioral
adaptations required; donor presence is not proof they already work.
Related 68000/V33 boards are not substitutes for the US V30 game.

## Next action

Continue the fresh sprite/COP model from the passed title checkpoint at
416 million system cycles to the populated attract reference near 1.04
billion cycles. Compare actual unshifted output, then continue with the staged physical
input schedules and native checkpoints. Preserve donor pins and do not build
an RBF before the final simulation gate.

## Implementation entries

2026-10-04 | Phase 1 partial | Imported 140 donor hardware/assets with
provenance, active source list and wrapper. Added the CPU Verilator seam
and Ubuntu WSL build/run entry. The real V30 fetched its reset vector and
executed the US program for 3,000,000 system cycles: 1,146 distinct prefetch
addresses, 2,129 debug PCs and 64,550 work-RAM writes with modeled three-cycle
memory latency. `docs/evidence/cpu-seam.json` binds this narrow evidence to
the program and CPU source hashes. Full log: `sim/results/cpu-build.log`.
The donor's simulation-only microcode path was corrected; tables and CPU
logic were unchanged. COP/video/sound are not connected in this seam.

The longer ROM-wait probe now follows the donor's CE-freeze contract rather
than relying only on READY. In 600,000 cycles with 13-cycle ROM latency it
made 24,023 RAM writes and withheld 1,266 CPU enables; this evidence is
included in the same CPU-seam metadata. Internal RAM latency is two cycles.

Phase 2 fixture preparation started independently: pristine full MAME
0.289 reached frame 600 of the target attract sequence, producing a visibly
populated 320×256 reference image and 13 RAM/write-only-register dumps.
Raw image/data remain ignored under `sim/results/mame-attract-600/`;
tracked hashes and limitations are in
`docs/evidence/mame-attract-reference.json`. This is MAME reference evidence,
not RTL attract-mode completion.

## Progress entry format for implementation

2026-10-05 | Phase 5 observed line-boundary fix | A real captured-scene
renderer reproduces the same 14 building-edge pixels as the live attract
image. The first column's wrong colors follow the previous row's column one.
Preparing the completed incoming tile row and its first read during blanking,
while retaining the original line fetch/swap timing, removes all 14 errors.
Applied the narrow read selector and first-address fix to production RTL.
Its unchanged-source component run passes the same comparison over three
complete frames, with regular pixel/frame periods and 81,920 pixels per frame.
Water, logo and HUD ROIs remain exact; columns beyond the first two are
unchanged. The whole captured-scene image still has 4,854 differences, so this
is a boundary fix, not a full scene or gameplay gate. Diagnostic changes to
global line-start timing were rejected because they changed other columns.
`docs/evidence/video-line-boundary.json` records the controlled comparisons.

The isolated renderer now hashes/copies the blend lookup table as well as
cipher tables, retains each attempt, and records fixture/model identities.
It uses observed MAME RAM only for component diagnosis; live gameplay remains
on real CPU models. Existing frozen runs and the separately copied current-cold
run continue to test their respective pre-boundary-fix models. A fresh final
model must include this change before simulation release acceptance.

2026-10-05 | Phase 7 focused current-platform verification | Current real RTL
checks passed for little-endian downloads, main/COP memory reads, graphics and
OKI packing, 512x282 raster / 320x256 active area, 75-byte score restore/save
and delayed DDR acknowledgements. The frontend passed 30 current RTL vectors.
Independent MRA assembly matches all five staged MAME regions and the raw
sound file; all 24 physical DIP bits and the source closure passed its checks.
`docs/evidence/platform-options.json` records this focused scope.

Production `emu` lint passed with Verilator's DFG optimizer disabled after the
default optimizer hit an internal width error. Only Intel primitives were
black-boxed; this is wiring evidence, not primitive or hardware validation.
Added `scripts/launch_av_current.py`, which froze 213 current source/support
files into a separate private directory, checked that copying preserved their
hashes, and built a fresh actual AV model there. Its cold run to 600 IRQs is
active under `sim/results/current-builds/current-cold/`. No old native state
was loaded into the changed model. Platform and full-game release gates remain
pending; no Quartus/RBF or MiSTer test occurred.

The earlier frozen gameplay run has reached 1,200 IRQs. Its actual image now
shows the stage-one player amid the street explosion sequence after the
Stage Start screens, demonstrating further natural scene progression. This
does not yet prove combat input response, two-player play or stage completion.
`docs/evidence/platform-and-gameplay-continuation.json` binds these observations.

2026-10-05 | Phase 5/6 isolated live continuations | Added
`scripts/launch_av_branch.py` to retain separate frames, audio and native
checkpoints for concurrent actual-RTL scenarios. It checks the exact compiled
binary hash, ROM/cipher inputs, source closure and serializer configuration,
then copies the verified binary into an isolated private results directory.
Normal mode rejects source drift. Explicit frozen-model mode records the drift
and preserves the original build inventory without claiming current RTL proof.

The existing gameplay run remains active. Additional runs now continue the
600-IRQ attract state to cycle 4,160,000,000 and cold-boot the four-player
cabinet scenario to cycle 3,120,000,000. Both started successfully in
`sim/results/branches/attractloop/` and `sim/results/branches/fourplayer/`.
These test frozen model `0c9e069a` (the authoritative full hash is in each run
inventory). No loop or four-player
completion is claimed yet.

Shared platform changes to main-top hiscore access, configurable sound download,
separate timing reset and the timing module are newer than that binary. Their
worktree source mismatch was detected before launching these branches. They
require a fresh current-source simulation before platform acceptance. The
900/1020-IRQ gameplay images show Stage Start scenes; combat, natural stage
progression, completion and audio fidelity remain pending.

2026-10-05 | Phase 5/6 live attract and gameplay continuation | The corrected
actual RTL completed 1,040,000,000 cycles / 600 IRQs, producing the populated
street attract scene and active FM audio. BG, FG, MG, text, palette and the
compared CRTC bytes match the nearby pristine MAME 599/600 captures. The full
image still differs (8,688 pixels against 599; 9,210 against 600), with sprite
state differences and a small first-two-column boundary discrepancy pending.
`docs/evidence/live-attract-600.json` and
`docs/evidence/live-attract-599-alignment.json` preserve the scope. The inherited
COP LFSR and MAME cycle-derived random streams differ; their effect on these
specific actor differences is not yet established. See `docs/HACKS.md` and
`docs/MAME_KLUDGES.md`.

The compatible native 600-IRQ checkpoint is now continuing with
`sim/inputs/play-2p.csv`. Its actual 900-IRQ image shows Stage Start, a player
HUD and the populated street; the run has also exercised the OKI command path.
This proves entry into gameplay, not completed two-player gameplay, audio
fidelity, natural progression, repeating attract or the simulation release gate.
Raw frames and checkpoints remain private under ignored `sim/results/`.

2026-10-05 | Phase 7 independent platform staging | The wrapper now uses
the same real TV80/YM3812/single-OKI hardware as the live simulator, with
the exact 49-source sound closure generated into `rtl/ZeroTeam_audio.qip`.
Added four HPS pads, three actions per player, starts at SYSTEM bits
0/1/4/5, four active-low coins, cabinet/service configuration and keyboard
controls. Pause accepts every player. Disabled unsupported donor user
savestates and their menu entries; native Verilator checkpoints are intact.
The frontend passes 17 focused actual-RTL vectors, including extended arrow
versus keypad separation, independent releases, service/test and reset.
`docs/evidence/platform-frontend.json` records scope and source hashes.

This is staged platform work, not a passed platform gate. The donor loader,
sprite DDR/cipher path, wrapper video geometry and final MRA still need
adaptation. In particular, the shared sound module's staging download window
at `0x0a0000` needs translation from a nonoverlapping final payload because
the target program region is 1 MiB. No Quartus/RBF or hardware test occurred.

2026-10-04 | Phase 3 observed COP distance fix | The pristine US play trace
first issues `3b30` at frame 170. The donor passes the raw command through
but dispatched only `3bb0`, leaving the distance stale. Added `3b30` to the
existing real restoring-square-root datapath; preserved its bit-7 RAM-write
condition. The focused replay matches all 78 observed US distances with zero
unintended result writes. `docs/evidence/cop-distance-us.json` binds its
source and fixture hashes. Corrected the new replay bridge's input latency
to match production before accepting the arithmetic result.

Stopped the old live run after this verified cause was found. Its later
checkpoints are diagnostic, not validated bring-up states. At 240 IRQs the
title outline/nonblack count matched MAME but 6,869 colored pixels differed;
the image difference was subsequently traced to sprite X bias (entry below). The changed COP
model has a fresh real cold-boot checkpoint at cycle 200,000. Next: continue
the actual CPU/video/sound board with the fixed COP through populated
attract, then the existing physical-input play sequence. No gameplay or
stage-progression completion is claimed.

2026-10-05 | Phase 4 title origin | The 6,869 title differences are an
exact one-pixel horizontal displacement, not a palette difference: comparing
RTL X with MAME X-1 gives zero different RGB pixels. The sprite renderer's
fixed donor `+1` X bias caused that displacement. Removed the bias while
retaining explicit CRT xoff and the shared line-buffer read lookahead.
`docs/evidence/title-origin-diagnosis.json` records the original image hashes,
measurement and scope. The actual corrected live title has passed its
unshifted comparison; no host output correction is applied. The changed
sprite/COP model starts from a fresh cold-boot checkpoint and continues
through the title/attract gates.

The fresh checkpoint at cycle 200,000 restored with strict RTL/ROM identity
validation and is continuing toward 1,040,000,000 cycles. Previous native
checkpoints with the donor X bias are incompatible with this model.

At 416,000,000 cycles, the live board reached 240 IRQs/239 completed rasters.
Its title image matches pristine MAME frame 240 with zero differing RGB
pixels and 13,402 nonblack pixels. The fresh SEIBU PRESENTS raster at 120
IRQs also matches exactly. Evidence is in
`docs/evidence/live-title-origin-fixed.json` and
`docs/evidence/live-presents-origin-fixed.json`, including frozen model/source
inventory and image hashes. The real Z80 continues fetching, with 2,414 FM
writes and 215,435 samples at the title checkpoint; integrated gameplay
sound is still pending. Local implementation checkpoint: `65cf46c`.

2026-10-04 | Input fidelity, real checkpoints and gameplay references |
The earlier live run reached 120 IRQs/119 complete rasters; its rendered
SEIBU PRESENTS image matched pristine MAME frame 120 with zero pixel
differences. The raw coin port in that run was wrongly idle at zero.
MAME's target includes `SEIBU_COIN_INPUTS_INVERT`: all four coin switches
are active-low, and idle is `ff`. Stopped that run, corrected the harness
and annotated its historical evidence. Start 3/4 are SYSTEM bits 4/5,
not bits 2/3. `docs/INPUTS.md` records the exact controls and cabinet modes.
The corrected isolated sound run produces 49,715 samples, 179 FM IRQ
acknowledgements, 180 coin reads and 400,923 real Z80 fetches in one second.

Added native Verilator model serialization with complete external ROM-bridge
transactions and capture/counter state; no MAME/game state is injected.
RTL/model-version/ROM identity gates restoration. The focused continuation
test is exact for device counters, seven RAM ranges and final image.
`docs/evidence/av-checkpoint-roundtrip.json` records scope and limits.
The corrected 600-frame attract run is active from a real early RTL checkpoint.
It reached 120 IRQs with proper coin idle; SEIBU PRESENTS again has zero
pixel differences against MAME. Native state was saved at 208,000,000 cycles.
`docs/evidence/live-presents-120.json` binds the exact image and observed
CPU/sound counts to that saved model and its actual build inputs.
Checkpoint provenance is frozen per process and records its resume parent;
the attract run continues from that saved real state.
Set Verilator's actual fast-code compiler option to `-O3`; its default `-Os`
had overridden the previous host `-O2` flag.

Created repeatable raw physical-input CSVs for 2P and 4P cabinets and a
MAME playback helper that uses only ioport fields/settings. The 2P frame-900
reference enters Stage Start, frame 1800 has scrolled into combat with score
6000 and timer 58, and the 4P/4-slot frame-900 reference shows all four HUDs.
Bounded COP and sound-register traces are retained locally with these
references. No RTL gameplay/progression/music/speech completion is claimed.
The 2P device traces reached the 50,000-event cap; their coverage report
explicitly marks truncation. The 4P frame-900 traces are complete within
that cap. The observed command set is a starting coverage list, not proof
that every later gameplay command has been observed or implemented.

2026-10-04 | Phase 5 sound integration, partial | Added production
`ZeroTeam_audio.sv` using the pinned Raiden Seibu glue/JTOPL2, the imported
single JT6295 and five unmodified licensed TV80 sources. Corrected the
target bank register (`401a`), exact OKI decode (`6000`), plain 64 KiB ROM
mapping, 96 MHz clock enables and pin 7 HIGH. Removed the donor's optional
CPU register savestate/replay interface; no sound savestates are claimed.
The real module is connected to the live V30 sound bus and coin input.

The isolated one-second run passed: 401,312 Z80 fetches, 180 FM IRQ
acknowledgements, 864 FM data writes, 180 coin reads and 49,715 completed
audio samples. Resolved two harness/integration issues: MAME's OKI region
is 1 MiB with 256 KiB populated, and the held FM sample flag must become
one pulse per sample. The JT6295 coefficient paths are now explicit.
`docs/evidence/audio-coldboot.json` records source/ROM hashes, clocks and
limits. Nonzero audio is not yet proof of correct music/speech; the isolated
test does not issue main CPU commands. The live AV run has reached
104,000,000 cycles: 60 main IRQs, 59 complete raster frames, 431,365 Z80
fetches, 254 sound IRQs, 587 FM data writes and 53,858 audio samples.
The rendered Seibu logo retains exactly the earlier 162-pixel discrepancy;
audio integration introduces no additional mismatch at this checkpoint.
No OKI command has been issued yet. `docs/evidence/audio-live-60.json`
binds this checkpoint to the actual build inputs. The 600-frame run remains
active to validate later attract behavior and the command/coin handshake.

2026-10-04 | Phase 3 sprite cipher | Adapted the staged donor cipher
datapath with the public MAME Zero Team tables, target address indexing and
constants. Compared all 2,097,152 sprite-region words against the original
MAME routine: zero differences, including the upper 4 MiB passthrough.
`docs/evidence/sprite-cipher.json` binds source/table/ROM/result hashes.
The cipher is now in the shared RTL video response path; no host-side
sprite decryption is used by the live board harness. Uploaded-key behavior,
sorting and later gameplay are separate pending requirements.

The first live CPU/video run exposed an integration error: connecting text
to CRTC base registers shifted the logo. MAME scrolls only BG/MID/FG, so
the live text origin is now zero. Also corrected the fixed bank interpretation:
`bank_reset(0,2,1,0)` means BG=0, FG=2, MID=1. The earlier text-only logo
did not exercise the mistaken FG/MID ordering.

The corrected live run finished 104,000,000 system cycles with 60 IRQ
acknowledgements, 59 complete captured video frames, recurring tile/palette
DMA, and the real sprite-cipher response pipeline connected. The Seibu
logo is correctly placed. The live frame differs from MAME frame 60 only
in 162 blue pixels on rows 168–169; this is retained as an unresolved
scanout/timing comparison, not declared pixel-exact. All six final live
DMA-buffer ranges match MAME byte for byte. Evidence:
`docs/evidence/live-logo.json` and `live-boot-buffer-comparison.json`.
Next: integrate the real sound CPU and FM/ADPCM devices, then run beyond
this early scene into copyright/title/animated attract and investigate
the remaining differences at stable checkpoints.

2026-10-04 | Phase 4 isolated video bring-up | Added the shared target
`rtl/ZeroTeam_video.sv` around real donor renderers/arbiter/mixer, corrected
the raster and 256-line geometry, target priority order, text origin and
explicit completed-pixel coordinates. The actual RTL-rendered early Seibu
logo matches pristine MAME frame 60 with zero differing pixels (12,380
nonblack pixels). See `docs/evidence/video-logo.json`. The fixture reuses
captured RTL memory; CPU/sound are not running inside it. Next: wire this
same video module to the live CPU/COP memory ports; sprite cipher and
later animated attract/gameplay are still incomplete.

2026-10-04 | Phase 1/2 partial | Integrated the actual donor V30/COP/CRTC
and memory/DMA hierarchy in `sim/zero_board_top.sv`; adapted source/staging
addresses to the target map and fixed tile banks. Ran 104,000,000 system
cycles at the 96 MHz simulation clock (60 vblank interrupts): 5,607,420
ROM transactions, 103,119 CPU writes, 302,080 video-DMA words and 120,832
palette-DMA words. Actual renderer buffers have 304 nonzero text words,
15 palette words and empty BG/FG/MG at this early checkpoint. Raw RTL
buffers/work RAM are ignored; source/ROM hashes and limits are in
`docs/evidence/board-seam.json`. No rendered RTL frame, sound, attract-mode,
gameplay or target sort/protection completion is claimed. Next: connect
the graphics path and sound CPU, then compare meaningful target behavior
against the saved pristine MAME fixtures.

A targeted pristine MAME frame-60 fixture confirms this checkpoint is the
early Seibu logo. All six compared RTL renderer-buffer ranges match the
MAME source ranges byte for byte: BG/FG/MG (2 KiB each), text, palette and
sprite (4 KiB each). See `docs/evidence/boot-buffer-comparison.json` and
`docs/evidence/mame-reference-60.json`. This validates the early data path;
it does not replace the later rendered attract/gameplay gates.

The replacement global instructions revoke standing RBF-build permission:
an explicit user RBF build request is required, and hardware remains after
the simulation release gate.

`Date | phase | commit | behavior changed | decisive check + evidence path |
remaining concrete issue | next action`.

Keep entries short and evidence-based. Distinguish planned, implemented,
simulated and hardware-verified behavior.

2026-10-05 | Video renderer | Production captured-scene proof: all 81,920 pixels equal pristine MAME frame 599. Fixed 256-line sprite gate, incoming sprite-bank read/DE alignment, final-row swap and USA four-pen 127/129 alpha blending. See docs/evidence/video-complete-raster.json. This is a state-seeded component test; live CPU acceptance remains pending.

2026-10-05 | Gameplay continuation | Frozen four-player run at 900 IRQs shows all four active player HUDs and avatars after physical credits/starts. Frozen P1 case completes 1800 IRQs with score 0; effective combat is unproven. Started immutable current-source combat2p-raster cold run with both players, repeated attacks, jumps and a special through physical inputs only. Repeating attract and four-player runs continue separately.

2026-10-05 | Global flip | Actual production renderer with its global flip asserted matches all 81,920 pixels of the captured MAME frame rotated 180 degrees. Normal and flipped component cases both pass with regular /12 pixel and 1,732,608-clock frame periods. See docs/evidence/video-global-flip.json. This is not hardware or live gameplay acceptance. Combat input files now have an explicit LF Git policy for Linux replay.

2026-10-05 | Native state observation | Extended the saved-model observer to export 128 KiB of main work RAM without clocking the model. Frozen gameplay-1800 native RAM matches the existing paused dump byte for byte. See docs/evidence/native-workram-probe.json. Current combat model reaches 60 IRQs with live sound activity; two-player combat acceptance still pending.

2026-10-05 | Current live boot | Corrected AV model SHA 588b441d3b287a6d4c409c5b4b8ede76e687d2fb4343ac8dfc4e8ad04eb81b91 completes frame 59 at 60 IRQs; its early-logo RGB image matches pristine MAME frame 59 exactly. Adjacent frame 60 has 162 differing animation pixels, retained as a phase check. See docs/evidence/current-renderer-live-60.json. Fresh combat2p-raster and combat4p-raster runs now use this same strictly checked compiled model; full gameplay remains pending.

2026-10-05 | Attract continuation | Frozen attract model reaches 1800 IRQs and naturally shows the standalone Zero Team title after the earlier actor/title scene. See docs/evidence/attract-title-transition-1800.json. This confirms a transition, not a complete repeating attract cycle or latest-renderer acceptance. Live sessions retained: attractloop 7373, fourplayer 7601, combat2p-raster 24548, combat4p-raster 72555.

2026-10-05 | Observed COP replay | Production COP passes 128 distance cases in each two/four-player reference and 416 two-player plus 413 four-player collision cases, including 32 positive collisions and 4,145 result-register comparisons. No descriptor errors or unintended RAM writes. Corrected the observer/replay to retain B100-cached bounds separately from later position loads and include both legal position-command variants. No production COP change. See docs/evidence/cop-observed-math-and-collision.json; these component proofs do not replace live gameplay/progression/audio gates. Fresh live runs currently reach 300/240 IRQs for two/four-player; old attract/four-player runs reach 2040/1380.

2026-10-05 | Attract period reference | Pristine MAME at completed frame 2399 shows the beach/crate demo, while frame 4799 has naturally returned to the Seibu logo. Saved exact phase fixtures and started attract-raster cold through 4800 IRQs using the corrected AV binary already running the two/four-player cases. The older attractloop is still finishing its original 2400-IRQ interval; no repeating-attract acceptance is claimed yet.

2026-10-05 | Sound reset | Verified that reset suppressed every sound-chip clock enable, violating JTOPL2 minimum six enabled reset clocks. Oscillator dividers now continue through reset, including paused reset. Real original-ROM sound test observes sufficient reset clocks and zero pre-coin nonzero samples, followed by a bipolar coin response. Historical first-0.2-second recording had 9,942 nonzero samples; corrected recording has zero. Active-renderer MAME startup is also silent with no FM key-on writes. See docs/evidence/audio-reset-clock.json. Started immutable audio-reset-cold session 57447 through 600 IRQs; all five earlier AV runs now predate this audio fix and remain diagnostic only.

2026-10-05 | Corrected live AV boot | Fresh audio-reset-cold reaches 60 IRQs. All 81,920 RGB pixels match pristine completed MAME frame 59, and all 53,859 emitted audio samples are zero as expected before any key-on command. See docs/evidence/audio-reset-live-60.json. The sound fix is accepted for cold startup; music/samples and gameplay/progression remain pending. Older attractloop session 7373 completes its planned interval at 2401 IRQs; the earlier four-player diagnostic reaches 1740, old corrected-video two-player/four-player cases reach 720/600, and old attract-raster reaches 300. Do not restart the completed old attractloop.
2026-10-05 | COP program ROM routing | Fixed B100/B900 pointer and descriptor reads that fell through the RAM-only source mux for banked-ROM addresses. They now use the variable-latency ROM handshake and production CPU bank mapper. All 829 observed two/four-player collision cases match (4,145 result-register comparisons, 6,632 ROM requests), and all 829 independently relocated RAM/ROM cases match. Both ROM banks and 1–9-clock replies are exercised; RAM source returns poison for ROM addresses. Both 128-case distance regressions pass. Evidence: docs/evidence/cop-rom-source-path.json. These component checks do not establish CPU gameplay acceptance.

2026-10-05 | Superseded simulations | Stopped only our four outdated active runs after verifying complete native checkpoints and their compiled-model hashes. Preserved combat2p-raster at 1,768,000,000 clocks, combat4p-raster at 1,560,000,000, attract-raster at 936,000,000 and audio-reset-cold at 624,000,000. The older held-input four-player case completed at 1800 IRQs with zero scores, while pristine MAME under the same inputs scored. That comparison motivated the ROM-routing investigation; the new fix still needs CPU-driven proof. Started fresh immutable cop-rom-combat2p with the corrected sound/video/COP graph through 1800 IRQs. No Quartus/RBF or hardware phase started.
2026-10-05 | Corrected COP live cases | Commit fbf3aad is running in immutable full AV model 89378b6176765c8cde3002dec049afd3048adfa0959db85d891c59f8b7747069. Actual cold prefix reaches 60 IRQs/59 completed frames with 53,859 silent audio samples. Reused its complete native pre-input checkpoint for four-player and attract cases, after strict model/source/ROM identity checks. Active sessions: cop-rom-combat2p 37037 (1800 IRQ target), cop-rom-combat4p 57191 (1800), cop-rom-attract 69963 (4800). Details in docs/evidence/cop-rom-live-build.json. Continue these cases; do not duplicate or resume superseded binaries. CPU scoring, health, progression, repeating attract and complete sound remain open. Capacity-recovery heartbeat remains active.
2026-10-05 | Cabinet checkpoint scope | Corrected the four-player launch: cabinet selection exists at reset and changes the initial main sound configuration. The previous four-player branch inherited a two-player boot and is retained as diagnostic only, stopped at its complete 416,000,000-clock checkpoint. Launched cop-rom-combat4p-cold session 99889 from reset using the same unchanged AV binary and original four-player profile. Added/checked a launcher guard rejecting checkpoint resumes with different initial cabinet/DIPs before creating outputs. Two-player 37037 and attract 69963 continue unchanged. Evidence: docs/evidence/cabinet-checkpoint-guard.json.
2026-10-05 | Sound replay coverage | Added timestamped main sound commands, actual cached coin-pin transitions and an uncapped timed chip trace to the read-only MAME observer. Complete 1800-frame references contain 69,614/69,699 sound writes, 5,406/5,558 musical register writes and 671/820 ADPCM commands for two/four-player modes. The prior bounded trace ended around frame 1350 and is diagnostic only. Verified observer changes leave main commands and MAME WAVs byte-identical. Actual coin pins lag Lua field requests by exactly one 1,732,608-clock frame; corrected that fixture mismatch without changing sound RTL. Production-chip replays with actual pins are active (pins2p 98493, pins4p 35053); earlier requested-pin replays 6258/66934 are diagnostic. Full sound acceptance remains pending. See sim/AUDIO_REPLAY.md.
2026-10-05 | CPU-driven COP ROM witness | At 936,000,000 clocks / 540 IRQs, unchanged corrected full AV model 89378b6 records 4,312 COP ROM requests, 539 completed frames, and a naturally rendered beach/crate attract demo. Read counters and completed image from the saved native host stream without clocking the RTL. Evidence: docs/evidence/cop-rom-cpu-540.json. This establishes that the CPU/board ROM path is exercised; repeating attract and effective gameplay/progression still require their ongoing runs.

2026-10-05 | Actual-pin sound diagnostics completed | Both unchanged production-chip replays reached 3,120,000,000 clocks. They consume all 5,505/5,579 in-window events, but three later fixture commands cause their strict full-fixture exit status 1. Correct actual coin pins reduce first-tone differences against MAME to -0.905/+2.977 ms. Reset clocks and mono checks pass. Musical streams still contain eight additional writes in each mode, and ADPCM streams contain 16/10 additional commands; exact command comparisons fail. These are retained diagnostics, not sound acceptance. Added a compiled preflight rejecting truncated fixtures before output creation or simulation, and documented a longer response window. See docs/evidence/audio-actual-pin-replay-diagnostics.json and audio-replay-preflight.json. Do not repeat these long runs just to change the exit code.

2026-10-05 | CPU600/780 observations | Native 2P CPU600 has 7,412 COP ROM requests and 538,589 silent pre-coin samples. Completed frame 599 differs from pristine MAME in 4,358 of 81,920 pixels within dynamic actors; six of eleven observed actor positions differ upstream while every observed flag agrees. Cause is not established. At CPU780, the completed image is black during the post-start interval, with 42 ADPCM writes and 136,227 nonzero samples; this proves neither visible gameplay nor scoring. Passive probes did not clock RTL. See docs/evidence/cop-rom-cpu-600-780-diagnostics.json. Existing 2P 37037, cold-4P 99889 and attract 69963 continue; no RBF/hardware work started.

2026-10-05 | Audio diagnostic window | Requested-pin diagnostic runs 6258/66934 are terminal at 3,120,000,000 clocks. They consume every event within that window but exit 1 because four captured commands occur just beyond it. Preserve their waveforms/traces as diagnostic, not accepted sound evidence. Evidence: docs/evidence/audio-replay-window-diagnostics.json. Actual-pin replays 98493/35053 are still live with the same limit; classify this boundary explicitly when they finish. Future full-fixture replay limits must exceed the final captured command and allow response time; do not rerun solely to conceal the exit status. Musical/ADPCM comparison remains open.

2026-10-05 | First-stage HUD sprite budget | Captured first-stage production rendering now matches all 81,920 pristine MAME RGB pixels. The old renderer lost 643 HUD pixels in the top 16 rows because 496 unused sprite slots pointed to code 0x8000 at (0,0), consuming work on the unpopulated transparent upper ROM half. A Zero Team-only parameter skips that known blank range; the donor renderer default retains its full ROM range. Graphics requests fall from 107,897 to 80,920 for the same component interval. The fixture now reads all six actual CRTC scroll values and active-low layer enables instead of fixed attract values, and --expect-equal reports failures correctly. Evidence: docs/evidence/video-first-stage-hud.json. No gameplay/progression acceptance is inferred from this component proof.

2026-10-05 | Lossless live sprite-model cutover | Built corrected full AV model 13eaeabf04c600260c63d7c292c81db45481d4d02fef25ae951d19ca689cb19b. Its model headers and all native serialization/deserialization methods exactly match the prior model. New-model passive load/save reproduces complete original native streams byte for byte, with unchanged host bytes, ROMs, CPU sources, cabinet/DIPs and input fixtures. Migrated real 2P/attract state at 2,288,000,000 clocks (1320 IRQs) and real cold-4P state at 1,768,000,000 (1020 IRQs), preserving original streams and explicit lineage. All normal strict resume guards pass. Current live sessions: hud-combat2p 76569 through 1800 IRQs, hud-combat4p 60897 through 1800, hud-attract 94623 through 4800. Superseded sessions 37037/99889/69963 were stopped only after exact replacement processes were confirmed live; terminal status verified. See sim/NATIVE_MIGRATION.md and docs/evidence/hud-live-build.json. Actual corrected CPU HUD, effective combat/scoring/health, natural stages/bosses/ending, full sound and repeating attract remain open. No RBF/hardware phase started.

2026-10-05 | Corrected CPU HUD witness | Updated immutable model continues to native 2P1380, 4P1080 and attract1380 checkpoints. The completed 2P frame shows real first-stage foot combat, restored player portraits and an enemy health HUD; displayed scores are still zero, so effective scoring is unproven. The real cold-configured 4P frame shows all four joined HUDs/portraits during the natural stage intro; four-player effective combat remains pending. Native cabinet values agree (0x700/0x500), with continuing CPU/COP ROM, DMA, FM and ADPCM activity. Saved passive RAM/text/sprite probes, images and exact identities in docs/evidence/hud-cpu-live-witness.json. Continue sessions 76569/60897/94623 without duplicating them. All original gameplay, progression, sound and repeating-attract release gates remain intact.


## 2026-10-05 — development timing closure authorized

The user explicitly requested analysis/synthesis and fit as needed as RTL changes. `plan.md` now brings map/fit/STA into development while retaining final-only RBF generation and MiSTer testing. `scripts/check_timing.ps1` invokes only build-ID generation and explicit map, fit and STA stages; it never invokes the assembler or full compile flow. Source identities and native reports remain under ignored `sim/results/timing` and `output_files`.

Initial actual Quartus passes exposed a missing generated build-ID include, missing DDR interface/source dependencies, and the core's obsolete 49-bit HPS port against the template framework's 46-bit bus. The setup now runs the template build-ID hook, includes the existing donor DDR interface and memory-stream sources, and uses the framework's exact HPS bus width. `sys/` remains unchanged. Production Verilator platform lint passed after the port correction. The current map → fit → STA workflow is running; timing closure is **pending**, not established. No assembler, RBF or MiSTer test has run. HUD renderer/checkpoint work was committed locally as `d74b567`.


### Development synthesis baseline — passed, fit/STA pending

Actual Quartus 17 analysis/synthesis exposed error 276003: the combined registered selector over sound ROM lanes prevented RAM inference. The production fix uses independent synchronous reads and a registered lane selector, preserving the same one-system-clock read behavior. Both ROM banks now appear as inferred `altsyncram` in the real map report. The actual 96M-clock Z80/FM/OKI boot/coin harness passed with all result fields identical to the preserved previous baseline: 400922 fetches, 180 IRQ acknowledgements, 873 FM writes, 49716 samples, 32782 nonzero samples, 1224 enabled reset clocks and zero pre-coin nonzero samples. `docs/evidence/synthesis-sound-rom.json` records the source/report hashes and scope.

Map passed with zero errors (60239 logic cells, 2296 RAM segments, 2 PLLs, 50 DSP elements; 5m25s). Fit and subsequent STA are running in workflow session 13471. Warnings and timing constraints still require assessment; **timing closure is pending**. No RBF was generated. The live HUD/gameplay models retain their immutable pre-hardware-fix source; no unsupported native checkpoint migration or current-top acceptance is claimed.


The successful map summary reports 27221 registers, 2709128 block-memory bits and 3 total PLLs (the earlier mapping log's 2 implemented PLL cells is a different counter). Quartus expanded imported pin assignments into the QSF; the exact synthesis-input QSF was reconstructed and restored by SHA256, and all recorded source hashes matched afterward. Future stage commands disable settings writeback. The timing script parser passed; stage identity guards now prevent fit/STA reuse with changed RTL. Fit is still active; no timing closure claim is made.


## 2026-10-05 — actual two-player combat scoring witness

Passive inspection of the continuing immutable HUD model at 2,912,000,000 clocks/1680 IRQs/1679 completed frames shows real street combat and P2 score **5290**. The independently exported native COP numeric state agrees: low input 5290, high 0, decimal mode 2, conversion pending 0, reversed ASCII digits 0/9/2/5. This is the first positive CPU-driven combat/scoring witness; P1 effectiveness remains open. The cold-four-player case at 2,496,000,000 clocks/1440 IRQs/1439 frames has all four joined HUDs and actors in street combat, but all displayed scores are still zero and per-player effectiveness remains open. No native state was advanced by inspection. Cabinet values remain correct (2P 0x0700, 4P 0x0500). `docs/evidence/hud-combat-scoring-witness.json` records counters, passive RAM/scroll/numeric exports and image hashes against model 13eaeabf…; it does not claim full gameplay/progression or current-top release acceptance. Fit workflow 13471 remains live, while all three AV sessions continue.


### Development fit and timing constraints — timing still FAILED (2026-10-05)

Actual current-RTL synthesis and fitting completed successfully. The first fit uses 29,055/41,910 ALMs (69%), 385/553 RAM blocks (70%), 50/112 DSPs (45%), and 3/6 PLLs. Raw 96 MHz core setup slack is -33.472 ns; Quartus command success does not establish timing closure. See `docs/evidence/timing-first-fit.json`.

The production V30 enable generator passed the focused 200,000-clock spacing test: 11,801 pulses, nominal/minimum gap six fabric clocks, maximum 175, including stalls/pause/resets. Added narrow shared-CE constraints for architectural EU/BIU commits, the packed first decode table and CE bus-adapter latches; separately scoped the existing divide-by-two COP FSM. Fast IRQ, CE_HALF, trigger/cache/DDR paths and the mixed-domain COP status register remain outside these exceptions. With the existing placement, worst setup improves to -11.952 ns on board irq_pending -> V30 row_posted, but remains FAILED. A refit with the scoped constraints is running as session 7098. This is development map/fit/STA only; no assembler, RBF or hardware run. `scripts/check_timing.ps1` now exits unsuccessfully on negative slack and preserves machine-readable timing status. See `docs/evidence/development-ce-timing.json` and `docs/timing.md`.

### Continuing real combat witnesses (2026-10-05)

Real 2P completed frame 2640 shows P1 score 5,100 and P2 5,880; 4P completed frame 1979 shows P3 5,010 and P4 1,700. This establishes effective scoring across player ports in their recorded cabinet configurations; scoring by all four players in one 4P run remains open. See `docs/evidence/hud-all-player-scoring-witness.json`. Original 2P/4P runs terminated successfully at 3.12 billion clocks and continue from exact strict checkpoints through 6.24 billion (sessions 83477/88573). Attract session 94623 continues toward 8.32 billion. All three explicitly use immutable model 13eaeabf04c600260c63d7c292c81db45481d4d02fef25ae951d19ca689cb19b; they do not certify the newly synthesized audio implementation. Natural stages/bosses/ending, complete sound, repeating attract and current-top final acceptance remain open.

Pristine MAME 0.289 with the same 2P physical-input schedule at frame 2640 also displays the first street scene and timer 55 (RTL completed frame 2640: timer 55). This rejects the suspected timer slowdown. MAME scores 420/1,090 differ from RTL 5,100/5,880, so this is contextual progression evidence, not exact gameplay equivalence. No memory/ROM patches were applied. The capture completed with exit zero as session 97500.

V30 demux source audit additionally identifies bs_q/ube_n_q as status captures at CE+4, leaving at least two clocks until the next CE. Added only CE -> status setup4/hold3 and status -> CE setup2/hold1 scopes, preserving single-cycle external IRQ/data inputs. Fit session 7098 began before this phase addition; its final placement will receive an explicit fresh STA pass with the updated constraint identity. The timing workflow now invalidates old stage identities before in-place stages, so a failed refit cannot authorize reuse through an old successful manifest.


### Routed development timing and IRQ phase fix (2026-10-05)

Fit 7098 completed successfully (native fit exit zero, 35m37s). Fresh STA 70800 correctly returns workflow exit one: core setup remains -3.875 ns from board irq_pending to V30 BIU r_cmt_addr (13.863 ns data path); timing is not closed. Resources: 28,770 ALMs/69%, 27,905 registers, 385 RAM blocks/70%, 50 DSPs/45%, three PLLs. Preserved complete routed reports and exact pre-candidate constraints/source identities privately; added measurements to docs/evidence/development-ce-timing.json. No assembler/RBF/hardware run.

Added opt-in IRQ_HALF_CAPTURE to the donor bridge/board, enabled explicitly for the Zero Team production wrapper and board/AV fixtures. The held pending IRQ is captured at CE+2; consumers at the next CE have >=4 clocks. Board IRQ -> sampler remains single-cycle. The actual production generator and bridge/core passed the focused 200,000-clock phase probe (session 97883, exit zero), including fast IRQ changes, stalls, pause and resets: minimum CE gap six, half offset two, minimum IRQ launch-to-CE four. See docs/evidence/irq-half-phase.json and sim/run_irq_phase.sh. This proof uses synthetic NOP bus data, not real-game acceptance. The first probe compile used the wrong interface type; corrected it to the production ssbus_if before the passing run.

Next: actual new-candidate map/fit/STA, then retain or fix the routed critical path. Existing 2P/4P/attract AV sessions remain explicitly historical/frozen and do not certify this candidate. Current-top native checkpoint conversion/replay, functional IRQ/game boot, full progression/sound/features and all final simulation gates remain open; no direct legacy-checkpoint relabeling is permitted.

Started the new IRQ half-phase candidate through scripts/check_timing.ps1 -Stage All (explicit map -> fit -> STA, no assembler). Track the active build session and sim/results/timing/all-irq-half.log; do not start a duplicate build or use the old fitted netlist for current RTL. Timing closure remains pending until this candidate has routed and passed fresh STA.

Active IRQ half-phase Quartus workflow session: 32385. It is the sole current candidate map/fit/STA run; poll it or its stage logs rather than relaunching.

IRQ half-phase candidate analysis/synthesis PASSED at 14:20:38 (native exit zero, zero errors, 1499 warnings, 6m01s). The current fitter recognizes one IRQ half-phase register and three delayed-status registers, and continues in the same workflow session 32385. Latest completed design timing remains FAILED at -3.875 ns; do not treat the current synthesis success as closure. Implementation and phase proof were committed locally as 1e354d8.

IRQ-half workflow 32385 is now terminal: map and fit succeeded; routed STA correctly failed (-1.982 ns core setup). Fit ended 14:50:38 in 29m59s with zero errors/five warnings. Preserved complete reports/status/source identity as sim/results/timing/irq-half-* before further changes. Current real AV model ba2457ede895be21624ee7584bda3260b7ceeb36bb022e776b7c614d5c623210 built in 82.8s and is archived immutably under sim/results/current-builds/irq-half-model. Genuine native reset seed at cycle64 was created by clocking this actual model from reset; the tiny 68-clock seed invocation returned one because functional-progress counters were intentionally not yet reached, not a boot pass. Strict isolated continuation irq-half-attract (session 82786) runs current code from that seed toward 1.04B clocks. No legacy state conversion, stream patch or model relabel was used.

### 2026-10-05 — Sound CE scope and high-score timing candidate

- IRQ half-phase fit completed successfully (29m59s); routed STA failed at -1.982 ns. No RBF was generated.
- Actual production sound oscillator passed 200,000 clocks: 6,877 enables, minimum gap 26, maximum 54 including pause/reset. TV80 audit found only constant reset writes outside the 50 enumerated CE register branches. Scoped setup 2/hold 1 improved STA to -1.733 ns; remaining critical path is RAM readback to the high-score FSM.
- Added an HS-enabled registered byte readback and explicit reader latency handling. Existing 75-byte restore/extract/upload regression and new map/fit/STA are pending; no closure claim.
- Current IRQ/audio AV model ba2457ede895be21624ee7584bda3260b7ceeb36bb022e776b7c614d5c623210 is advancing from actual reset, latest observed 208M clocks/119 frames/120 V30 IRQs, Z80 862,284 fetches/513 sound IRQs. Nonzero PCM remains zero at this early no-input point; no full attract or gameplay pass claimed. It is frozen before this high-score-only candidate.

- High-score pipeline regression completed: 867,529 checks, zero failures; restore/extract/upload of all 75 bytes passed with delayed pause and byte-lane isolation. Analysis/synthesis passed, 0 errors, 5m04s. Fit/STA is active as session 21008; closure remains pending.
- Preserved 2P run completed 6.24 billion clocks/3,600 frames with 3,601 V30 IRQs and 2,667,046 nonzero sound samples. Continued native state into hud-combat2p-7200 (session 52302, target 12.48 billion clocks); exact historical input prefix is preserved, with new physical controller events only after cutover. This frozen older model is exploratory progression evidence, not current acceptance.

### 2026-10-05 — SDRAM pin timing investigation

- Constraint review found active SDRAM pins unconstrained; generated-clock and input/output delay work is required before closure.
- A bounded pin-level test of the real production controller reproduced a late sample outside the CAS3, burst1 valid window (expected 0x4321, poison 0xdead). An isolated candidate captures DQ on the falling fabric edge, then keeps the existing READY/ack commit. The same test passed 128 reads and 64 masked writes on all four ports. Synthetic memory bytes are only controller test data, not a game model or substituted CPU/ROM.
- Candidate RTL and interface constraints are staged under sim/results/sdram-half-candidate; production RTL is unchanged while high-score fit session 21008 runs. Representative ISSI timing assumptions are explicit in docs/evidence/sdram-read-phase.json; no external-I/O closure claim yet.
- New IRQ/audio model cold runs are active: irq-half-combat2p-3600 session 9585 (actual reset seed cycle64), irq-half-combat4p-3600 session 6841 (cold four-player reset). Both preserve binary ba2457... and mark the high-score-only worktree drift. No gameplay pass yet.

- Passive historical witnesses: 2P advanced naturally from first garage into the next street (frame3360, scores21790/10880) and continued fighting through terminal frame3600. 4P frame3180 displays scores P1=0, P2=5950, P3=5010, P4=4230; all-four individual scoring in this cabinet is still open. No-input attract returned to title at3420 then entered forest at3900, with sound activity resuming. Full sequence repetition, natural boss/stage clear and ending remain open. Exact frozen-model identities and evidence hashes are recorded in docs/evidence/historical-natural-progression.json.

- Pristine MAME 0.289 zeroteam completed the same 4P input schedule at frame3180, exit0/CORE_CAPTURE_OK (session55304). It displays scores5010/210/0/2500 and timer54; RTL displays0/5950/5010/4230 and timer54. Both show the first garage area. A zero-score player can occur with this schedule, but player slot and score differences remain unresolved; no exact gameplay match or input mapping diagnosis is claimed.

- High-score candidate full physical run21008 completed: map PASS 5m04s, fit PASS 29m20s/0 errors; STA native exit0 but workflow exit1. Core setup -1.657 ns (FM rhythm/gain to accumulator), HDMI setup -0.158 ns. Resources28,708 ALMs/30,269 regs/369 RAM blocks/50 DSP. Exact reports preserved under sim/results/timing/highscore-*. No closure or RBF claim.
- Isolated FM candidate registers the rhythm/gain result before the accumulator carry chain. Actual target gains are constant unity. Full 96M-clock baseline/candidate audio PCM comparison is running as86617 before any production audio change.

### 2026-10-05 — Combined FM and SDRAM physical timing candidate

- Actual 96M-clock audio baseline/candidate comparison86617 completed exit0: PCM is byte-identical. Both have400,922 Z80 fetches/180 sound IRQs/873 FM writes/49,716 samples/32,782 nonzero samples. Applied the tested gain-result register before the FM accumulator carry chain; fast MMR paths remain single-cycle. This fixture pass does not claim complete in-game sound.
- Applied tested falling-edge SDRAM DQ capture, preserving the original READY/ack cycle. Added inverted forwarded-clock and bounded input/output delays, with no SDRAM input multicycle, plus input-I/O register placement assignment. Both production changes require fresh map/fit/STA; no closure claim yet. Exact evidence is in docs/evidence/fm-gain-timing-pipeline.json and sdram-read-phase.json.

- Incorporated production SDRAM source passed the same pin-window regression (128 reads/64 masked writes). New combined map/fit/STA10645 is active; no RBF/assembler. Audio comparison helper reconstructs the tested baseline/candidate after incorporation; Verilog text equality was verified after line-ending normalization. The initial byte comparison rejected Windows CRLF conversion, not an RTL difference.

- Combined map10645 passed (0 errors,3m56s), but reported INPUT_REGISTER assignment with invalid literal node {SDRAM_DQ[*]}. Corrected to the QSF quoted vector syntax. The first sandboxed stop was denied; a new map briefly overlapped. Escalated process control then stopped verified ZeroTeam fitter53708, map53440 and their descendants. Both10645/70164 are terminal exit1; independent projects were untouched. The new full physical run must validate the corrected assignment; no closure claim.

- Timing workflow now holds an exclusive project lock, rechecks the complete source/constraint identity before and after each native stage, and rejects ignored input/output register assignments. The lock rejection test passed without launching Quartus or altering existing timing evidence. Starting one clean full run after the aborted overlap.

- Clean physical run4065 passed map (0 errors,6m07s), with the corrected quoted SDRAM input-register assignment accepted; fit/STA is active. Current source snapshots include all constraints and are checked at each stage boundary.
- IRQ/audio lineage reset-derived run82786 completed exit0 at1.04B clocks/599 completed frames/600 IRQs and the actual USA title; it continues natively as irq-half-attract-4800/session38540 toward8.32B clocks. Its pre-FM-pipeline model remains explicit.
- AV source stamps now conservatively include all RTL .svh/.vh headers and .hex/.mif/.mem initializers, closing the previously identified future-stamp dependency gap. Older checkpoint stamps remain unchanged. Freezing/building timing-pipes-model from current source for subsequent current-model cold runs.

2026-10-05 | Complete AV source identity and current cold runs | Current immutable timing-pipes-model built successfully with 102 hashed compilation/header/table inputs; actual binary SHA256 aa17f4cd456be0fe0b8ae9f12b340e04d9699164c1c57da9d97941ad2a5c6acb matches its stamp. Explicitly includes target platform header, V30 headers and ucrom/ucdecode tables; historical stamps are not retroactively enlarged. Updated strict branch launcher to recognize the new dependency inventory while retaining existing legacy scope. Created genuine native reset state at cycle64 (68 clocks; expected progress-threshold exit1, not a boot pass). Started current attract session2452 through4800 frames, two-player18690 through7200, and cabinet-correct cold four-player16231 through7200. Strict launches accepted actual source/ROM/binary identity; no old-state conversion or forced load. See docs/evidence/timing-pipes-live-build.json. Historical four-player continuation40702 retains exact prior events and independent future attack cadence; historical two-player52302 and attract94623 remain diagnostic only. Current physical workflow4065 remains running after clean map PASS; closure is pending. QSF quoting lesson was appended once to canonical lessons and indexed. No assembler/RBF/hardware execution.

2026-10-05 | User requested final build and stop | Latest instruction explicitly authorizes an RBF now and ends further core work after that build. This changes the earlier simulation-first release schedule; full natural progression, ending, current-model gameplay/audio and MiSTer acceptance remain incomplete. Stopped exactly the six owned AV binaries after executable/hash checks. Retained historical complete native checkpoints: attract7696000000, two-player7384000000, four-player6344000000. Current timing-pipes cases had not completed their first periodic checkpoint; their frozen model and genuine reset seed remain, and no boot/gameplay pass is claimed. Earlier three IRQ-only runs were also stopped, retaining complete native checkpoints. No simulation remains authorized to continue after final assembly. Final build wrapper waits for existing clean workflow4065, verifies all recorded source hashes and current fit success, then assembles without rerunning map/fit. It records actual timing separately; an RBF alone does not establish timing or game acceptance. The automation tool is unavailable (transport closed on two attempts); marking the goal paused at the requested stop prevents its existing capacity heartbeat from resuming work.

2026-10-05 | Final requested RBF built; work stopped | Current clean workflow4065 completed: synthesis PASS; fit PASS, zero errors/five warnings, 39m16s, ended17:13:35. Native STA returned zero but the required timing gate correctly returned one: core setup -30.499ns, TNS -48480.262ns. HDMI setup +0.549ns and SDRAM setup +1.640ns; report still notes incomplete setup/hold constraint coverage. TIMING CLOSURE IS NOT ESTABLISHED. Preserved final reports/status under sim/results/timing/final-*. On the user's explicit instruction to build now and stop, assembled the exact verified current fit using Quartus17.0.2: zero errors/warnings, 31s, ended17:14:33. Created releases/ZeroTeam_20261005.rbf, 3,979,052 bytes, SHA256 314b89b5bb2cd8aa963ec19d2da1f1e9ef9a23264188f00fcda56060013ddd21. Build evidence: docs/evidence/final-rbf-build.json. This is a development artifact with failed timing, not a completed release. Full current-model attract/gameplay/progression/ending/audio and MiSTer hardware acceptance remain incomplete. All owned AV runs were stopped and completed checkpoints retained; no further RTL, simulation, build or hardware action is authorized by this stop instruction. Work is stopped at the user's explicit request. The pause API reported no goal for this thread; the capacity heartbeat must respect the explicit stop. Automation transport remained unavailable; its stored prompt already honors paused/cancelled goals. No MiSTer deployment or test and no push/publication.

2026-10-05 | Quartus database cleanup and stop | User requested stopping Quartus for this core only and deleting its build/incremental databases, with no new build. No core-owned Quartus process was active at cleanup; other projects remain unaffected. Verified absolute targets inside D:\Arcade\AI\aCORES\zero and absence of reparse points before recursively deleting db/ and incremental_db/ (qdb/ absent). Invalidated private active map-source.json and fit-source.json so old stages cannot authorize reuse of deleted databases. Verified database directories absent and no ZeroTeam Quartus task active. Preserved output_files reports/programming outputs, pinned source/donors, ROM staging, all simulation evidence/checkpoints, and releases/ZeroTeam_20261005.rbf; its SHA256 remains 314b89b5bb2cd8aa963ec19d2da1f1e9ef9a23264188f00fcda56060013ddd21. Next explicitly authorized build must start with fresh synthesis/fit. No build or hardware operation was run during this cleanup. Commit current records and the existing RBF, then stop.

2026-10-06 | Sort-DMA fix and MeatCore credits | (1) Z-sort DMA now sorts n=data+1 entries by the signed 32-bit key {word@+2,word@+0} (RAM-backed stable insertion sort, 128 entries); donor single-word key left every observed Zero Team call unsorted. Replay of 3,908 MAME-observed calls: 0 mismatches (docs/evidence/sort-dma-zeroteam.json). (2) MeatCore Credits overlay integrated from D:\Arcade\AI\aCORES\CREDITS: credits/ + credits.txt copied, credits/credits.qip added to files.qip, OSD action `R[120],Credits;` (status[120], previously unused), overlay on the native 320x256 stage (px_* signals) before arcade_video/crt_adjust/rotation, any-button dismissal from raw pad0-5/ps2_key[9]/ps2_mouse/buttons/OSD_STATUS. Names regenerated manually (`python credits/tools/generate.py --columns 48`, 32 names, 10,240 ROM bits); no preflow hook added. Checks: emu lint passes (scripts/lint_platform.py now includes credits sources); sim/run_credits_check.sh passes (closed pass-through 0 diffs, opens, closes on tap). Not fitted/timed or hardware tested yet; full Quartus compile is queued.

2026-10-07 | Audit against global lessons (CRT / direct video / overrun / sound) | Findings and fixes: (1) HBlank was folded with DE (px_hb=!pixel_display), so sys arcade_video (samples VBlank only on a falling HBlank edge) never saw VBlank: forced-scandoubler/VGA output produced 0 frames in the real sys chain (sim/run_video_chain.sh: OLD 0 frames, NEW 8 frames x 512 lines; 15 kHz path unchanged at 256 lines). HBlank now follows the raster during vblank (lesson: keep horizontal blank pulses during vertical blank). (2) CRT V-Position clamped to -4..+19 lines: raster front porch is 4 lines (picture ends 255, VS 260..262, 282 lines), so -5 or lower cut picture lines into retrace (lesson: crt_adjust V-shift). Checked OK: 15.625 kHz / 55.41 Hz raster equals MAME refresh (not a set_size raster), pixel divider 12 (even, integer, so direct video/scandoubler see uniform pixels), crt_adjust VTOTAL 282/HTOTAL 512 match the raster, H-Size range keeps >= 10 clk/pixel, DDR rotation FIFO with busy + overflow flag, reset cause includes PLL lock, audio enables run through reset, DIP bit ranges in the MRA are first,last, cabinet flip composes as crtc_flip^OSD 180. Not verified: worst-case CPU-vs-renderer SDRAM deadline (renderer overrun lesson) needs a loaded-bus bench; sound pause holds last sample (no DC-fade); OSD open still pauses the CPU when idle (hiscore design) - no hang seen in sim, not hardware-tested.

2026-10-08 | Hardware boot fix (root cause) | Hardware symptom: dim Seibu logo forever, coin sound alive, OSD fine. A DDR3 probe (since removed) showed the V30 derailed within ~15 frames (2 COP commands, 15 IRQs, spinning at ROM 0x924E0). Root cause: ZeroTeam_rom_bridge implemented the V30 ROM port as a toggle/level-ack protocol while Raiden2_main_top expects level request + one-clock ready pulse; every fetch triggered a phantom second read and the next fetch completed on a stale ack with old data once SDRAM latency exceeded the simulator's fixed 3 clocks. Repro: sim/board_main.cpp ZERO_ROM_JITTER=30 (3..33 clock latency) hung after 6 reads (IRQ=0); fixed bridge: IRQ=120, 4.0M reads at 208M cycles. Hardware after the fix (debug RBF): 1 IRQ per frame, >14k COP commands, game runs (user-confirmed on MiSTer). SDRAM clocking is the donor's proven scheme (clk inverted via DDIO, READY-edge capture); the earlier 225-degree/second-PLL-output experiment is reverted. Probe removed. A release RBF with closed timing is still to be built from this source.

2026-10-09 | Slowdown with many sprites (root cause) | Symptom: slight slow motion at the stage 1 car explosion and the stage 1 boss item shower. Cause: no program-ROM cache. Every V30 ROM read and every COP ROM read (C480/6880 sprite templates, B100/B900 hitboxes, CPU held by cop_cpu_stall) was a single-word SDRAM transaction (~11 clocks unloaded, longer behind the video-first arbiter that sprite load saturates) plus the 3-clock stall chain, against a 24-clock nominal bus cycle. The CE catch-up recovers only one CE per 30 clocks, so the V30 ran well below 16 MHz and lost more as sprite load grew; frames with the most work overran. The board sim's fixed 3-clock ROM model hid it. Fix: 8K-word direct-mapped I-cache inside Raiden2_main_top (hit releases the stall the clock after the read edge) and raiden2_rom_cache (4K words) on the COP ROM port; tags are swept during reset (ROM download holds reset). Evidence (sim/board_main.cpp ZERO_ROM_LATENCY): 30M-clock boot idle-loop CPU reads baseline 883k/738k/598k at latency 3/10/20, cached ~961k at all three, 99.4% hit. 300M clocks at latency 10 + jitter 20: both 173 IRQs, identical writes/video DMA/palette DMA/COP busy; SDRAM ROM reads 5.56M -> 15k. Pre-existing, unrelated: sim/run_platform_checks.sh fails "V30 falling toggle acknowledgement" (stale toggle-protocol expectation for the unchanged ROM bridge). No Quartus build or hardware test yet.
2026-10-09 | Sound-effect crackle fix | Root cause: JT6295 decodes the byte on its ROM bus ~750 clocks after an address change without waiting for rom_ok; OKI sample ROM (SDRAM port 3) was served last behind video, V30 and COP and starved, so stale bytes were decoded as ADPCM (pops). Contention bench with the JT6295 slot pattern: 1154/1154 late bytes before, 0 after (worst 46 clocks); frames unchanged. Also OKI output linearly interpolated onto the FM sample grid (alias error -18 -> -31 dB modelled). Timing repairs (ascal luminance compares, ascal sweep wrap registers, sprite lane-mux register) were needed because placement moved paths; contention bench frames identical. Release candidate releases/Arcade-ZeroTeam_20261009_rc3.rbf, 8-corner timing PASS. Not yet heard on hardware.
