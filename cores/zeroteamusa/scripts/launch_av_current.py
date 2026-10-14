"""Freeze current AV sources and cold-build/run them separately in Ubuntu WSL."""
from pathlib import Path
import argparse, hashlib, json, os, shutil, subprocess, sys, re

root = Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('name')
p.add_argument('cycles', type=int)
p.add_argument('--inputs')
p.add_argument('--build-only', action='store_true', help='Freeze and compile a model without cold-running it')
a = p.parse_args()
assert sys.platform.startswith('linux'), 'Run explicitly with Ubuntu WSL python3'
assert re.fullmatch(r'[a-zA-Z0-9_-]+', a.name) and a.cycles > 0
work = root/'sim/results/current-builds'/a.name
assert not work.exists(), 'Retain existing evidence; use a new name'
sha = lambda path: hashlib.sha256(Path(path).read_bytes()).hexdigest()
files = [q.relative_to(root) for q in (root/'rtl').rglob('*') if q.is_file()]
files += [Path('scripts')/n for n in ['board_sources.py', 'audio_sources.py',
                                    'snapshot_av_sources.py', 'validate_av_resume.py']]
files += [Path('sim')/n for n in ['run_av.sh', 'zero_board_top.sv', 'zero_av_top.sv', 'board_main.cpp']]
before = {q.as_posix(): sha(root/q) for q in files}
roms = {q.name: sha(q) for q in (root/'roms/regions').glob('*.bin')}
for q in files:
    destination = work/q
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(root/q, destination)
assert {q.as_posix(): sha(work/q) for q in files} == before, 'Sources changed during copying'
assert {q.as_posix(): sha(root/q) for q in files} == before, 'Sources changed during snapshot'
(work/'roms').symlink_to(root/'roms', target_is_directory=True)
run = [str(a.cycles), '--tag', a.name]
if a.inputs:
    run += ['--inputs', str(Path(a.inputs).resolve())]
meta = {'scope': 'Immutable copied current AV sources; '+('build only' if a.build_only else 'fresh cold boot'),
        'source_workspace': root.as_posix(), 'sources': before, 'rom_regions': roms,
        'run_arguments': run}
(work/'current-snapshot.json').write_text(json.dumps(meta, indent=2)+'\n')
print(f'Frozen {len(files)} current source/support files in {work}', flush=True)
env = os.environ.copy()
if a.build_only:env['ZERO_SIM_BUILD_ONLY'] = '1'
raise SystemExit(subprocess.call(['bash', 'sim/run_av.sh', *run], cwd=work, env=env))
