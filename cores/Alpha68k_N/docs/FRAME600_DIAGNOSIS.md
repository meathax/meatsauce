# Kyros frame 600: state difference, not a strip decoder failure

This is an offline diagnostic of the completed 600-field CPU/video run at
source `7c269ba`, with executable SHA-256
`e89d565ce4765b1df6752f27b9322b7ca35f37228a34df3bf205473b3268cf2c`.
It does not establish live frame alignment or whole-game MAME equivalence.

The canonical displayed MAME image and native RGB differ at 458 pixels,
entirely within native X88..95/Y57..198. These are the GET READY PLAYER 1
letters, rather than displaced scenery or a different player position.
The terminal strip snapshots differ at exactly 18 words, indices
`0x70e..0x71f`; every XOR is `0x4000`. The character codes match.

Running the existing real isolated RTL renderer and its independent
MAME-structure software renderer on each snapshot gives zero mismatches.
The RTL-state snapshot reproduces the live RTL image exactly; the MAME-state
snapshot reproduces the displayed MAME image exactly. No render deadline or
row overflow occurs. These results localize this finding to differing game
state and do not justify changing graphic-ROM decoding or color mapping.

Work RAM differs at 31 words. In particular, word `0x020000` is `0x021c` in
the native capture and `0x021d` in MAME. The original MAME event recording
contains the corresponding counter writes and distinguishes its recorder
frame from the screen frame. Reset raster origin, recorder epoch, interrupt
delivery and CPU startup timing still require causal alignment. Do not shift
image labels, suppress the text, mask differing pixels or retime the CPU to
turn this diagnostic into a pass.

Evidence: `research/kyros_frame600_state.json` binds both image/RAM snapshots,
the fixture executable and its two terminal results. The narrower pixel
geometry is in `research/kyros_frame600_diagnosis.json`.
`research/kyros_mame_counter_events.json` extracts the existing MAME work
counter events; its recording windows contain gaps. The new combined native
harness records every relevant counter/message-strip write and interrupt
acknowledgment in `epoch_events.csv`, without the general bus-log sample cap.
This is the next source of evidence for the alignment investigation.

## Reset and recording epoch evidence

A fresh four-callback run of the pinned official MAME binary records callback
0 at 0.016896 s, beam (240,0), screen frame 0; subsequent callbacks occur at
exact full-field intervals. It uses the same frame notifier and startup
options as the original recorder. See research/mame_origin_trace.json and
sim/mame/trace_origin.lua; the script only observes time/beam/PC.

The native board reset to beam (0,0), giving a shorter first field, while its
harness numbered the first completed image 1. The full selected native
causal stream confirms the first work-counter writes at lines 104 and 128,
where the original MAME stream records lines 80 and 104: exactly 24 lines
apart. Each raw line is 64 us, so the reset phase differs by 1.536 ms.
This is independent evidence from counter writes, rather than image matching.

The board reset now uses (240,0) and the harness labels completed fields
0..N-1, applying inputs after that same label as capture.lua does. CPU clock
rates, IRQ periods, bitplanes, palette tables and visible bounds are unchanged.
This adopts MAME's reset epoch; physical PCB power-on raster phase remains
unmeasured. The corrected native startup matches MAME, but that correction
alone leaves the same 458-pixel frame-600 difference; it is not a closure.
The earlier audio1800 run is deliberately cancelled with its source/evidence
preserved because it had the old epoch; it is not an acceptance pass.

## Observed input ports, rather than queued input requests

The corrected-epoch executable eabf3b99703bcfa09c46fcc73ccf8fa0c5f792d38df26de772d9b87decc6a60a
still applied the coin request after field 120. In MAME, capture.lua calls
field:set_value at that callback, but the input manager commits the port on
its next frame update: frame_states.csv first observes the active coin at
121 and the active start button at 161. The old harness therefore presented
both inputs one field early. Its main sound command 0x72 reached field 121,
whereas MAME records field 122. This changed the second DPCM stream's state;
the first control-RAM mismatch and first DAC mismatch follow that command.

The harness now accepts --inputs frame_states.csv and applies those actual
IN0/IN1/IN2 values at the matching completed-field callback. It records every
applied value, without changing game clocks or comparing shifted images.
The diagnostic build e161405f3f99f967a512fdcf0702e8aa2da18c4dd53127801078797cbcd88aa1
completed 130 fields with command 0x72 in field 122. All 131 applied-port
records match their source rows; all 12,734 selected sound-control RAM
writes and all 3,711 DAC writes match MAME in field, address and value/order.
This is a finite causal diagnostic, not a claim of phase-identical PCM or
whole-game equivalence. See research/kyros_portreplay_probe.json and
research/system_portreplay_coin_gate.json.

The incorrect-input corrected-epoch long run was deliberately cancelled
(exit 15), preserving research/system_epoch1800_cancelled.json and its
terminal receipt. The canonical-port 1800-field run uses the same successful
probe executable and source manifest, with recovery in
research/system_portreplay1800_started.json and
research/system_portreplay_inputs.sha256. Frame 600 and all later graphics,
gameplay and audio gates remain open until its actual results are examined.

## Frame-600 checkpoint closure

The canonical-port run has now reached field 600 with complete pixel coverage
and zero deadline misses. Its frame_000600.rgb is byte-exact to MAME's
canonical frame_000600.display.rgb: 0 differing pixels, both SHA-256
870367cea2cc090698af979491e7a9c75e56ca3048a484753ad11186728f9bc8.
All six available canonical checkpoints (0,30,90,240,360,600) also match
without offsets or masks. See research/kyros_portreplay_graphics_partial.json.

This closes the specific GET READY image difference under the shared reset
epoch and observed-port input contract. The run uses the already pinned
e161405f executable; no renderer or CPU-clock changes were needed. Its later
checkpoints and terminal gameplay/audio evidence remain pending. This finite
offline result does not establish every-frame or whole-game MAME equivalence.
