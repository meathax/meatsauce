# Kyros warm-reset replay

The canonical MAME recorder is unchanged. scripts/make_warm_reset_capture.py
derives capture_warm_reset.lua with guarded substitutions and source hashes.
It records 960 callback fields, applies the existing legal coin/start/combat
sequence, releases cabinet controls at field 300, and calls MAME soft_reset.
After reset, the input sequence starts again at logical field 301. Real game
CPUs run throughout; no lives, score, registers or RAM are patched.

The native harness accepts --warm-reset-after 300 with a recorded input file.
At the same completed-field boundary it releases controls, holds the game's
reset for 64 master cycles, and keeps cold_reset/downloading inactive. It
asserts cleared main/sound transaction counters, YM write counter, DAC latch
and signed mixed sample. The reset event CSV records before/held values.
CPU observation counters are resynchronized so reset itself cannot fabricate
a sound or main-bus write. ROM/SDRAM contents are retained; no reload occurs.
Subsequent fields run the real boot and second coin/start/play sequence.

This tests the game reset input. HPS reset transport and hardware reset
qualification remain separate. The precise MAME scheduling/RTL hold interval
can expose genuine event/raster differences: retain and diagnose them rather
than shifting images, ignoring writes or claiming broad MAME_EXACT. Compare
official PNG-derived canonical RGB after reset; raw MAME RGB is not canonical.

The first recorder derivation failed before launching MAME: a status-flush
block sits between drive_inputs() and frame increment. The guarded patch now
inserts at the unique input call and preserves that block. Failure logs are
research/kyros_warm_reset_derivation_failure.log and
research/kyros_warm_reset_reference_dependency_failure.log. The first native
worker completed a real build (exit 0), then stopped because no MAME receipt
existed. It launched no simulation.

The first actual MAME run exited 0 but is invalid: its autoboot script was
reattached four times by soft reset, reopening the capture files. It left
only 282 state rows and a reset CSV containing NUL bytes. The original
capture, exact loaded Lua and failed receipt are retained. A persistent Lua
guard now allows one recorder attachment per process.

The fresh reference completed 960 ordered fields, one attachment and both
reset markers 300/301, without Lua errors. Its 35 official PNG checkpoints
were normalized with the existing canonical helper. Evidence:
research/kyros_warm_reset960_refv2_mame_exit.json and
research/kyros_warm_reset960_refv2_normalization.json. This establishes the
reference recording, not native reset recovery.

That successful RTL build is retained as a dedicated ELF and input manifest.
research/kyros_warm_reset960_build_recovery.json verifies current harness
hash against the authentic build manifest, records the executable/manifest
hashes and permits --reuse-prepared in the second native worker. This avoids
rebuilding unchanged inputs. Authoritative MAME receipt:
research/kyros_warm_reset960_refv2_mame_exit.json. Native second-attempt receipt:
research/kyros_warm_reset960_v2_native_exit.json. Neither build exit nor
launch proves reset recovery; check completed field metrics, reset CSV,
post-reset graphics and actual sound-event streams before qualifying it.

The earlier death/game-over run uses its dedicated previous executable copy
and continues independently. All timing/resource/assembly work remains held:
no Quartus invocation or RBF generation occurs in this phase.
