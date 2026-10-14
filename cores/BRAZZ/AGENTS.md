# CrystalSystem project instructions

First target is The Crystal of Kings, `crysking`, using MAME 0.289. Root `plan.md` is the main plan; root `progress.md` is the progress ledger. Read both before continuing. No additional game is in scope until this game is complete.

This is a simulation-first project. Quartus analysis/synthesis and fit/static timing checks are explicitly authorized during RTL development by the user. RBF generation, deployment and MiSTer hardware acceptance remain reserved for the final phase after the documented simulation completion gate. The user's 2026-10-04 global rule replaces standing RBF-build authorization: never build or rebuild an RBF without an explicit user request for that build. MiSTer task-related access remains authorized; it does not change this ordering. Keep hardware credentials in local session/global instructions, never repository files.

Use staged ROMs/donors/MAME references. Sources present on disk do not establish correctness, license clearance or simulation success. Preserve source archives and pristine donors. Do not modify `sys/`. Keep machine configuration/ROMs/captures/build outputs private and ignored. Work on `develop`; do not push without a user request.

Use Capsule or bounded searches for repeated evidence. Keep exact recovery paths and nonzero statuses. Check only affected functionality after a change; expand verification only for a concrete failure/risk. Use the explicitly selected runtime for POSIX scripts/Linux ELF executables on Windows.

The full oracle executable is `D:\Arcade\AI\mameexe\mame.exe` (0.289 mame0289); the executable inside the source tree lacks crysking. Generic staged MAME/build scripts require adaptation to the SE3208/little-endian 32-bit board and must not be assumed ready.
