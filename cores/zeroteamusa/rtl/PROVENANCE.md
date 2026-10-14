# Shared Seibu infrastructure provenance

`sdram.sv`, `pll.v` and `pll.qip` were copied unchanged from
https://github.com/rmonic79/Arcade-Raiden2_MiSTer at
`534c84c5803959e76538b65ac71808616f1caa41`, under the same original `rtl/`
paths. Original Sorgelig/MiSTer and donor notices remain in the files.
Original imported file hashes are in `reference/research/hardware-import.json`.

Per-subdirectory provenance records the remaining hardware. The active
`ZeroTeam.sv` starts from that donor's `Raiden2.sv`, with a target-development
header and project-name replacement. Game-specific behavior remains to be
adapted; the unchanged template `sys/` is not part of this import.

2026-10-08: `Raiden2/crt_adjust.sv` (rmonic79, GPL-3.0-or-later) patched for Zero Team: sign-extended H-Position, per-H-Size read start and H-Position limits so the picture never clips, and vertical blank gated by the line being read. Details in the file header; evidence `sim/run_crt_bench.sh`.
