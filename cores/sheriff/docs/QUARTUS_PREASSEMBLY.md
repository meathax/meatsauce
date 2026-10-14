# Current check-only authorization (2026-10-10)

The latest user AGENTS instructions supersede the historical queue-admission restriction below. Check-only quartus_map (including analysis/elaboration), quartus_syn, quartus_fit and quartus_sta may run directly from D:/q17/quartus/bin64, unqueued. Freeze source and run these stages in an isolated workspace with GENERATE_RBF_FILE OFF; retain actual exits and reports. Full compiles and ASM/CPF/RBF remain queued and gated on explicit authorization and applicable acceptance. No development assembly is authorized. Historical recipe rejection evidence remains useful only for that former flow.

# Pending development timing check

The user lifted the Quartus hold on 2026-10-09. Resource limits in
`config/resource_limits.json` remain required, and final assembly still follows
the simulation and exact-source acceptance gates.

The first queued check of commit `f354ad7dacc075949bfa73b2767cc4c9c9dd8e61`
terminated before compiler admission with worker exit1:

> Only the canonical complete compile argv is admitted; separate stage tasks are refused.

The local snapshot and receipt are
`_checks/f354ad7dacc0-20261009-233434/`.
The shared worker receipt/log are in
`D:/vibes/fpga/quartus/temp/safe-55048-6e49a697490f49adb428ec3caa12fb69/`.
No compiler process, map/fit/STA pass or RBF was produced by this attempt.

The queue accepts independently registered complete-job recipes with mode
`preassembly`, but the current reviewed registry has no Sheriff recipe. Do not
bypass its invocation guard, change its pinned registry, use another project's
recipe, run raw tools, or substitute an assembly-producing full compile.

The reviewable requested job is the archived snapshot's
`source/development_check.tcl`: generate the template build ID, assert
`GENERATE_RBF_FILE OFF`, then execute map, fit and STA in one queue lease.
There is no assembler or conversion command. An independently reviewed Sheriff
preassembly recipe is needed before this job can run through `quartus_flow.ps1`.
The current `tools/quartus_check.ps1` submission is fail-closed under the installed
queue rules; do not describe it as operational or repeatedly retry it unchanged.

Once an applicable recipe is registered, run the committed current RTL snapshot
through the queue, record its actual exit and source identity, and assess all
timing/resource reports. The archived snapshot is useful for reviewing the job
but does not qualify later RTL edits.

The read-only registry observation on 2026-10-10 found 25 recipes and no
Sheriff/Nintendo8080 recipe. The worker pins
`shared_quartus_recipe_registry.json` SHA256
`16c652e324a32faa7d561a8b0cbc0e1c3922cb285dd9c5eb6acf6aade18da884`.
Local receipt: `_checks/current-wrapper-gameplay-1201-20261010/queue-registry-observation.json`.
No compiler submission was repeated during this observation.

A later read-only observation found27 recipes, still with no Sheriff, Sherrif,
Nintendo or N8080 entry. Registry SHA256 was
`fd7b98977d05e5e32ac87fe2c21e77affa43b181a7568ee75306898d5b498d42`.
This is an observed registry identity, not an assertion about the worker's pin.
The admission blocker remains; no failed submission was repeated.

## Verified monorepo preparation (2026-10-10)

The old launcher assumed a standalone Git root and archived allHEAD. Corrected source preparation scopes Git status to the core and archives<commit>:cores/sheriff, preserving the project/framework at the extraction root. The pure Git entry is:

```powershell
& D:/Arcade/AI/aCORES/meatsauce/cores/sheriff/tools/prepare_timing_snapshot.ps1 -ProjectRoot D:/Arcade/AI/aCORES/meatsauce/cores/sheriff
```

The committed9538653d8c36 snapshot passed actual preparation and independent file/blob/hash verification. Exact recovery: cores/sheriff/_checks/9538653d8c36-20261010-121212-c7b56929/{preparation,verification}.json. The staged development_check.tcl checks GENERATE_RBF_FILE OFF and executes map,fit,sta only; its hash and all committed source hashes are recorded in docs/evidence/sheriff_quartus_snapshot.json. No compiler, queue job, assembler or conversion was invoked. The host Quartus guard refused the project quartus_check.ps1 invocation even withSnapshotOnly; the tested preparation utility contains no compiler invocation.

The latest read-only registry observation in this goal turn had30 other-project recipes and no Sheriff entry, SHA2562fa5d401fafb2de95a69f547b1a4e4d6c4f74129cd005177c29e80eb562834ef. Preparation does not grant admission or qualify setup/hold, unconstrained paths, utilization or interconnect. Register an independent reviewed Sheriff complete preassembly job before executing these stages in the canonical shared queue. Keep original denied-submission receipts and do not modify the protected worker/registry or reuse another project profile.
