# Two observer corrections, no replay

The first authentic reference pilot finished at 2400 fields with MAME exit0 but observer qualifier1. Keep its frozen manifest5a348f unchanged. New candidate changes only the generic logger beam API and consumed input read address; all legal inputs, controller, bounds, taps, guest ROM/CPU and candidate logic remain unchanged. No second capture is dispatched.

Official0.289 driver maps0c0000 to IN0/IN1,080000 to MCU; officialLua exposes time_until_pos and periods, no vpos/hpos. The generic logger's unavailable-method calls explain its vacuous event stream; callback errors are separate from frame xpcall. All returned tap objects remain retained, so GC is unsupported here. The exact known-working beam routine is copied from sim/mame/capture.lua.

Actual collision read records bind player A4=20400/A5=work+player+0c, object A0/coordinate read to its own word+0c. No ordinary type20/21/22/24/25 was sampled in this finite route; this does not prove absence in the game. Item/player mapping is now nonvacuous. Health/depletion guard's source offsets are recorded without complete death-semantics claims.

Root review and release required for any second finite observer-corrected pilot. Native RTL replay remains unauthorized until a genuine source-qualified pickup target exists. No guest state write or fabricated command is proposed.
