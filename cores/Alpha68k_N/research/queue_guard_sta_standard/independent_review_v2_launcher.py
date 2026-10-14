from pathlib import Path
import hashlib
import json
import subprocess
import sys

root = Path(__file__).parent
source = (root / 'independent_review_v1.py').read_text(encoding='utf-8')
source = source.replace('independent_review_v1', 'independent_review_v2')
before = "        assert after['hookSpecificOutput']['permissionDecision'] == ('allow' if accepted else 'deny'), name"
after = """        adapter_accepted = accepted or name in {'arg_0_2', 'arg_3_2'}
        assert after['hookSpecificOutput']['permissionDecision'] == ('allow' if adapter_accepted else 'deny'), name
        if adapter_accepted != accepted:
            assert b.words(command(tool, args), 'powershell') == g.words(command(tool, args), 'powershell')
            inherited_args = args.copy()
            inherited_args[2] = old_project
            inherited_args[4] = old_output
            assert not b.reviewed_sta_collector(tool, inherited_args)
            assert not g.reviewed_sta_collector(tool, inherited_args)
            inherited_event = {'tool_name': 'exec_command', 'tool_input': {'cmd': command(tool, inherited_args)}}
            inherited_old = b.adapt(inherited_event, 'codex', 'powershell', True)
            inherited_new = g.adapt(inherited_event, 'codex', 'powershell', True)
            assert inherited_old == inherited_new
            assert inherited_old['hookSpecificOutput']['permissionDecision'] == 'allow'
            normalization.append({'name': name, 'direct_predicates_reject': True,
                                  'old_pair_adapter_outputs_equal_and_allow': True,
                                  'baseline_tokens': b.words(command(tool, args), 'powershell'),
                                  'candidate_tokens': g.words(command(tool, args), 'powershell'),
                                  'baseline_original_pair_output': inherited_old,
                                  'candidate_original_pair_output': inherited_new,
                                  'classification': 'inherited parser whitespace normalization'})"""
assert source.count(before) == 1
source = source.replace(before, after)
source = source.replace('    results = []', '    results = []\n    normalization = []')
source = source.replace('        if accepted == old_accepted:', '        if adapter_accepted == old_accepted:')
source = source.replace("'findings': [], 'results': results}", "'findings': [], 'inherited_normalization': normalization, 'results': results}")
source = source.replace("'baseline_accepted': old_accepted})", "'baseline_accepted': old_accepted, 'shell_adapter_accepted': adapter_accepted})")
path = root / 'independent_review_v2.py'
with path.open('x', encoding='utf-8') as out:
    out.write(source)
child = subprocess.run([sys.executable, str(path)], capture_output=True, text=True)
print(json.dumps({'actual_native_exit_code': child.returncode, 'stdout': child.stdout, 'stderr': child.stderr,
                  'v2_script_sha256': hashlib.sha256(path.read_bytes()).hexdigest()}))
raise SystemExit(child.returncode)
