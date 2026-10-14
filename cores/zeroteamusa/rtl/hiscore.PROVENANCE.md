# High-score controller

Copied from the pinned `donors/hiscores/hiscore.v` (Hiscores_MiSTer v14;
revision in `donors/manifest.json`). Copyright and GPLv3 notice retained.
Local changes: initialize pause/write/upload outputs to zero and tie unused
configuration/buffer RAM write ports low; hold the access state machine until `paused` acknowledges that
the V30 has parked and the COP is idle. Work RAM retains its existing single
registered CPU read port, with little-endian byte lanes. The 75-byte table at
`9212` and initialization bytes `40`/`55` come from MAME's hiscore.dat Zero Team
entry. Initialization bytes qualify restoration; saved payloads may change them.
# 2026-10-05 timing qualification

2026-10-06: Cache the hold predecessor atomically with configuration writes.
Map the four small configuration tables to explicit word registers, retaining
registered reads and write/read semantics. Quartus 17 kept the parameter-valued
RAM style in AUTO, so use constant logic style and individual word enables.
Keep automatic inference for the score buffer. Check both implementations
against the dual-port contract with `sim/run_hiscore_ram_checks.py` (65,536
cycles, including same-address writes and cross-port old-data reads).

Replace the start/end read-wait subtraction with `check_wait_elapsed` equality
tests. For unsigned 32-bit subtraction, a difference is below one/two only at
the exact zero/one-difference timer values. Preserve wrap, all 16-bit hold
values and both read-pipeline modes; verify the actual RTL predicate with
`sim/run_hiscore_wait_checks.py` (1,441,792 comparisons).

2026-10-06: Compute wait-timer decrement with parallel byte borrows. Keep the
full 32-bit timer, modular wrap and all state transitions. Verify the actual
function with sim/run_hiscore_timer_checks.py (1,835,008 comparisons).
