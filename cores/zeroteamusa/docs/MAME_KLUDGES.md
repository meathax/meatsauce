# Reference limits

The reference is the staged pristine MAME 0.289 source and original `zeroteam`
US ROM. Local captures and their hashes are recorded under `docs/evidence/`.

`reference/mame/seibucop.cpp` implements `cop_prng_r()` as host CPU total cycles
modulo the programmed range. Its adjacent comment says the random generators
were verified only for 68000 games. `reference/mame/raiden2.cpp` maps the random
reads at `0x5a0..0x5a7` and notes Zero Team reads `0x5a4`.

The donor RTL's LFSR therefore does not reproduce MAME's random stream.
Matching a frame number or IRQ count does not guarantee matching actor state.
Use exact comparisons for deterministic buffers and scenes; investigate actor
differences with matching state and operands before attributing their cause.

The complete live attract image at 600 IRQs is not pixel-identical to MAME.
BG, FG, MG, text, palette and the compared CRTC register bytes match the
599/600 reference captures; sprite words differ. This is partial evidence,
not a passed stable-attract or gameplay gate.

The USA set uses `raiden2_state` with `init_zeroteam`, rather than the
`xsedae_state` used by a sibling set. It blends palette pens 0x37e, 0x38e,
0x52e and 0x5de with `(source*127 + destination*129) >> 8`. The production
renderer now follows this target initialization and blend arithmetic.
Optional capture exports observe MAME's buffered sprite save item without
writing emulated state. At frame 599 its buffer equals the source sprite RAM;
that observation ruled out buffering as the cause of this scene's mismatch.
The corrected renderer matches the complete captured scene, which does not
replace live CPU, gameplay, audio or progression evidence.

## COP sort-DMA (`$6FE`)

MAME 0.289 `dma_zsorting()` sorts `data` entries, but the observed Zero Team
tables hold `data+1` live entries followed by a zero terminator, so MAME leaves
the last object unsorted (its own TODO: zeroteam sort/sprite priorities).
The RTL sorts `data+1` entries by the signed 32-bit key `{word@+2, word@+0}`
with a stable sort, up to 128 entries (the game issues up to 82). The donor's
earlier single-word key left every observed call unsorted. Evidence:
`docs/evidence/sort-dma-zeroteam.json`.

## Sprite order and the entry-0 "clip" record

MAME's `zeroteam` uses the `raiden2_state` path (`draw_raw`): the list is
drawn from the last entry to entry 0, opaque pixels overwrite regardless of
the priority field, so list order alone is sprite-sprite priority. The RTL scan
is the same (511 -> 0, last write wins, pen 15 transparent); the broken
ordering came from the COP sort-DMA (above), not the renderer.

MAME's TODO about a non-sprite first entry: in a 2P combat capture (every 30
frames, 1800 frames, pristine MAME) entry 0 is constant `ffff 3fff 0150 00ff`
(code 0x3fff, X=0x150=336, Y=0xff, 8x8 tiles). MAME and the RTL both treat it
as an ordinary sprite; X=336 is beyond the 320-pixel line, so it draws nothing
visible. No clipping semantics are implemented because none is evidenced; no
PCB evidence exists for the record's purpose.
