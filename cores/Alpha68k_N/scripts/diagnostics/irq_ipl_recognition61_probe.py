"""Private, frozen-source real CPU interrupt observer. Run with Ubuntu Python."""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import time

def resolve_evidence_root():
    """Explicit evidence root or nearest marked project, within eight ancestors."""
    override = os.environ.get('ALPHA68KN_EVIDENCE_ROOT')
    if override is not None:
        if not override.strip():
            raise ValueError('ALPHA68KN_EVIDENCE_ROOT must be an absolute project path')
        candidate = Path(override).expanduser()
        if not candidate.is_absolute():
            raise ValueError('ALPHA68KN_EVIDENCE_ROOT must be absolute')
        candidate = candidate.resolve()
        if not ((candidate / 'plan.md').is_file() and
                (candidate / 'rtl/alpha68kn_board.sv').is_file()):
            raise FileNotFoundError('Evidence root lacks plan.md or rtl/alpha68kn_board.sv: ' + str(candidate))
        return candidate
    for candidate in list(Path(__file__).resolve().parents)[:8]:
        if ((candidate / 'plan.md').is_file() and
                (candidate / 'rtl/alpha68kn_board.sv').is_file()):
            return candidate
    raise FileNotFoundError('No marked project in eight ancestors; set ALPHA68KN_EVIDENCE_ROOT')


ROOT = resolve_evidence_root()
NAME = 'irq_ipl_recognition61'
RESEARCH = ROOT / 'research'
CAPTURE = ROOT / 'sim/captures/rtl' / NAME
PRIVATE = ROOT / 'sim/captures/diagnostics' / (NAME + '_source')


def sha(p):
    return hashlib.sha256(Path(p).read_bytes()).hexdigest()


def receipt(suffix, obj):
    p = RESEARCH / (NAME + '_' + suffix + '.json')
    with p.open('x', encoding='utf-8') as f:
        json.dump(obj, f, indent=2)
        f.write('\n')


FIELDS = [
    ('irq1', 'board', 1), ('irq2', 'board', 1), ('level', 'board', 3),
    ('cpu_phase', 'board', 3),
    ('IPL0n', 'maincpu', 1), ('IPL1n', 'maincpu', 1), ('IPL2n', 'maincpu', 1),
    ('Clks', 'maincpu', 5), ('rIpl', 'maincpu', 3), ('iIpl', 'maincpu', 3),
    ('intPend', 'maincpu', 1), ('inl', 'maincpu', 3),
    ('updIll', 'maincpu', 1), ('microLatch', 'maincpu', 17),
    ('enT1', 'maincpu', 1), ('enT4', 'maincpu', 1),
    ('pswI', 'maincpu', 3), ('prevNmi', 'maincpu', 1), ('Iac', 'maincpu', 1),
    ('PcH', 'excUnit', 16), ('PcL', 'excUnit', 16),
]


def main():
    assert os.name == 'posix' and str(ROOT).startswith('/mnt/d/'), 'Use explicit Ubuntu WSL'
    assert not CAPTURE.exists() and not PRIVATE.exists(), 'Preserve prior evidence'
    baseline = RESEARCH / 'irq_sampling_edge_latch61_job.json'
    frozen = json.loads(baseline.read_text())
    base_host = ROOT / 'sim/captures/diagnostics/irq_sampling_edge_latch61_source/system_main.cpp'
    assert sha(base_host) == frozen['generated_host_sha256']
    for rel, digest in frozen['source_pins'].items():
        assert sha(ROOT / rel) == digest, rel
    input_path = ROOT / 'sim/captures/kyros/warm_reset960_refv2/frame_states.csv'
    rom = ROOT / 'roms/kyros/download.bin'
    assert sha(input_path) == frozen['input_trace_sha256']
    assert sha(rom) == frozen['rom_sha256']
    PRIVATE.mkdir()
    CAPTURE.mkdir()
    build = Path(tempfile.mkdtemp(prefix='alpha68kn-ipl61.', dir='/mnt/d/vibes/fpga/temp'))
    for name, rel in frozen['compile_file_origins'].items():
        shutil.copy2(ROOT / rel, build / name)
    config = '`verilator_config\n'
    for field, scope, _ in FIELDS:
        module = {'board': 'alpha68kn_board', 'maincpu': 'fx68k', 'excUnit': 'excUnit'}[scope]
        config += 'public_flat_rd -module "' + module + '" -var "' + field + '"\n'
    (build / 'observer.vlt').write_text(config)
    (PRIVATE / 'observer.vlt').write_text(config)
    host = base_host.read_text()
    stream_anchor = '    std::ofstream applied_inputs(output/"applied_inputs.csv");'
    assert host.count(stream_anchor) == 1
    names = [f[0] for f in FIELDS]
    header = 'tick,frame,address,attrs_before,attrs_after,' + ','.join(n + '_' + side for side in ['before', 'after'] for n in names)
    observer = '    std::ofstream ipl_phase(output/"ipl_phase.csv");\n'
    observer += '    ipl_phase<<"' + header + '\\n";\n'
    observer += '    uint64_t ipl_follow_until=0;\n'
    observe_lambda = '    auto observe_ipl=[&]() { auto *p=top.rootp; return std::vector<uint32_t>{'
    observe_lambda += ','.join('unsigned(p->@' + scope + '.' + field + '@)' for field, scope, _ in FIELDS)
    observe_lambda += '}; };\n'
    host = host.replace(stream_anchor, observer + stream_anchor)
    assert host.count('    Valpha68kn_system top;\n') == 1
    host = host.replace('    Valpha68kn_system top;\n', '    Valpha68kn_system top;\n' + observe_lambda)
    anchor = '        tick();\n        if(e_window) {'
    assert host.count(anchor) == 1
    observation = '''        bool ipl_roi=frame>=58 && frame<=60;
        std::vector<uint32_t> ipl_before;
        if(ipl_roi) ipl_before=observe_ipl();
        tick();
        if(ipl_roi) {
            auto ipl_after=observe_ipl();
            if(ipl_before[0] || ipl_before[1] || ipl_after[0] || ipl_after[1] ||
               ((attrs | top.debug_main_attrs)&8)) ipl_follow_until=ticks-started+512;
            if(ticks-started<=ipl_follow_until) {
                ipl_phase<<ticks-started<<','<<frame<<','<<address<<','<<unsigned(attrs)<<','<<unsigned(top.debug_main_attrs);
                for(auto v:ipl_before) ipl_phase<<','<<v;
                for(auto v:ipl_after) ipl_phase<<','<<v;
                ipl_phase<<'\\n';
            }
        }
        if(e_window) {'''
    host = host.replace(anchor, observation)
    (build / 'system_main.cpp').write_text(host)
    command = list(frozen['build_command'])
    command.remove('--build')
    command[command.index('-o') + 1] = NAME + '_sim'
    command[command.index('alpha68kn_board.sv'):command.index('alpha68kn_board.sv')] = ['observer.vlt']
    command = [str(build / 'system_main.cpp') if x.endswith('/system_main.cpp') else x for x in command]
    version = subprocess.check_output([command[0], '--version'], text=True).strip()
    assert version == frozen['verilator_version'], version
    job = dict(worker_pid=os.getpid(), started=time.time(), frames=61,
               source_parent=frozen['source_parent'], source_pins=frozen['source_pins'],
               baseline_job_sha256=sha(baseline), baseline_host_sha256=sha(base_host),
               input_trace_sha256=sha(input_path), rom_sha256=sha(rom),
               compile_file_origins=frozen['compile_file_origins'], build_root=str(build),
               verilator_version=version, generation_command=command,
               observer_configuration_sha256=sha(build / 'observer.vlt'),
               helper_sha256=sha(__file__),
               scope='Read-only retained actual CPU IPL recognition; unchanged frozen production RTL, tick calls, inputs and native rendering. No physical-cause or fix claim.')
    receipt('job', job)
    log = open(CAPTURE / 'build.log', 'w')
    generate = subprocess.Popen(command, cwd=build, stdout=log, stderr=subprocess.STDOUT)
    receipt('generation_running', dict(pid=generate.pid, worker_pid=os.getpid(), started=time.time()))
    code = generate.wait()
    receipt('generation_exit', dict(pid=generate.pid, exit_code=code, ended=time.time()))
    assert code == 0, 'Verilator generation failed'
    root_header = build / 'obj/Valpha68kn_system___024root.h'
    text = root_header.read_text()
    mapping = {}
    for field, scope, width in FIELDS:
        candidates = re.findall(r'\b([A-Za-z_][A-Za-z_0-9]*' + re.escape('__DOT__' + scope + '__DOT__' + field) + r')\s*;', text)
        assert len(candidates) == 1, (field, candidates)
        member = candidates[0]
        line = next(s.strip() for s in text.splitlines() if member + ';' in s)
        assert '/*' + str(width - 1) + ':0*/' in line, (field, line)
        mapping[field] = dict(member=member, width=width, header_line=line)
        host = host.replace('@' + scope + '.' + field + '@', member)
    assert '@' not in host
    (build / 'system_main.cpp').write_text(host)
    (PRIVATE / 'system_main.cpp').write_text(host)
    receipt('source', dict(generated_host_sha256=sha(build / 'system_main.cpp'),
                          retained_header_sha256=sha(root_header), field_mapping=mapping,
                          baseline_host_sha256=sha(base_host), source_pins=frozen['source_pins'],
                          source_changes='Observer streams, read-only lambda after top declaration, and observer around existing tick; no RTL changes',
                          observer_configuration_sha256=sha(build / 'observer.vlt')))
    make = ['make', '-C', 'obj', '-f', 'Valpha68kn_system.mk', '-j4']
    process = subprocess.Popen(make, cwd=build, stdout=log, stderr=subprocess.STDOUT)
    receipt('build_running', dict(pid=process.pid, worker_pid=os.getpid(), command=make, started=time.time()))
    code = process.wait()
    log.close()
    receipt('build_exit', dict(pid=process.pid, exit_code=code, ended=time.time()))
    assert code == 0, 'Private build failed'
    exe = CAPTURE / (NAME + '_sim')
    shutil.copy2(build / 'obj' / (NAME + '_sim'), exe)
    run = [str(exe), str(rom), '61', str(CAPTURE), 'gameplay', '--inputs', str(input_path)]
    with open(CAPTURE / 'run.log', 'w') as out:
        sim = subprocess.Popen(run, cwd=build, stdout=out, stderr=subprocess.STDOUT)
        receipt('running', dict(pid=sim.pid, worker_pid=os.getpid(), command=run,
                                executable_sha256=sha(exe), started=time.time()))
        code = sim.wait()
    receipt('exit', dict(pid=sim.pid, exit_code=code, ended=time.time(),
                         executable_sha256=sha(exe)))
    assert code == 0, 'Actual replay failed'


if __name__ == '__main__':
    main()
