# Source provenance

Upstream: https://github.com/rmonic79/Arcade-Raiden2_MiSTer.git

Commit: `534c84c5803959e76538b65ac71808616f1caa41`

Original path: `rtl/sound/`

Imported unchanged, retaining original per-file notices. Integration changes belong in a dated change entry below. The project license is GPL-3.0-or-later; upstream file notices remain authoritative.

2026-10-04: `jtopl/` added unchanged from the staged Raiden donor,
`28cd62a632f8a5c12dfc81e0882b9869ac57940d` (Jose Tejada, GPL notices retained).
`jt6295/jt6295_acc.v` now uses project-root-relative coefficient HEX paths;
the datapath and coefficient contents are unchanged. Target wrapper details
are in `../ZeroTeam_audio.PROVENANCE.md`.

2026-10-06: `jtopl/jtopl_acc.v` bypasses the general Q4.4 multiplier/clamp
when the selected gain is exactly `8'h10`. The signed fourteen-bit rhythm
result already fits the clamp range, so this preserves all samples, gains,
rounding, rhythm slot selection and register latency. Zero Team ties all nine
gains to unity; the bypass shortens its full-cycle rhythm/slot path. Actual
RTL arithmetic was exhaustively checked in `sim/run_opl_gain_checks.py`
(33,554,432 comparisons), alongside the operator phase regression.
