# Behavioral approximations and remaining fidelity work

The game runs its original US ROM through the real RTL CPU, COP, video and
sound paths. No protection-answer stubs, ROM patches or host CPU substitutes
have been introduced for bring-up.

The inherited COP random source remains an approximation: `rtl/Raiden2/COP3.sv`
uses a free-running 16-bit LFSR reset to `0xace1`, with taps 16/15/13/4, and
scales its value into the configured range. The original ASIC's random sequence
has not been established. Save-state support retains the LFSR state.

This matters when comparing randomized actor positions to MAME. The streams
differ, but this alone does not establish the cause of any particular actor
discrepancy. Gameplay and natural progression still need their planned proof.

At the 600-IRQ attract checkpoint, static scenery ROIs align without an X/Y
shift. Captured-scene tests reproduced the incoming tile/sprite row read errors,
the inherited 240-line sprite gate, the suppressed last-row swap, and missing
USA palette blending. The corrected production renderer matches all 81,920
pixels of the pristine buffered frame-599 fixture, without image offsets.
This is a component proof using observed MAME state. Full live CPU acceptance
of these changes and the attract/gameplay gates remain pending. See
`docs/evidence/video-complete-raster.json`.
