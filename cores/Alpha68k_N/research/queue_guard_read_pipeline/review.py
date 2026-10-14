from pathlib import Path
import hashlib, importlib.util, json, sys, difflib

root = Path(__file__).parent
def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()
def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

candidate = root / 'candidate.py'
baseline = root / 'baseline.py'
global_path = Path(r'C:\Users\meath\.claude\skills\mister-rbf-build\scripts\shared_quartus_queue_hook.py')
expected_candidate = 'afcf3db289db892de176c233b411a267d1c687012e1334988a83ffd8b3efbf04'
expected_baseline = '9d979f3f7ec0e74693f3d6405fb98cd777c5153b6cb747e772a3da0154c5749e'
g = load('independent_candidate', candidate)
b = load('independent_baseline', baseline)
q = json.loads((root / 'qualification.json').read_text(encoding='utf-8'))
pins = {'candidate': digest(candidate), 'baseline': digest(baseline), 'global': digest(global_path)}
assert pins['candidate'] == expected_candidate
assert pins['baseline'] == expected_baseline
assert pins['global'] == expected_baseline, pins
assert q['pass'] and q['candidate_sha256'] == expected_candidate and q['baseline_sha256'] == expected_baseline

safe = [
    "Get-Content -LiteralPath 'a|quartus_asm;$(thing).txt' | Select-Object -First 3",
    "Get-Content -LiteralPath 'a''b|quartus.txt' | Select-Object -Skip 0 -First 1",
    'Get-Content -LiteralPath "quartus|notes.txt" | Select-Object -First 2',
    "Get-Content -TotalCount 5 -LiteralPath 'quartus.txt' | Select-Object -First 2",
    "Get-CimInstance Win32_Process -Filter \"Name LIKE 'quartus%'\" | Select-Object ProcessId,CommandLine | Format-List",
    "Get-CimInstance -ClassName Win32_Process -Filter 'Name=" + '"quartus_asm.exe"' + "' | Format-List",
    "Get-CimInstance Win32_Process | Select-Object -Property ProcessId -First 1",
]
seed = "Get-Content -LiteralPath 'quartus.txt' | Select-Object -First 3"
unsafe = [
    seed + ' | Stop-Process', seed + ' | Invoke-Expression', seed + ' | % { quartus_asm }',
    seed + ' | & quartus_asm', seed + '; quartus_asm', seed + ' && quartus_asm',
    seed + ' & quartus_asm', seed + ' > quartus.txt', seed + ' 2>&1',
    seed.replace('-First 3', '-First (quartus_asm)'),
    seed.replace('-First 3', '-First $(quartus_asm)'),
    seed.replace('-First 3', '-First ${quartus}'),
    seed.replace('-First 3', '-Property @{Name="quartus";Expression={quartus_asm}}'),
    seed.replace('-First 3', '-Property {quartus_asm}'),
    seed.replace('-First 3', '-ExpandProperty quartus'),
    seed.replace('-First 3', '-First 3 -OutVariable quartus'),
    seed.replace('-First 3', '-First 3 -PipelineVariable quartus'),
    seed.replace('-First 3', '-First 3 -Property PSObject.Methods'),
    seed.replace('-First 3', '-First 3 -Property A,,B'),
    seed.replace('-First 3', '-First +3'), seed.replace('-First 3', '-First 3.0'),
    seed.replace('-First 3', '-First 3e0'), seed.replace('-First 3', '-First 0x3'),
    seed.replace('-First 3', '-First ٣'), seed.replace('-First 3', '-First ' + '1' * 5000),
    seed.replace('-First 3', '-First 3 -First 2'),
    seed.replace('-First 3', '-Skip 1000001 -First 3'),
    seed.replace("'quartus.txt'", '$(quartus_asm)'),
    seed.replace("'quartus.txt'", '"${quartus}"'),
    seed.replace("'quartus.txt'", '"`"quartus_asm"'),
    seed.replace(' | ', ' `| '), seed.replace(' | ', ' || '),
    seed.replace('Select-Object', 'Select`-Object'), seed.replace('Select-Object', 'Where-Object'),
    seed.replace('Select-Object', 'select'), seed.replace('Get-Content', 'gc'),
    seed.replace('Get-Content', "& (Get-Command 'quartus_asm')"),
    "Get-CimInstance Win32_Process -CimSession quartus | Format-List",
    "Get-CimInstance Win32_Process -ComputerName quartus | Format-List",
    "Get-CimInstance Win32_Process -Namespace root/quartus | Format-List",
    "Get-CimInstance Win32_Process -Query quartus | Format-List",
    "Get-CimInstance Win32_Process | Invoke-CimMethod -MethodName Terminate",
    "Get-CimInstance Win32_Process | Select-Object ProcessId | Format-List | Stop-Process",
    "Get-CimInstance Win32_Process | Format-List -Force quartus",
    "Get-CimInstance Win32_Process | Format-List @{Expression={quartus_asm}}",
    "Get-CimInstance Win32_Process | Format-List quartus > outfile",
    "rg --pre quartus_asm quartus .", "rg --pre=quartus_asm quartus .",
]
for sep in ['\n', '\r', '\r\n']:
    unsafe += [seed + sep + 'quartus_asm', seed.replace(' | ', ' | ' + sep), seed.replace(' | ', ' `' + sep + '| ')]
unsafe += [seed + '\0', seed + 'x' * 32768]

results = []
for accepted, commands in [(True, safe), (False, unsafe)]:
    for command in commands:
        actual = g.readonly_shell_evidence(command, 'powershell')
        outputs = {}
        for carrier, event in [
            ('exec', {'tool_name': 'exec_command', 'tool_input': {'cmd': command}}),
            ('capsule', {'tool_name': 'mcp__capsule__capsule', 'tool_input': {'action': 'run', 'payload': {'command': command, 'cwd': str(root), 'capsule_force': True}}}),
        ]:
            output = g.adapt(event, 'codex', 'powershell', True)
            old = b.adapt(event, 'codex', 'powershell', True)
            outputs[carrier] = output
            assert output == ({} if accepted else old), (accepted, command, carrier, output, old)
        assert actual == accepted, (accepted, command, actual)
        results.append({'expected_read_exemption': accepted, 'actual_read_exemption': actual, 'command': command, 'outputs': outputs})

receipt = {'pass': True, 'pins': pins, 'builder_claimed_checks': q['checks'], 'independent_cases': len(results), 'dangerous_commands_executed': False, 'scope': 'Frozen diff; full raw builder qualification pins; pure read classifier and exec/Capsule adapters. No shell command under test was executed.', 'findings': [], 'results': results}
(root / 'review.json').write_text(json.dumps(receipt, indent=2) + '\n', encoding='utf-8')
print(json.dumps({k:v for k,v in receipt.items() if k != 'results'}))
