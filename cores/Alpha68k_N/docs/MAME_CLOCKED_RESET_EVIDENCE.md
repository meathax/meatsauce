# Exact-clock MAME reset evidence and field360 comparison

Parentfb5f1c8. A fresh361-field MAME capture adds emulated48MHz master ticks
and main CURPC/PC to the original functioning callbacks, plus notifier clock
rows. It reproduces all361 state rows,741,506 original event rows (including
their vpos/hpos), and all15 previously normalized displayed images. The
extra fields are observers; cabinet inputs, reset behavior and ROM are unchanged.
Local MAME0.289 luaengine.cpp binds machine.time to running_machine::time and
attotime:as_ticks. CPU sources bind STATE_GENPCBASE as CURPC. Source hash,
loaded recorder hash and positive trace coverage are retained in the v4
job/exit/verification records. No unsupported hpos/vpos method is used.

At field60, the observed backdrop write is data0x5050, mask0x00FF to0x060000
(physical low byte0x060001), instruction CURPC110132=0x1AE34, nextPC110140.
Staged program bytes at that instruction are13FC005000060001, MOVE.B #$50
to$00060001. Thus this executed MAME instruction is identified rather than
selected from the five static patterns. MAME master tick49,032,839, rounded
beam81,97; native accepted write at99,97 remains an open bus-phase comparison.
Do not subtract absolute clocks across different reset/start origins without
their recorded boundary clocks.

MAME notifier330/360 clocks are268,443,647 and292,773,887, exactly30 fields
apart (24,330,240 master ticks), at240,0. The10,455 actual MAME sprite writes
between them reconstruct final360 RAM exactly. Both start330 and end360 RAM
match the native source byte-for-byte. Replaying these MAME writes through the
same unchanged actual renderer and the same recorded native counter origin
produces every57,344 native360 pixel exactly. Native accepted-write replay
also matches every pixel. No time/pixel/frame offset was fitted to images.

Both timed runs complete exit0,7,920 lines,0 deadline/overflow, worst line2,280
master ticks. MAME timed render has527,956 SDRAM read pairs; native timed has
527,950. The small write-history differences do not alter this target raster
image. The canonical atomic MAME360 image still differs2,104 pixels, retained
as a separate failed comparison. This case therefore has finite time-aware
graphics agreement; final-frame RAM drawing is a different oracle from the
recorded raster-time writes. No complete MAME graphics gate is inferred.

Projection uses integer-floor machine.time:as_ticks(48MHz), so sub-master-clock
fractions are not preserved. Background is fixed to target snapshot64; its
history and full original SDRAM controller/refresh phase are not restored.
These are explicit isolated-fixture limits, not actual CPU bring-up substitutes.

Tools: scripts/run_clocked_reset_reference.py,
scripts/prepare_mame_reset360_renderer.py and run_mame_reset360_renderer.py.
The last reuses the exact qualified renderer ELF hash; no duplicate build.
Evidence: research/kyros_reset_raster361_v4_verification.json and
research/kyros_reset360_mame_timed_renderer_verification.json, corresponding
preparation/job/worker/exit records, and ignored frozen captures.
Next: record native instruction/program-bus state around the identified
backdrop write, resolve its actual CPU bus phase, then apply the same
time-aware method to combat/field900 differences without waiving atomic
image failures or modifying CPU clocks merely to match pictures.
