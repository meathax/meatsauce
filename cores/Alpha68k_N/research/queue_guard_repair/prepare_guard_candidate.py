from pathlib import Path
import hashlib, json, difflib

ROOT = Path(__file__).resolve().parent
ORIGINAL = Path(r'C:\Users\meath\.claude\skills\mister-rbf-build\scripts\shared_quartus_queue_hook.py')
EXPECTED = '1046f079e2a740bc9ea8301922586cc5dc16176f0e623883550e9861a69378bb'

def sha(data): return hashlib.sha256(data).hexdigest()

live=ORIGINAL.read_bytes()
assert sha(live) in {EXPECTED,'8feab912124dd4ad67167d45f2e8ce3638844c5a229b21996e62a91d11d0aac5'}
original = (ROOT/'shared_quartus_queue_hook.original.py').read_bytes() if (ROOT/'shared_quartus_queue_hook.original.py').exists() else live
assert sha(original) == EXPECTED
source = original.decode('utf-8')
source = source.replace('import argparse\n', 'import argparse\nimport ast\n', 1)
source = source.replace('BUILD_TOOLS = {"quartus_asm","quartus_cpf"}', 'BUILD_TOOLS = {"quartus_asm","quartus_cpf"}\nFAST_FRONTEND = r"C:\\Users\\meath\\QuartusFast\\quartus-fast.ps1"', 1)
source = source.replace('CHECK_REFUSED_ARGS = {"--flow","--script","--eval"}', 'CHECK_REFUSED_ARGS = {"--flow","--script","--eval","-t","-s","--tcl_eval","--tcl-eval","--shell"}',1)
source = source.replace(' Use the canonical shared queue; queue admission does not authorize RBF assembly.', ' Use the reviewed QuartusFast frontend for check-only work; full compiles require the shared queue and separate explicit RBF authorization.', 1)
helper = (ROOT / 'guard_helpers.py').read_text(encoding='utf-8')
source = source.replace('def classify(exe: str,args: list[str]) -> str:\n', helper + '\n\ndef classify(exe: str,args: list[str]) -> str:\n', 1)
source = source.replace('    low=[a.lower() for a in args]\n    if path in PROGRESS', '    low=[a.lower() for a in args]\n    if path==canonical(FAST_FRONTEND):\n        validate_fast(args)\n        # Visible command stays unchanged: no permission allow, lease or launch here.\n        return "pass"\n    if stem=="quartus-fast":raise Refusal("Noncanonical QuartusFast frontend")\n    if path in PROGRESS', 1)
source = source.replace('if any(a in low for a in CHECK_REFUSED_ARGS):', 'if any(a==flag or a.startswith(flag+"=") for a in low for flag in CHECK_REFUSED_ARGS):', 1)
source = source.replace('    if path==canonical(FLOW):\n', '    if path==canonical(FLOW):\n        if any(a=="-quartusfast" or a.startswith("-quartusfast=") for a in low):raise Refusal("Unknown fast delegate on canonical queue flow")\n',1)
source = source.replace('        if any(a in low for a in {"-globalslotroot","-globaltemproot"}):raise Refusal("Queue namespace override")\n        action=low[low.index("-action")+1] if "-action" in low and low.index("-action")+1<len(low) else ""\n        stage=low[low.index("-stage")+1] if "-stage" in low and low.index("-stage")+1<len(low) else "compile"', '        flow_options=literal_flow_options(args)\n        if any(name in flow_options for name in {"-globalslotroot","-globaltemproot"}):raise Refusal("Queue namespace override")\n        action=flow_options.get("-action","").lower()\n        stage=flow_options.get("-stage","compile").lower()',1)
source = source.replace('quartus-(?:safe|progress)|quartus_(?:flow|worker)",command))', 'quartus-(?:safe|progress|fast)|quartus_(?:flow|worker)",command))', 1)
source = source.replace('quartus-(?:safe|progress)|quartus_(?:flow|worker)|-encodedcommand', 'quartus-(?:safe|progress|fast)|quartus_(?:flow|worker)|-encodedcommand', 1)
source = source.replace('        if ntpath.basename(exe).lower() in {"python","python.exe"}:\n            rest=list(args)', '        if ntpath.basename(exe).lower() in {"python","python.exe","python3","python3.exe"}:\n            if readonly_python(args):return None,None\n            rest=list(args)', 1)
start=source.index('def is_check_only(')
end=source.index('\ndef adapt_shell(',start)
source=source[:start]+'''def is_check_only(command: str, shell: str) -> bool:
    # Classify the actual literal executable, never tool names inside code/comments.
    # Ambiguous compound forms must be expressed as a visible supported command.
    try:
        exe,args=unwrap(words(command,shell),shell)
        stem=ntpath.splitext(ntpath.basename(canonical(exe)))[0]
        if stem not in CHECK_TOOLS:return False
        return not any(a.lower()==flag or a.lower().startswith(flag+'=')
                       for a in args for flag in CHECK_REFUSED_ARGS)
    except (Refusal,ValueError,IndexError):return False

''' + source[end:]
source=source.replace('if is_check_only(command):','if is_check_only(command,shell):',1)
assert source != original.decode('utf-8')
candidate=source.encode('utf-8')
(ROOT/'shared_quartus_queue_hook.original.py').write_bytes(original)
(ROOT/'shared_quartus_queue_hook.py').write_bytes(candidate)
(ROOT/'guard.patch').write_text(''.join(difflib.unified_diff(original.decode('utf-8').splitlines(True),source.splitlines(True),fromfile=str(ORIGINAL),tofile='candidate/shared_quartus_queue_hook.py')),encoding='utf-8')
for name in ['deployment_receipt','deployment_verification','deployed_classification_receipt','test_receipt']:
    p=ROOT/(name+'.json'); saved=ROOT/(name+'.initial8fe.json')
    if p.exists() and not saved.exists():saved.write_bytes(p.read_bytes())
(ROOT/'manifest.json').write_text(json.dumps({'original_path':str(ORIGINAL),'original_sha256':sha(original),'deploy_from_sha256':sha(live),'candidate_sha256':sha(candidate),'patch_sha256':sha((ROOT/'guard.patch').read_bytes()),'scope':'PreToolUse classification only; no hook-config/controller/queue-worker changes, no execution or permission-allow rewrite'},indent=2)+'\n',encoding='utf-8')
print(json.dumps({'original':sha(original),'candidate':sha(candidate),'stage':str(ROOT)}))
