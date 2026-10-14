# VRender0 audio implementation

`rtl/audio/vr0_voice.sv` is a synthesizable sample-fetch and voice-arithmetic pipeline for the future 32-channel SPU scheduler. It reads samples through the aligned board bus from the actual texture (`0x03800000`) or framebuffer (`0x04000000`) regions. It holds requests and results under backpressure and reports memory errors. No host software supplies production samples or executes the voice arithmetic.

Implemented voice behavior follows the pinned [MAME 0.289 VRender0 sound source](https://github.com/mamedev/mame/blob/mame0289/src/devices/sound/vrender0.cpp): exact 256-entry vendor-game-derived µ-law table; signed linear 8/16-bit decode; fractional sample address and pitch update; address wrapping; loop/end boundary; envelope volume and stage cascade; and left/right gains. The gains use the volume before that sample's envelope update. An ending non-looping voice produces no contribution on that sample, matching the reference. The wrapper must implement MAME's corresponding early termination of the remaining voice scan.

The test oracle retains three original function bodies unchanged: channel register read, channel register write and complete `render_audio`. Its memory adapter reads the fixture bytes; its stream adapter retains the **unclamped signed contributions**. Integer products wrap at 32 bits before signed shifts. The oracle is compiled with `-fwrapv` so these edge cases have a defined comparison contract. This is a reference arithmetic contract, not proof of undocumented silicon overflow behavior.

`python -X utf8 scripts/sim.py voice` exits **0**: **14,420 differential jobs**, **452,920 checks**, **14,420 coherent reads**, **260,625 clocks**. Checks cover every µ-law and signed-byte value, every byte lane, linear-halfword boundaries, all reference clock-divisor inputs, pitch/address overflow, loop/end, positive/negative envelope rates and cascades, pan, delayed responses, request/result stalls, memory faults and reset. The worst isolated job takes **25 clocks** in this test. This is not a shared-memory deadline or full 32-channel throughput proof.

## Real game fixture

The earlier 3,600-frame P1/P2 reference places the first active sound assignment at frame **901**, following P1's coin. A new bounded native capture reaches frame **960** and saves both 8 MiB sample-memory regions and all channel registers **before that assignment**. The pending status write is recorded separately. The fixture does not run a software voice in the RTL model.

The first assignment enables channel **4** at PC `0x02088f1e`: status command `0x8004`, control `0x8000`, channel-clock count **29**, current address `0xa0000000`, µ-law mode `0x10`, framebuffer source. The active channel's captured registers are decoded through the unchanged MAME channel-write body and submitted to the genuine RTL pipeline. Its returned address/envelope/gains match the independent oracle using the captured memory bytes. Evidence: `docs/mame_audio_fixture.json`, `docs/spu_reference.json`, `docs/simulation_voice.json`. Raw ROM-derived memory, register fixtures and WAV remain ignored under `sim/obj_dir/`.

The native capture's stereo WAV has peak **3,592** and **93,958** nonzero samples. These are **MAME reference results**, not RTL audio or gameplay acceptance. The voice test has not generated complete music, SFX streams or a full-board WAV.

## Required next work

- Implement the complete channel/global MMIO layer, simultaneous halfword/byte writes, note/status semantics, 32-channel scheduling, end/loop/IRQ updates, mixing/clamping and fixed sample cadence. Integrate the voice memory client with CPU/DMA/GPU/scanout arbitration.
- Resolve the source's global high-bank discrepancy: register comments describe channels 16–31, but status/note/mask/pending methods shift their second half by **4**, rather than 16. The real P1/P2 trace uses upper channel numbers and reads the full 32-bit status word, so this is material. Preserve this conflict explicitly; an unquestioned copied bank implementation is not physical evidence.
- MAME does not implement reverb, sustain/note-off, ping-pong/reversed loop, most global controls or verified hardware envelope/IRQ timing. The pipeline reports sustain/ping-pong mode bits as unsupported; it does not invent these effects. The inspected P1/P2 trace programs µ-law/linear-16 modes and no reverb control, but full-game/service coverage remains necessary.
- MAME's pitch multiplier algorithm and sound-clock/972 rate are explicitly unverified. The planned system-clock cadence is 1,944 clocks per sample; the scheduler and actual game audio timing remain to be tested. The voice has no interpolation because the pinned source performs direct sample lookup.
- Listen to genuine RTL-generated attract/gameplay output after integration, compare the necessary PCM/state boundaries and prove deadlines with realistic shared-memory contention. Resolve any remaining exercised functionality before declaring the simulation gate complete.

The CPU still stops at unresolved `MVTC R0,CR5`; attract, normal P1/P2 gameplay and working sound in the integrated RTL remain pending. This component milestone does not change that gate.

## 2026-10-05 — 32-channel SPU scheduling and complete first-coin playback

Added synthesizable `rtl/audio/vr0_spu.sv`: all 32 channel banks with byte writes, global status/note/mask/pending registers, inclusive maximum-channel scheduling, programmable pitch divider ROM, frame/texture memory selection, 32-bit stereo summing and signed 16-bit clipping, end interrupts/W1C, constant sample cadence, and sticky RAM/deadline diagnostics. One `vr0_voice` serves every channel. MMIO waits during a sample scan; audio output has one sample of pipeline latency.

`python -X utf8 scripts/sim.py spu` passed: 8,192 randomized channel register writes compared against unchanged MAME channel methods, four 1,024-frame full 32-voice mixes (8-bit/16-bit/ulaw, texture selection and clipping), channel-end scan termination and masked IRQs including channels 20/31, and all 65,373 frames of the native first-coin fixture through actual shutdown. Delayed reads (1–11 clocks plus request backpressure) gave a maximum 530-clock scheduler/MMIO stall against a 1,944-clock sample period. Deliberately 2,400-clock-delayed memory triggered underrun; RAM faults and reset diagnostics passed. Result: `docs/simulation_spu.json`, 196,450 coherent reads, 135,085,499 simulated clocks.

Limits: SPU is not yet connected to the cold-boot board, shared CPU/DMA/GPU memory arbiter or final MiSTer wrapper. This is component/fixture evidence, not RTL attract/gameplay/music completion. Global high-bank layout is physically unresolved: BANK_SHIFT=16 follows source register comments; BANK_SHIFT=4 is diagnostic for the conflicting source implementation and was not validated this turn. MAME sound clock/972 remains an uncertain physical divider; the chosen board clock uses 1,944 system clocks per output sample. Reverb, sustain and pingpong remain incomplete and exposed as unsupported. No RBF was built. CPU cold boot still halts at MVTC R0,CR5 (020820c4/fc65); no bypass was added.

### 2026-10-05 — SPU board connection and four-client arbitration

Connected the synthesizable SPU to `cs_boot_probe`: sound window 04800000–04800fff uses internal MMIO with a registered reply; sample reads use shared-memory client 3, alongside CPU/DMA/GPU clients 0/1/2; signed stereo samples and memory/deadline/unsupported diagnostics reach the board outputs. Sound end requests produce one-clock event pulses into SoC interrupt 2, matching the pinned vrender0.cpp soundirq callback; the SPU pending-register IRQ level remains separately visible internally. Event pulses prevent a retained sound pending bit from continually recreating an already-acknowledged SoC event.

Changed-path verification: `scripts/sim.py arbiter4` passed 256 contended requests, 64/client, with delayed replies, fair ownership, ready stalls and error routing. `scripts/sim.py spu` passed the previous complete voice/MMIO/mix/coin workload plus explicit masked/unmasked sound-event counts and one-clock pulse width. `scripts/sim.py boot_probe` compiled and ran the integrated board against actual staged BIOS/cartridge data and the independent CPU reference: 8,233,974 matched instructions, 154,545,349 clocks, 10,736,151 CPU memory requests, 79,498 silent audio samples, no sound fault/underrun. It still exits **1** at the unresolved original MVTC R0,CR5 at 020820c4/fc65. This is preserved partial boot evidence, not a passing full-boot gate.

Coverage limits: boot reached zero sound MMIO accesses and zero SPU/GPU/DMA memory requests, so the real firmware did not yet exercise active sound or mixed-client bandwidth. The four-client arbiter test proves routing/fairness but not a full-board simultaneous workload or SDRAM refresh/turnaround deadlines. Next: execute genuine CPU-driven sound MMIO and interrupt handling in a diagnostic BIOS fixture, then active shared-bus contention; retain the real cold-boot MVTC investigation and complete game GPU replay/scanout. BANK_SHIFT physical ambiguity and unimplemented sound modes remain open. No RBF/Quartus/hardware run.

### 2026-10-05 — Reset-driven CPU/SPU/IRQ integration diagnostic

Added `scripts/sim.py bios_sound`: the unchanged board RTL boots a generated test BIOS from the normal reset vector. SE3208 instructions establish the stack, write sample bytes through the shared board RAM path, configure sound channels 0 and 31 through actual MMIO, enable SoC IRQ2 and CPU interrupts, and execute a real ISR that reads sound/SoC pending, W1C-clears sound pending, acknowledges INTVEC, increments a work-RAM counter, and restores GPR/ER/SR/PC. No RTL state-load or post-boot game state is injected. A separate C++ translation unit runs the unchanged pinned MAME channel/render methods to predict every output sample with deliberately distinct stereo values.

`python -X utf8 scripts/sim.py bios_sound` **PASS**: 3,035 instructions matched the independent CPU reference; 26 sound MMIO accesses; 8 genuine SPU shared-bus sample reads; 24 checked output frames after sound start; 2 IRQ2 entries/returns for low/high-bank voice ends; restored SP=021ff000, ENI enabled and idle-loop retirement; CPU-written RAM logs prove SoC status=4 and high-bank sound pending=80000000. No audio memory fault or deadline miss with randomized memory acceptance/backpressure and 1–7-cycle delayed replies. This now exercises the sound MMIO and interrupt connections that original game boot has not reached.

The independent audio comparison first caught two errors in the *test BIOS*, corrected before PASS: a 32-bit status-command write also executed the adjacent halfword command and switched voice0 off; format flags belong in bits 14:8 of the mode halfword (bits 30:24 of the packed DSAddr/Mode word). Command writes now use genuine STS halfword instructions, and mode packing selects signed 8-bit samples correctly. No production RTL behavior was changed for this test.

Limits: this is a small generated diagnostic BIOS, not original-game cold boot, attract, gameplay or music. DMA/GPU were present but idle; no SDRAM refresh/turnaround or worst-game mixed-client load is proven. Global sound bank-layout physical ambiguity remains. Original game execution remains stopped at 020820c4/fc65; that fault is not bypassed. Next: active shared-memory contention and real-game GPU replay/scanout, alongside the SE3208 control-register investigation. No RBF build or hardware run.

## 2026-10-06 — Real-game sound feature usage (MAME `crysking`) and the "no intro sound" report

Instrumentation: `scripts/mame_sound_usage.lua` (tap on the sound window 0x04800000-0x04800fff; logs every global-register access, every channel mode-word write, a full channel snapshot at every status-on, and per-frame which channels' `cur_saddr` advance), driven by `scripts/mame_sound_usage.py` (`run`/`report`; inputs from `scripts/mame_sound_usage_inputs.py`). Summary: `docs/mame_sound_usage.json`; raw CSV/WAV/PNG stay private under `sim/obj_dir/sound_usage/`. MAME 0.289, `-video none -sound none -wavwrite`, native 48 kHz WAV.

### Root cause of "complete lack of sound during the introduction"

It is **game-side, not a MAME emulation gap.** On blank NVRAM (crysking has no NVRAM dump in MAME) the game's factory default is **Demo Sound = WITHOUT** (service menu, hold Service Mode > CABINET DIP SET UP > DEMO SOUND; there is no hardware DIP for it). Evidence:

| run | setup | result |
|---|---|---|
| `run2` | blank NVRAM, no input, 12,000 frames (BrezzaSoft logo, story intro 1000-6000, title, demo play, ranking) | **0 note-on events**, 98 status-off (init only), WAV 199.8 s **peak 0 / 0 nonzero samples** |
| `run_attract` | same NVRAM with Demo Sound = WITH (set via service menu, scripted), 13,000 frames | 425 note-ons from frame **640**; WAV 216.5 s, peak 27,128; music/narration through frame ~10,500, silent again during ranking (frames 11,000-13,000) |

Sound hardware is enabled (CTRL RS=0x8000 at frame 32) in both; the game simply never starts a voice in attract with the option off. First coin (frame 900) starts SFX regardless. A reviewer on a fresh MAME install hears nothing in attract/story; setting Demo Sound to WITH restores it. MAME's `MACHINE_IMPERFECT_SOUND` flag is unrelated to this.

### Usage table (what the game actually programs)

Runs: `run_attract` (13,000 frames, no input), `run_play` (40,000 frames: attract, coin 900, P1 start, pseudo-random P1 joystick/A/B/C mashing, periodic coin/continue and P2 join at frame 5000+6000k; seeded, reproducible; reaches stage 1 with 1-2 players only), `run1` (4,000 frames), `run2` (above).

| item | observed (run_play, 40,000 frames) |
|---|---|
| status-on (note) events | 5,641; mode word 0x1000 (u-law, frame memory, no loop) 5,315 from frame 901 at PC 0x020889c4 (the only SFX mode-write site seen); mode word 0x0000 (signed 16-bit, frame memory, no loop) 326 from frame 640 at PC 0x0208c29c (music/narration streams, ds_addr 0x00c2/0x00b9, channels 0/1) |
| LOOP / SUSTAIN / ENVELOPE / PINGPONG / 8-bit / TEXTURE bits | **0 / 0 / 0 / 0 / 0 / 0** (every voice runs once to loop_end; the game re-triggers music itself, e.g. channels 0/1 re-triggered 102 times) |
| envelope rates 0-3, targets 0-3, env stage | all zero at every note-on; env_vol 0x7f0000 (full), pan 127/127 (SFX) or 63/48 (music) |
| reverb: RevFactor 0x410, BufferSAddr 0x412, BufferSize0-3 0x420/422/440/442 | only the boot clear to 0 (2 writes each) |
| CTRL 0x602 | 0x0000 x5 (boot), 0x8000 x2; **RE/AW/MW/CW/TM never set** |
| CHNNUM 0x600 | 0x1f00, 0x1fff, 0x1f1d (max channel 31, clock number 29) |
| IntMask 0x480/482, IntPend 0x500/502 | boot: mask 0xffff (all masked) then pend cleared; **no channel interrupt ever enabled, no pend write afterwards** |
| channels used | 0,1,4-31 (SFX pool 4-15 round-robin with ~2% retrigger; 16-27 only 3-14 uses each; 28 (565 uses, 55% retrigger) and 29 (94) dedicated) |
| status reads | 11,820 full-32-bit reads of 0x404/0x406 (pairs); notes via status write 0x404 with bit 15 (6,109 writes) |
| noteon 0x408 writes | 33 (all at boot init) |

Conclusion: **the game uses none of MAME's unimplemented features** (sustain, ping-pong, reverb, adder/multiplier waits, envelopes, channel IRQs) in the exercised paths. MAME output for these paths is therefore expected to be functionally right (modulo sample-rate divider uncertainty below). No RTL behavior change was made; the `unsupported_modes`/`unsupported_reverb` diagnostics stay (nothing was implemented) and now have game evidence that they should remain zero. `python -X utf8 scripts/mame_sound_usage.py report <runs>` exits 1 if any recorded run uses one of them.

### Datasheet / sources

No public VRender0 datasheet was found (searched web and the MES Digital product page; archive.org copy of mesdigital.com not retrievable). Available: [MAME vrender0.cpp (0.289, same as master)](https://github.com/mamedev/mame/blob/mame0289/src/devices/sound/vrender0.cpp), [Arcade Database vr0sound](https://arcade.vastheman.com/minimaws/machine/vr0sound), [MES Digital VRender0 board listing](https://mesdigital.en.ec21.com/VRender0_B_d--269545_269546.html) (only "32-channel 16-bit wavetable synthesizer"). Reverb/ping-pong/sustain/envelope-rate semantics therefore have **no hardware evidence**; implementing them would be invention and was deliberately not done.

### Unresolved

- Coverage: stage 1 only, 1-2 players; later stages, bosses, ending, continue/name entry/ranking and the service-menu sound test were not played. Statistical evidence is strong (all 5,641 mode writes come from two PCs with two constants) but not a static proof; a ROM-wide scan for other mode-write sites has not been done. Re-run `mame_sound_usage.py report` on longer play to extend.
- MAME's status read of the high half is `m_status >> 4` (not 16): the game's 32-bit read of 0x404 sees channels 4-19 duplicated and never sees 20-31. The game's observed channel pattern (16-27 rarely used, 28/29 dedicated) does not show obvious breakage, so the choice of BANK_SHIFT stays open; nothing in these runs resolves it.
- Sample rate (clock/972) and the `(30<<16|0x8000)/(clknum+1)` pitch scaler remain unverified; the game uses clock number 29 only.
