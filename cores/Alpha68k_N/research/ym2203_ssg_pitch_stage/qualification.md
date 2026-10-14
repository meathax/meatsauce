# Embedded YM2203 SSG tone pitch

The actual current production graph fails period0: accepted tone period0, mixer0x3e, volume15 and default prescaler2 produce no divider or channel-A transitions during500000 master ticks. Actual baseline build exits0 and its contract run exits1. Period1 produces a768-tick rising period (62500Hz); period37 produces28416ticks (1689.189189Hz). Real chip and SSG enables are24 and96master ticks apart. The earlier space-path build exits2 before any simulation and remains preserved.

The private candidate removes only the embedded JT49 divider's period0 forced-low override. The same unmodified probe/host and other production files produce an actual build0/run0: periods0/1/37 match768/768/28416tick gaps exactly. GPLv3-or-later donor notices remain in the copied JT49 source. The original source and pinned MAME references are recorded in source_contract.json and candidate/candidate_provenance.json.

The nominal divider is48MHz /24 /4 /4 /2 /max(P,1). Production alpha68kn_soundchips uses phase0 on a24-step counter; JT12 uses the reset SSG prescaler4 and JT49_DIV2 (divide4); the tone counter toggles every period. MAME289's ymfm_ssg.cpp135-142 increments then compares its tone counter, so period0 behaves like1. ymfm_opn.cpp900-905/934 records the default SSG sample ratio4:1 at chipclock/4, giving the same62500/PHz nominal tone rate at a2MHz YM2203 clock.

Nonzero frequencies and rising periods remain exact, but absolute edge phases differ by a half-cycle after setup because the corrected period0 oscillator runs while registers are programmed. All first-edge ticks and rise-count differences remain in qualification.json. No phase-equal PCM or invented tolerance is used.

Production is unchanged; the existing4401 replay still uses the original divider. This is a finite channel-A fixed-volume/default-prescaler contract and an unapplied correction. Broader SSG envelope/noise, action coverage, P5, full audio and whole-game acceptance remain open.
