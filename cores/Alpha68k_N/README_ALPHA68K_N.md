# Alpha68k N preparation

This is a local MiSTer template project, with public donor source and locally supplied ROMs staged for development. **No game RTL has been implemented or demonstrated yet.** The Template demo remains in the renamed top-level file. No RBF has been built or deployed by this task.

Target order: Kyros (`kyros`), Kyros no Yakata Japan (`kyrosj`), then Super Stingray Japan (`sstingry`). Jongbou is outside this assignment.

Start with [plan.md](plan.md), [progress.md](progress.md), [mamebug.md](mamebug.md), [donormap.md](donormap.md) and [docs/HARDWARE_NOTES.md](docs/HARDWARE_NOTES.md). [goal_prompt.md](goal_prompt.md) contains the prompt for authorizing implementation and the final gated build.

Open `Alpha68k_N.qpf` for Quartus 17.0.2. `Alpha68k_N.sv` keeps Template's `emu` interface; `files.qip` references the renamed source and constraints. `sys/` is the original template framework. The retained `Template_Q13.*` files are historical template references and are not the active project.

`donors.lock.json` pins twelve staged donor repositories. The downloads live under gitignored `donors/`; each includes a local `STAGED_PROVENANCE.json`. `research/source_manifest.json` pins the template and records MAME reference hashes. `research/rom_manifest.json` records all required ROM checks and load semantics. The locally supplied `kyros.zip` includes the Japan clone.

Reproduce staging with `python -X utf8 scripts/bootstrap_stage.py`, then `python -X utf8 scripts/stage_reference.py`. Bootstrap retrieves public code and copies local ROMs; it never invokes FPGA tools. Once implementation starts, retain pinned donors rather than updating their HEADs indiscriminately. `scripts/verify_preparation.py` verifies the saved preparation once without rebuilding it.

The initial `D:\Arcade\AI\mame289\mame.exe` identifies itself as 0.289 but does not contain Kyros. A matching executable containing the target driver must be selected or built in plan phase P1 before MAME reference capture. This does not affect the successful source-based CRC/SHA1 audit.

The intended aggregate implementation license must accommodate GPLv3 donors; retain the template license and all component notices. No game ROM may be distributed. Final README, contribution review, third-party attribution and release metadata are tasks in the plan, not evidence of a completed core.
