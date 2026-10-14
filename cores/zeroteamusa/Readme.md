# Zero Team USA for MiSTer

Simulation-first development workspace for the Seibu Kaihatsu 1993 JAMMA
board, targeting **MAME 0.289 `zeroteam` — Zero Team USA (US)**.

Current state: donor hardware is imported and the real V30 executes the US
program in a Verilator CPU seam with explicit memory latency. The complete
target board, protection, video and sound are still being integrated.
**There is no working Zero Team game or project RBF yet.** Donor release
RBFs inside ignored donor checkouts are upstream artifacts, not Zero Team builds.

- [plan.md](plan.md): authoritative implementation order and completion gates.
- [progress.md](progress.md): completed work, evidence and next action.
- [docs/DONOR_MAP.md](docs/DONOR_MAP.md): board component coverage and adaptation gaps.
- [goal-prompt.md](goal-prompt.md): prompt to start the implementation goal.
- [donors/manifest.json](donors/manifest.json): exact public source revisions.
- [reference/mame/manifest.json](reference/mame/manifest.json): target identity,
  clocks, ROM hashes and local reference paths.

The primary hardware donor is rmonic79's Raiden II/DX core. Zero Team has
different sprites, decryption, mixer glue, ROM arrangements and sound;
the donor must be adapted. MAME marks the target as not working and four
board PALs are undumped. These are explicit tasks in the plan.

Use Quartus 17.0 for analysis/synthesis, fit and timing analysis during RTL development (`scripts/check_timing.ps1`). RBF generation and MiSTer testing remain in the final hardware phase.
The scaffold is not compiled during preparation. Keep the MiSTer `sys/`
framework unchanged. See [THIRD-PARTY.md](THIRD-PARTY.md) for source attribution.

Game data under `roms/` is local and ignored by Git. No ROMs are distributed.

Target MiSTer platform options are now wired in source: named four-player
controls/service menu, all physical DIPs, native 55.407801 Hz video, scaling,
CRT adjustment, HDMI 90-degree rotation, analog/HDMI 180-degree rotation and
OSD-triggered high-score saving. See [docs/PLATFORM_OPTIONS.md](docs/PLATFORM_OPTIONS.md)
for verification and remaining hardware/gameplay gates. This is not an RBF
release. High-score support uses Alan Steremberg and Jim Gregory's GPLv3
Hiscores_MiSTer controller; see [provenance](rtl/hiscore.PROVENANCE.md).
