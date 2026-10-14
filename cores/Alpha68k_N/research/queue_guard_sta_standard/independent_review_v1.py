from pathlib import Path
import ast
import hashlib
import importlib.util
import json
import subprocess
import sys
from unittest.mock import patch

ROOT = Path(__file__).parent
BASELINE = 'a9ee073877dcb63434ab9282ce97b87cbdcbfe93ced24462bf198fccc85dcf6d'
CANDIDATE = '5adad4cdbac0382e9d3a55582b7629ef69a69ddfac97d85dffe49a52980028a3'
COLLECTORS = {
    'all-corners.tcl': '3309f3c72b10bdc50443f4891f5791f08748dd4ce9df5fc451d4ec650176780a',
    'all-corners-detail.tcl': 'ab3bffea354fa2dd1aa70cc98d8e128cd7c6bf64045c7b14e86e0f93bac02aab',
}
CHECK = 'D:/Arcade/AI/aCORES/Alpha68k N/research/sound_write_width/'
EXE = 'D:/q17/quartus/bin64/quartus_sta.exe'

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

def write_new(name, content):
    with (ROOT / name).open('x', encoding='utf-8') as handle:
        handle.write(json.dumps(content, indent=2) + '\n')

def worker():
    assert digest(ROOT / 'baseline.py') == BASELINE
    assert digest(ROOT / 'candidate.py') == CANDIDATE
    b = load('independent_standard_baseline', ROOT / 'baseline.py')
    g = load('independent_standard_candidate', ROOT / 'candidate.py')
    trees = [ast.parse((ROOT / name).read_text(encoding='utf-8')) for name in ('baseline.py', 'candidate.py')]
    target = 'reviewed_sta_collector'
    for tree in trees:
        assert sum(isinstance(n, ast.FunctionDef) and n.name == target for n in tree.body) == 1
        tree.body = [n for n in tree.body if not (isinstance(n, ast.FunctionDef) and n.name == target)]
    assert ast.dump(trees[0]) == ast.dump(trees[1]), 'Policy changed outside target predicate'
    collector_pins = {}
    for name, expected in COLLECTORS.items():
        path = Path(CHECK + 'case2_fit_sta/' + name)
        collector_pins[str(path)] = digest(path)
        assert collector_pins[str(path)] == expected
    proof_pins = {}
    for name, count in [('qualification.json', 155), ('collector_qualification.json', 181), ('detail_qualification.json', 204), ('standard_qualification.json', 231)]:
        path = ROOT / name
        proof = json.loads(path.read_text(encoding='utf-8'))
        actual = proof.get('total_checks', proof.get('checks'))
        if isinstance(actual, (list, dict)):
            actual = len(actual)
        assert proof.get('pass') is True and actual == count, (name, actual)
        proof_pins[name] = {'sha256': digest(path), 'source_case_count': count}
    results = []
    q = lambda s: "'" + s.replace("'", "''") + "'"
    command = lambda tool, args: '& ' + q(tool) + ' ' + ' '.join(q(a) for a in args)
    old_project = CHECK + 'case2_full_map/Alpha68k_N'
    old_output = CHECK + 'case2_fit_sta/all-corners'
    new_project = CHECK + 'case2_standard_fit/Alpha68k_N'
    new_output = CHECK + 'case2_standard_fit_evidence/all-corners'
    detail = CHECK + 'case2_fit_sta/all-corners-detail.tcl'
    plain = CHECK + 'case2_fit_sta/all-corners.tcl'
    good = ['-t', detail, new_project, 'Alpha68k_N', new_output]

    def case(name, tool, args, accepted, old_accepted=False):
        assert g.reviewed_sta_collector(tool, args) is accepted, name
        assert b.reviewed_sta_collector(tool, args) is old_accepted, name
        event = {'tool_name': 'exec_command', 'tool_input': {'cmd': command(tool, args)}}
        before = b.adapt(event, 'codex', 'powershell', True)
        after = g.adapt(event, 'codex', 'powershell', True)
        assert after['hookSpecificOutput']['permissionDecision'] == ('allow' if accepted else 'deny'), name
        assert 'updatedInput' not in after['hookSpecificOutput'], name
        if accepted == old_accepted:
            assert before == after, name
        results.append({'name': name, 'accepted': accepted, 'baseline_accepted': old_accepted})

    for collector in [plain, detail]:
        case('old_pair_' + Path(collector).name, EXE, ['-t', collector, old_project, 'Alpha68k_N', old_output], True, True)
    case('new_pair', EXE, good, True)
    case('new_pair_backslashes', EXE.replace('/', '\\'), [a.replace('/', '\\') for a in good], True)
    for project in [old_project, new_project]:
        for output in [old_output, new_output]:
            for collector in [plain, detail]:
                expected = (project == old_project and output == old_output) or (project == new_project and output == new_output and collector == detail)
                prior = project == old_project and output == old_output
                case('matrix_' + project.split('/')[-2] + '_' + output.split('/')[-2] + '_' + Path(collector).name, EXE, ['-t', collector, project, 'Alpha68k_N', output], expected, prior)
    for i, values in enumerate([
        ['--script', '-T', '-t '],
        [detail + '.bad', 'all-corners-detail.tcl', CHECK + 'case2_fit_sta/unreviewed.tcl'],
        [new_project + '2', 'Alpha68k_N', CHECK + 'case2_standard_fit/Other'],
        ['alpha68k_n', 'Other', 'Alpha68k_N '],
        [new_output + '2', 'all-corners', CHECK + 'case2_fit_sta/all-corners'],
    ]):
        for j, value in enumerate(values):
            changed = good.copy(); changed[i] = value
            case('arg_' + str(i) + '_' + str(j), EXE, changed, False)
    for name in ['quartus_sh.exe', 'quartus_asm.exe', 'quartus_cpf.exe', 'quartus_fit.exe']:
        case('wrong_executable_' + name, EXE.rsplit('/', 1)[0] + '/' + name, good, False)
    for tool in ['D:/other/quartus_sta.exe', 'D:/q17/quartus/bin/quartus_sta.exe', 'quartus_sta.exe']:
        case('wrong_tool_' + tool, tool, good, False)
    for extra in ['--eval', '--allow-rbf', '-t', ';']:
        case('extra_' + extra, EXE, good + [extra], False)
    case('missing_argument', EXE, good[:-1], False)
    for name, data in [('modified_hash', b'puts changed'), ('oversized', b'x' * 65537), ('empty', b'')]:
        with patch.object(g, 'open', create=True) as opened:
            opened.return_value.__enter__.return_value.read.return_value = data
            assert not g.reviewed_sta_collector(EXE, good)
            event = {'tool_name': 'exec_command', 'tool_input': {'cmd': command(EXE, good)}}
            assert g.adapt(event, 'codex', 'powershell', True)['hookSpecificOutput']['permissionDecision'] == 'deny'
            results.append({'name': name, 'accepted': False})
    with patch.object(g, 'open', create=True, side_effect=OSError('unreadable')):
        assert not g.reviewed_sta_collector(EXE, good)
        results.append({'name': 'unreadable', 'accepted': False})
    for suffix in ['; quartus_asm x', '\nquartus_asm x', '\rquartus_cpf x', '\r\nquartus_sh x', ' | quartus_asm x', '; Stop-Process -Id 123', ' && quartus_sh x']:
        event = {'tool_name': 'exec_command', 'tool_input': {'cmd': command(EXE, good) + suffix}}
        assert g.adapt(event, 'codex', 'powershell', True)['hookSpecificOutput']['permissionDecision'] == 'deny'
        results.append({'name': 'compound_' + repr(suffix), 'accepted': False})
    for packet in [{'command': command(EXE, good)}, {'command': EXE, 'args': good}]:
        event = {'tool_name': 'mcp__capsule__capsule', 'tool_input': {'action': 'run', 'payload': packet}}
        assert g.adapt(event, 'codex', 'powershell', True)['hookSpecificOutput']['permissionDecision'] == 'deny'
        results.append({'name': 'structured_capsule_' + str(len(packet)), 'accepted': False})
    result = {'pass': True, 'baseline_sha256': BASELINE, 'candidate_sha256': CANDIDATE,
              'policy_ast_unchanged_outside_target': True, 'collector_pins': collector_pins,
              'source_replay_receipts': proof_pins, 'independent_cases': len(results),
              'executed_quartus_or_tcl': False, 'global_deployment': False,
              'findings': [], 'results': results}
    write_new('independent_review_v1.json', result)
    print(json.dumps({k: v for k, v in result.items() if k not in {'results', 'source_replay_receipts', 'collector_pins'}}))

if __name__ == '__main__':
    if '--worker' in sys.argv:
        worker()
    else:
        child = subprocess.run([sys.executable, str(Path(__file__).resolve()), '--worker'], capture_output=True, text=True)
        write_new('independent_review_v1_exit.json', {'actual_native_exit_code': child.returncode,
                 'python': sys.executable, 'stdout': child.stdout, 'stderr': child.stderr,
                 'script_sha256': digest(Path(__file__)), 'executed_quartus_or_tcl': False})
        print(json.dumps({'actual_native_exit_code': child.returncode, 'stdout': child.stdout, 'stderr': child.stderr}))
        raise SystemExit(child.returncode)
