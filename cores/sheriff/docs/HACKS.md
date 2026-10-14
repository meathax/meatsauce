# Limitations and approximations

Sheriff board RTL and MiSTer integration are implemented. Component and gameplay comparisons are recorded in `progress.md`; the complete simulation and release gates remain open. Other family profiles remain pending.

Known future qualification gaps are recorded in `mamebug.md` and `donormap.md`: a complete SN76477 model, HeliFire imperfect audio/graphics/cocktail behavior, Othello video HOLD/timing/input/sound ambiguity, Block Fever discrete sound/replay outputs, and incomplete 8085 donors. Downloading these references does not resolve them.

For each implementation approximation, append: affected set/block; observed behavior; exact source/evidence; implemented choice; focused check and result; remaining difference; what evidence/change would close it. No blank or generic exemption may be used to bypass the simulation gate.
# Verified reference-capture correction (2026-10-09)

## Whole-frame redraw versus live scanout

After correcting the Lua buffer phase, frame 1500 has seven whole-frame-reference differences at X128-130/Y131-135. MAME's timed writes update those rows at raster Y139-151, **after** they have been displayed. `sim/results/gameplay-v2/first_live_scanout_difference.json` preserves the exact positions and transaction times. An independent oracle consuming only MAME's timed RAM/control writes and the real color PROM matches all 34 captured live FPGA frames with zero pixels different (`streaming_comparison.json`). No frame latch or rendering workaround was added to RTL. The functional streaming reference does not establish undocumented physical DRAM fetch/arbitration subtleties; retain that hardware assumption explicitly.


MAME 0.289 `screen:pixels()`/`pixel()` read the **drawing** buffer `m_bitmap[m_curbitmap]`, rather than the displayed texture buffer. `screen_device::update_quads()` selects `m_curtexture=m_curbitmap` and advances `m_curbitmap` when a changed frame is published. At `emu.register_frame_done` that exposes an older bitmap in this capture path. The initial gameplay comparison consequently reported 13 pixels at frame 960, 92 at frame 1020 and 99 at frame 1380 although the same-time MAME RAM rendered exactly like the live FPGA pixels.

The independent adjacent-callback probe under `sim/results/pixel-phase-probe/` proves the phase: MAME callback +1 has zero mismatches for those same frames, while offsets -1/0 fail. The canonical capture now saves RAM/state at the requested frame and pairs native RGB from the following callback, recording both times in `.meta`. FPGA raster, graphics and CPU behavior are unchanged. This is a host capture correction, **not** a hardware fix or a blanket MAME mismatch waiver. Original captures remain recoverable. Exact source: `D:/Arcade/AI/mame289/src/emu/screen.cpp` (`pixel`, `pixels`, `update_quads`), `screen.h` (`curbitmap`) and `src/frontend/mame/luaengine.cpp` (`pixels`, frame-done binding).
## Initial CPU/raster epoch

The physical two-phase CPU starts its first T1 phi1 43 master clocks after the
current harness releases RESET: first SYNC is tick 56 and first opcode DBIN is
tick 81. MAME dispatches its first instruction at emulated time zero. Starting
the raster immediately on RESET release therefore gives these references
different CPU phases at the same IRQ edge. A trial aligning the initial raster
to the first CPU T1 matched all six checkpoint images and I/O outputs in the
70-frame probe, but introduced 16 RAM-write differences starting at index
21,026, earlier than the baseline's two differences at index 23,193. That
trial was rejected and the original synthesizable raster startup retained.
`sim/results/irq-66-aligned-rtl/` preserves the failed experiment, and
`cpu_startup.csv` retains the raw reset-relative waveform. Current trace times
remain relative to RESET release. Original PCB power-on phase is unknown;
neither an arbitrary phase adjustment nor a stack-byte waiver qualifies IRQs.

Further 30- and 29-tick epoch trials also fail: the 30-tick trial gives the
same 16 early stack differences; the 29-tick trial moves the first difference
to frame 58 (write 22,648), returning to 0x0fef instead of 0x0ff3. Both pass
the six image/RAM checkpoints and 502 output values, so those checkpoints
alone cannot qualify interrupt timing. All startup alignment experiments
were removed from production. The exact source patches and immutable ELF
builds remain under `sim/results/irq-{epoch,tie}-rtl/` and corresponding
`sim/build/irq-{epoch,tie}/`. Frame-26 program/bus evidence is preserved in
`sim/results/irq-26-{mame,trial-rtl}/`; the physical bus and the reference's
instruction-atomic timing must be resolved rather than tuned by a constant.

## CRT enlargement viewport

The +4 H-Size setting emits source samples every 11 master clocks while the
native line remains 3,200 clocks. Content is enlarged from its native anchor;
the last 13 source pixels exceed the read window and are clipped at HSync.
The qualified image contains 224 rows of the exact first 243 source samples,
54,432 active samples per frame. Shrinking retains all 256 source samples.
Read-bank switching resets the read counter and flushes active metadata on
the same edge; HSync follows the synchronous RGB pipeline. This prevents
mixed rows and spurious row fragments without altering the native raster.

## CPU phase contract and paused RAM service

The staged Interact integration drives complementary phase levels into
vm80a, rather than one-master-clock pulses. The board now uses phase 0..11
for phi1 and 12..24 for phi2: one 50.4 MHz master clock, 2.016 MHz T states.
The focused donor fixture retains 13-T-state LDA cadence in both modes,
but sustained levels retain the donor's full interrupt sampling aperture.
This establishes the phase contract, not complete Sheriff IRQ qualification.

Setting both phases low did not freeze every donor latch. Its DBIN data
latch and extended read-data enable update on the master clock independently
of those phases. Borrowing RAM for the frame-60 snapshot changed the saved
accumulator from 5 to 0, producing 33 extra CPU writes and 28 wrong frame-70
pixels. Restoring the RAM address alone, or holding only input data, failed
the same replay. These failed experiments remain under
`sim/results/service-{resume,latch}-rtl/`.

`tools/generate_vm80a_ce.py` verifies the pristine donor's SHA256 with LF
line endings and generates `rtl/n8080_vm80a_ce.v`. It adds a shared enable
to all 16 synchronous blocks and to the non-reset branch of the existing
asynchronous-reset block. Instruction/ALU logic and original reset priority
remain intact; the pristine vendor file and CC-BY notice are retained.
The wrapper freezes phase and bus-edge history together. A two-clock board
guard restores the registered CPU RAM port when pause and request fall
together. Snapshot bookkeeping returns that port before releasing its
explicit raster freeze, consuming no emulated time.

All 75 read/service cases pass (25 master-clock offsets, three borrowed
bytes). A pair of 70-frame replays from the same ELF matches all CPU writes,
I/O, sound pins, audio and six native images byte for byte. The unpaused run
also matches the prior unadapted phase-level baseline; that comparison is
behavioral preservation across two RTL versions, not same-source identity.
The matching MAME capture is `sim/results/irq-66-mame/`: all six RAM/image
checkpoints, 502 outputs and six timed native images match. Two historical
interrupt-stack writes at 0x7ffc remain different; this fix does not waive
them or claim the full simulation gate. Evidence:
`docs/evidence/sheriff_pause_phase.json`.

The subsequent two-corner diagnostic establishes the MAME scheduling
precision effect, MB-18. At the vblank IRQ of frame 58 and mid-screen IRQ
of frame 61, integer CPU/pixel clock periods leave a sub-cycle scheduler
residue. MAME begins RST at its older local instruction boundary, one
T state before the raster request. ANA's last physical phi2 aperture has
already ended; the board completes the following JNZ before RST. The ISA,
clock epoch and local ROM branch target independently predict both stack
write times and the actual return PC. Exact evidence is retained in
`docs/evidence/sheriff_irq_scheduler_corners.json`; the original strict
memory report still fails visibly on those two bytes. This qualifies only
those measured corners, not all IRQ phases or full-game timing.
## Integrated DAC polarity/range (2026-10-09)

The Sheriff `DAC_1BIT` is unipolar. MAME 0.289 `src/devices/sound/dac.cpp` sets `m_range_min=0.0` for one-bit DACs and `m_range_max=1.0`; `n8080_a.cpp` routes it at 0.15. `n8080_board.sv` therefore adds 0 or +4915 to the SN76477 sample. A centred -4915/+4915 contribution was a local integration bug. Twelve settled intervals from actual coin/start sound-ROM execution now match the reference exactly. Connected latch values match over 1244 events; measured event timing offsets are retained. This correction does not establish every sound class, analog calibration or the complete sound gate. See `docs/evidence/sheriff_integrated_dac.json`.

## Physical video serializer still unqualified (2026-10-09)

Sheriff TWG-1 parts drawings confirm a video 198 at I/O 1L. The related Bandido schematic connects its parallel input to the DRAM read bus and uses QA/QH for video. Current board RTL instead refreshes bitmap_q continuously and selects its bit at each pixel; the independent timed-write oracle shares that functional assumption. Frame-6780's native write occurs within its eight-pixel interval, so physical byte holding may affect this corner. Load/shift phase, read-latch timing, flip direction, visible origin and CPU-visible arbitration are not yet derived. `docs/HARDWARE_VIDEO.md` and `docs/evidence/sheriff_video_primary_sources.json` retain sources, classification and the focused closure steps. No speculative RTL change or mismatch waiver has been made.
