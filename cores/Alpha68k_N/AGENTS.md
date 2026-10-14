# Current task override — 2026-10-10

The user explicitly authorized parallel agents, resumed development checks and
requested repair of the conflicting queue rule before resubmitting.

Use `C:\Users\meath\QuartusFast\quartus-fast.ps1 build --project PATH.qpf`
for check-only work. Use `plan` to choose the smallest sufficient supported
profile: `quick-check` for syntax/elaboration, `synth-only` for synthesis,
and `turbo` for fit/STA. Use `--mode dev-safe` for report-guided fallback.
Inspect the installed frontend before selecting profile flags; if a profile
is unavailable, use the fixed native check tools in an independent database.
Partial checks force `GENERATE_RBF_FILE OFF` and preserve preprocessing in
the isolated check workspace; they do not run full packaging workflows. Without `--allow-rbf`, this frontend performs
preassembly checks and does not build an RBF. Check-only map/synthesis, fitting
and STA are authorized, run without a production FIFO lease, and never occupy
a queue lane. Do not force these checks through a full-compile-only recipe.
Preserve reviewed preprocessing, source pins, original project read-only
behavior and separate receipts. Direct check-only tools remain allowed under
the global rule, but QuartusFast is the preferred compilation/fitting entrypoint.

Full compile/assembly, RBF/ASM/CPF and final release packaging require an explicit
current RBF build request, `--allow-rbf` when using QuartusFast, and all required
current-image simulation, graphics, bug, resource and timing gates. QuartusFast
delegates these full jobs to the existing shared FIFO with a permanent two-job
ceiling. The reviewed queue entrypoints remain
`C:\Users\meath\.claude\skills\mister-rbf-build\scripts\quartus_flow.ps1`
and `D:\vibes\fpga\bin\quartus-safe.ps1`; preserve custom recipes. A job owns
its lease until every child closes. Report actual `QUEUE position N of M` when
queued; never invent a position for unqueued checks, bypass the ceiling, launch
raw quartus_sh/asm/cpf or interfere with other sessions. Resubmission must not
duplicate an already-live check. General permission and queue admission do not
authorize early assembly. Enforce all seven complete-design resource limits,
review all timing domains and critical warnings, and retain unqualified gates.

# Active repository location — 2026-10-10

The canonical game working folder is `D:\Arcade\AI\aCORES\meatsauce-alpha68kn\cores\Alpha68k_N`. Its Git root is `D:\Arcade\AI\aCORES\meatsauce-alpha68kn`, remote `https://github.com/meathax/meatsauce.git`, game prefix `cores/Alpha68k_N`, branch `main`. Perform future Git operations there. `D:\Arcade\AI\aCORES\Alpha68k N` is retained as a recovery copy and as the target of gitignored local staging links; active simulations may finish there. This migration authorizes its commit and push only. Quartus development checks are authorized by the current override below.

# Current user override — 2026-10-10

Use agents in parallel for independent tasks wherever useful. The user explicitly
resumed Quartus and authorized ongoing development checks. This supersedes the
2026-10-09 suspension and older restrictions on agent use. Keep timing closed
throughout development; measure the complete fitted design against all seven
strict resource limits, aiming for headroom where practical. A failed or missing
measurement remains an open gate, never a passing estimate.

The unified current flow policy above governs both check-only and full jobs.
Preserve the explicit final-build request and all its prerequisites; hardware
testing remains last.

# Alpha68k N working instructions

The user's current instructions override this file and skill defaults.

- This repository is a local Template_MiSTer derivative for `kyros`, `kyrosj`, then `sstingry`. Preparation is complete only when `progress.md` records the evidence. The scaffold is not a working arcade core.
- `plan.md` is the execution plan; `progress.md` is the durable progress record; `mamebug.md` is the canonical bug catalogue; `donormap.md` is the donor integration map. Read their relevant sections before continuing.
- Use Capsule or bounded reads, bound searches and long lines, batch independent observations, preserve command exit codes and useful stderr, and reuse saved evidence. Do not repeatedly rescan donor repositories or the MAME tree.
- Never build or rebuild an RBF without an explicit user request to build or rebuild it. Implementation, diagnosis, simulations, Quartus analysis, synthesis and fitting do not authorize assembly. Ongoing development does not authorize RBF assembly.
- Run material-change development checks through the current unified flow policy above. Inspect RAM inference before fitting; qualify setup/hold, recovery/removal, crossings, generated clocks and unconstrained endpoints before declaring timing closed. Enforce resource_limits.json on the complete fitted design.
- Bring all target games through attract mode and gameplay in the real RTL Verilator harness before any RBF or MiSTer test. Snapshot rendering and scripted fake CPU/game behavior do not meet this requirement.
- The user has standing authorization for task-related MiSTer deployment, execution, diagnostics and hardware tests, including existing RBFs. Obtain connection settings from local session configuration; never put credentials in this repository or published artifacts.
- Keep game logic on one master clock with enables. Preserve the pinned `sys/` framework. Specify and review every necessary crossing to framework or memory-interface clocks.
- ROMs, downloaded donor working copies, local environment files, large captured evidence and generated build files are gitignored. Pin and credit donor modules before integration; retain their license notices. No remote publication is authorized by ongoing development.
- Consult relevant entries through `C:\Users\meath\.codex\lessons-index.md` or `python -X utf8 C:\Users\meath\codex-tools\maintenance\lessons_index.py search <terms>`. Expand only selected lessons; never read the full corpus for orientation.
- Linux ELF binaries run through the explicit Ubuntu WSL environment. POSIX scripts run through their matching interpreter; never invoke extensionless scripts with PowerShell or ShellExecute. For example: `wsl.exe -d Ubuntu --cd "D:\Arcade\AI\aCORES\Alpha68k N" --exec ./sim/build/alpha68kn_sim`.
- Work in the canonical checkout. Use parallel agents for independent tasks wherever useful, within available slots; assign disjoint source ownership and integrate centrally. Do not create extra worktrees, unrelated tests or optional features without separate authorization. Commit completed phases on main locally; push only when explicitly requested.
- On each meaningful phase exit, update progress with the source revision, changed files, decisive result, evidence path and next action. Record failures and fidelity limits plainly.
