# Zero Team COP adaptation

The base module remains the licensed pinned rmonic79 Raiden II donor.
Original copyright/GPL notices and arithmetic implementation are retained.

2026-10-04: Added command `3b30` to the existing `3bb0` distance dispatch.
The US game actually issues `3b30`; the prior raw-command dispatch did not
recognize it. MAME 0.289 `seibucop_cmd.ipp:193–215` documents the same uploaded
distance sequence under those two triggers. The existing hardware computes
the integer square root of the latched signed position deltas. Bit 7 still
controls the optional RAM-result write, so `3b30` updates the internal
distance register without writing the result into actor RAM.

The focused real-COP replay matches all 78 observed US operand/readback
cases and performs no unintended distance writes. Its memory bridge uses
the production input latency. Source/fixture hashes and exact scope are in
`docs/evidence/cop-distance-us.json`. This is actual arithmetic, not a
constant answer, ROM patch or protection bypass.

The first observed target call is at frame 170. Earlier live snapshots
remain historical boot evidence; later pre-fix snapshots are affected by
the missing operation. A changed hardware model starts from a fresh cold
boot/checkpoint, preserving the strict native serialization identity gate.
