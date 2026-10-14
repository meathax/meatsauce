# Sheriff-only MiSTer project

Read `plan.md`, `progress.md`, `donormap.md`, and `mamebug.md` before implementation. `plan.md` is the authoritative plan; append completed work and evidence to `progress.md`.

- Sole supported game: Nintendo `sheriff` parent, MAME 0.289. Other games and clones are excluded, including after Sheriff is complete. Related-board sources are references only.
- Run analysis/synthesis, fit, and TimeQuest at the milestones in the plan and after relevant RTL/clock/memory changes. Quartus is `D:/q17/quartus/bin64`.
- Never build/rebuild an RBF without an explicit user request. This preparation request does not authorize assembly. Do not use `quartus_asm`, `quartus_sh --flow compile`, or an equivalent full build before the simulation gates and explicit authorization. `GENERATE_RBF_FILE` stays OFF until that final authorized stage.
- Use one game master clock and clock enables. Framework HDMI/HPS/DDR clocks are separate platform requirements; document them rather than claiming the whole framework has one clock.
- Respect the utilization limits in `config/resource_limits.json`. Unknown/missing reports do not count as passes.
- Keep `sys/` untouched. Put board RTL outside it and add files through `files.qip`.
- No ROM bytes, connection credentials, local environment files, or fetched ROM archives in commits or published artifacts. `roms/`, `donors/`, and `mister.env` are local and ignored.
- Donor source is staged, not qualified. Preserve notices and provenance. Do not integrate the noncommercial Donkey Kong `I8035IP` wrapper or assume the staged 8085 candidates are complete.
- Linux tools/tests use Ubuntu WSL explicitly. Never launch ELF binaries or extensionless POSIX scripts directly from PowerShell. Use `wsl.exe -d Ubuntu --cd D:\Arcade\AI\aCORES\sherrif --exec ...`.
- Use bounded reads/Capsule, batch independent evidence work, and keep reports compact. Consult the relevant entries in the shared lessons index before unfamiliar failures, toolchain choices, clock changes, or release qualification. No subagents unless the user authorizes them.
- Scope each verification to the changed behavior. Reuse captures, checkpoints, converted donors, and clean fit snapshots. Stop repeated tests once the relevant acceptance condition passes.
- Standing MiSTer access authorization is supplied by the user. Obtain connection details from the current session/local ignored configuration; never write them in project documents.
