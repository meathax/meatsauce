"""Stage current operational rules without changing a live Quartus input tree."""
from pathlib import Path
import hashlib
import json

CORE = Path(r'D:\Arcade\AI\aCORES\meatsauce-alpha68kn\cores\Alpha68k_N')
STAGE = Path(__file__).resolve().parent / 'queue_rule_docs'

def sha(data):
    return hashlib.sha256(data).hexdigest()

def replace_once(text, old, new):
    assert text.count(old) == 1, ('unexpected replacement count', old[:100], text.count(old))
    return text.replace(old, new, 1)

plan_path = CORE / 'plan.md'
original_plan = plan_path.read_bytes()
plan = original_plan.decode('utf-8')
start = plan.index('At minimum fit+STA at P2, P3, P4, P5, P6 and P8.')
end = plan.index('\nResolve negative slack', start)
plan = plan[:start] + '''At minimum fit+STA at P2, P3, P4, P5, P6 and P8. Fit immediately after changes to master clocks, constraints, CDC, RAM structure, memory controller, major fanout or datapath placement. Run analysis/synthesis once per coherent intervening RTL batch. Quartus use is resumed. Prefer the current QuartusFast entrypoint:

```powershell
& "C:\\Users\\meath\\QuartusFast\\quartus-fast.ps1" build --project "PATH.qpf"
```

DEV_FAST performs map/fit/STA checks without assembly. Use `--mode dev-safe` for a conservative fallback and `--mode release` for final qualification. Check-only map/synthesis/fit/STA runs are unqueued and occupy no production lane; direct check tools from `D:\\q17\\quartus\\bin64` are also permitted. There is no required preassembly registry approval or map/fit/STA queue lease.

Full compile, assembly and conversion require the explicit current RBF request and all final gates. QuartusFast `--allow-rbf` delegates those complete jobs to the shared host-wide FIFO, with a permanent two-job ceiling and one lease covering all child processes. Preserve any reviewed custom preprocessing/conversion/packaging recipe; never substitute an implicit assembly flow for checks. Do not invoke raw `quartus_sh`, `quartus_asm` or `quartus_cpf`, historical runners, or bypass the queue. While a full job waits, report its actual `QUEUE position N of M` line; never invent a queue position for check-only work or kill another session's job.

Original projects remain read-only under QuartusFast. Preserve authentic stage exits, reports and input fingerprints. Bind resource_limits.json qualification to the complete fitted candidate; require accepted timing, no unexplained unconstrained paths and reviewed critical warnings. Queue admission does not authorize an RBF. P2–P8 omit assembly and conversion throughout; P9's conditional authorization remains unchanged.
''' + plan[end:]
plan = replace_once(plan,
    "Explicit user resumption supersedes the previous hold. Synthesis/fit/timing remain strict gates under resource_limits.json. The shared queue requires one pinned preassembly recipe and lease across map/fit/STA. Its Alpha68k registration is pending explicit approval after automatic review rejected a host-wide registry/pin change. The original registry is restored. No raw-tool or full-compile workaround. Continue real RTL simulation while approval is pending; final RBF remains conditional on all-game gates.",
    "Explicit user resumption supersedes the previous hold. The current operational rule is the QuartusFast/check-only versus full-job contract above: development map/fit/STA checks need neither a production queue lane nor registry approval. The earlier rejected registry change and restored registry remain historical evidence, not a current blocker. The shared guard repair is retained in research/queue_guard_repair/import_manifest.json. Continue real RTL simulation and complete-design resource/timing checks; final RBF remains conditional on all-game gates.")
plan = replace_once(plan,
    "Quartus remains fully held until the user explicitly releases it; this applies to map, synthesis, fit and TimeQuest as well as assembly.",
    "The Quartus hold recorded at this diagnosis was subsequently released; apply the current operational contract above. Assembly remains gated by P9.")
plan = replace_once(plan,
    "All Quartus stages remain held.",
    "Quartus was held at that dated feature addition and has since resumed under the current operational contract above.")

prompt_path = CORE / 'goal_prompt.md'
original_prompt = prompt_path.read_bytes()
prompt = original_prompt.decode('utf-8')
prompt = replace_once(prompt,
    r'Complete the Alpha68k N MiSTer core in D:\Arcade\AI\aCORES\Alpha68k N,',
    r'Complete the Alpha68k N MiSTer core in D:\Arcade\AI\aCORES\meatsauce-alpha68kn\cores\Alpha68k_N,')
prompt = replace_once(prompt, 'commit completed work locally on develop.', 'commit completed work locally on the canonical repository branch main.')
prompt = replace_once(prompt,
    'Repair resource or timing problems when they appear.',
    r'Repair resource or timing problems when they appear. Use C:\Users\meath\QuartusFast\quartus-fast.ps1 for development map/fit/STA checks, without --allow-rbf. Check-only runs are unqueued and use no production lane. Only gated full compiles/assembly/conversion enter the shared FIFO with its permanent two-job ceiling; preserve reviewed custom flow recipes. Queue admission never authorizes assembly.')
prompt = replace_once(prompt,
    'Do not add optional scope, agents, unrelated verification or remote publishing.',
    'Use agents in parallel for independent authorized work, with clear file ownership and source/evidence joins. Do not add optional scope, unrelated verification or remote publishing.')

loader_path = CORE / 'docs/LOADER_AND_CLOCKS.md'
original_loader = loader_path.read_bytes()
loader = original_loader.decode('utf-8')
start = loader.index('The initial attempts below are historical diagnostics, not current execution')
end = loader.index('\nThe first analysis failed', start)
loader = loader[:start] + '''The initial attempts below are historical diagnostics, not current execution
instructions. Quartus is resumed. Prefer the absolute QuartusFast frontend
documented in plan.md. Development map/fit/STA checks run unqueued and occupy
no production lane. No preassembly recipe registration or lease approval is
required. Only gated full compiles/assembly/conversion use the shared FIFO and
its permanent two-job ceiling. Queue admission never authorizes assembly.
Preserve every strict ceiling in resource_limits.json and all final gates.

The old scripts/quartus_develop.py and scripts/quartus_preassembly.ps1 lease/raw
shell entrypoints are retired and refuse execution with the current frontend
instructions. Use a reviewed immutable check project, then a visible absolute
QuartusFast build command without --allow-rbf. Preserve the Template timestamp
header and fx68k readmemh prerequisites; do not silently discard preprocessing.
The exact timestamp-only-hook review, assignment equivalence and input pins are
retained in research/quartus_check_merged_preprocessed_admission.json,
research/quartus_check_merged_fast_launch.json and the complete private overlay
receipt research/sound_write_width/complete_overlay_launch.json (original
recovery checkout until imported). These are preparation evidence, not a fitted
resource/timing pass. No hardware input was changed by this rule correction.
''' + loader[end:]

legacy_python_path = CORE / 'scripts/quartus_develop.py'
original_legacy_python = legacy_python_path.read_bytes()
legacy_python = '''"""Retired queued preassembly entrypoint; use the visible reviewed frontend."""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
if __name__ == "__main__":
    project = ROOT / "Alpha68k_N.qpf"
    sys.stderr.write(
        "This obsolete queued preassembly entrypoint is retired. "
        "Prepare/review the immutable check project and Template build-ID/microcode "
        "prerequisites as documented in docs/LOADER_AND_CLOCKS.md, then invoke "
        "C:\\\\Users\\\\meath\\\\QuartusFast\\\\quartus-fast.ps1 build --project "
        + str(project) + " (or the reviewed overlay QPF), without --allow-rbf. "
        "Check-only map/fit/STA uses no production queue lane.\\n"
    )
    raise SystemExit(2)
'''
legacy_ps_path = CORE / 'scripts/quartus_preassembly.ps1'
original_legacy_ps = legacy_ps_path.read_bytes()
legacy_ps = '''param([switch]$QueuedRecipeBody)
$ErrorActionPreference = 'Stop'
throw 'The obsolete leased/raw-shell preassembly recipe is retired. Review the immutable check project and Template build-ID/microcode prerequisites in docs/LOADER_AND_CLOCKS.md, then use C:\\Users\\meath\\QuartusFast\\quartus-fast.ps1 build --project PATH.qpf without --allow-rbf. Check-only map/fit/STA is unqueued; full compile/assembly remains gated and queued.'
'''

checks = {
    'plan_current_checks_unqueued': 'Check-only map/synthesis/fit/STA runs are unqueued' in plan,
    'plan_no_preassembly_registration': 'There is no required preassembly registry approval' in plan,
    'plan_no_active_lease_requirement': 'The shared queue requires one pinned preassembly recipe' not in plan,
    'plan_no_active_hold': 'Quartus remains fully held until' not in plan and 'All Quartus stages remain held.' not in plan,
    'plan_final_rbf_gated': 'P9\'s conditional authorization remains unchanged.' in plan,
    'prompt_current_path_branch': str(CORE) in prompt and 'branch main' in prompt,
    'prompt_parallel_authorized': 'Use agents in parallel' in prompt,
    'prompt_full_job_limit': 'permanent two-job ceiling' in prompt,
    'loader_no_active_registry_or_lease': 'Shared preassembly recipe registration remains subject' not in loader and 'every\ncurrent job must use' not in loader,
    'legacy_python_no_launch': 'subprocess' not in legacy_python and 'quartus_flow.ps1' not in legacy_python,
    'legacy_ps_no_launch': 'quartus_sh.exe' not in legacy_ps and 'Assert-SharedQuartusAncestorLease' not in legacy_ps,
}
assert all(checks.values()), checks
compile(legacy_python, 'quartus_develop.py', 'exec')
STAGE.mkdir(parents=True, exist_ok=True)
entries = []
for relative, original, candidate in [('plan.md', original_plan, plan), ('goal_prompt.md', original_prompt, prompt), ('docs/LOADER_AND_CLOCKS.md', original_loader, loader), ('scripts/quartus_develop.py', original_legacy_python, legacy_python), ('scripts/quartus_preassembly.ps1', original_legacy_ps, legacy_ps)]:
    data = candidate.encode('utf-8')
    staged = STAGE / relative
    staged.parent.mkdir(parents=True, exist_ok=True)
    staged.write_bytes(data)
    assert sha((CORE / relative).read_bytes()) == sha(original), 'canonical source changed during staging'
    entries.append({'canonical_relative': relative, 'original_sha256': sha(original), 'staged': str(staged), 'sha256': sha(data), 'bytes': len(data)})
receipt = {'schema': 1, 'canonical_mutation': False, 'reason': 'Preserve live complete-check source fingerprint; import only after its terminal receipt.', 'checks': checks, 'entries': entries}
manifest = STAGE / 'manifest.json'
manifest.write_text(json.dumps(receipt, indent=2) + '\n', encoding='utf-8')
print(json.dumps({'staged': str(manifest), 'checks': checks, 'manifest_sha256': sha(manifest.read_bytes()), 'canonical_mutation': False}))
