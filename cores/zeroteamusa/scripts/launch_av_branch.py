"""Run a verified existing AV model with isolated frames/checkpoints (Ubuntu WSL)."""
from pathlib import Path
import argparse, csv, hashlib, json, re, subprocess, sys

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('name')
parser.add_argument('cycles', type=int)
parser.add_argument('--identity', required=True, help='Native checkpoint base for compiled-model identity')
parser.add_argument('--resume', action='store_true')
parser.add_argument('--inputs')
parser.add_argument('--binary', help='Select an isolated compiled model; its checkpoint hash must match')
parser.add_argument('--frozen-model', action='store_true',
                    help='Use the exact old compiled binary; explicitly label worktree source drift')
args = parser.parse_args()
assert sys.platform.startswith('linux'), 'Run explicitly with Ubuntu WSL python3'
assert re.fullmatch(r'[a-zA-Z0-9_-]+', args.name), 'Invalid branch name'
assert args.cycles > 0
identity = Path(args.identity).resolve()
saved = json.loads(Path(str(identity) + '.json').read_text())
sha = lambda p: hashlib.sha256(Path(p).read_bytes()).hexdigest()
files = (root/'sim/board_sources.f').read_text().splitlines()
files += (root/'sim/audio_sources.f').read_text().splitlines()
files += ['rtl/ZeroTeam_video.sv', 'sim/zero_av_top.sv', 'sim/board_main.cpp',
          'rtl/Raiden2/crypt/zeroteam_sprite_decrypt.sv', 'sim/run_av.sh']
files += [f'rtl/Raiden2/crypt/{n}.hex' for n in ['rotate_zt', 'x5_zt', 'x11_zt']]
files += [f'rtl/Raiden2/{n}.sv' for n in ['Raiden2_video_timing', 'Raiden2_text_renderer',
          'Raiden2_tile_layer', 'Raiden2_sprite_renderer', 'spram_dp',
          'tile_rom_arbiter', 'raiden2_mixer']]
if saved.get('dependency_coverage'):
    files += [p.relative_to(root).as_posix() for p in (root/'rtl').rglob('*')
              if p.is_file() and p.suffix.lower() in ('.svh', '.vh', '.hex', '.mif', '.mem')]
    files += ['scripts/snapshot_av_sources.py']
    files = sorted(set(files))
current_sources = {p: sha(root/p) for p in files}
assert current_sources.keys() == saved['sources'].keys(), 'Source closure changed'
changed = [p for p, h in current_sources.items() if h != saved['sources'][p]]
assert not changed or args.frozen_model, 'Build inputs changed; rebuild/cold boot normally first'
assert all(not p.startswith('rtl/Raiden2/crypt/') for p in changed), 'Runtime cipher tables changed'
assert {p.name: sha(p) for p in (root/'roms/regions').glob('*.bin')} == saved['rom_regions'], 'ROM inputs changed'
assert subprocess.check_output(['verilator', '--version'], text=True).strip() == saved['verilator_version']
binary = Path(args.binary).resolve() if args.binary else root/'sim/build/av/Vzero_av_top'
assert sha(binary) == saved['model_binary_sha256'], 'Compiled model changed'
assert saved['model_config'] == {'top': 'zero_av_top', 'savable': True,
                                'defines': ['CE_HALF_PLUS2', 'READY_FIXED_HIGH', 'CE_STALL_ON']}
def boot_config(path):
    if not path: return (0xffff,0x0700)
    with Path(path).open(newline='') as f:
        row=next(csv.DictReader(f))
    assert int(row['cycle'],0)==0,'Input profile must declare its reset configuration'
    return (int(row['dips'],0),int(row['system'],0)&0x0700)
if args.resume:
    previous_inputs=(saved.get('physical_inputs') or {}).get('path')
    assert boot_config(previous_inputs)==boot_config(args.inputs), \
        'Checkpoint boot DIPs/cabinet differ; use a cold run of the existing binary'
run_args = [str(args.cycles), '--tag', args.name]
stamp = {k: v for k, v in saved.items() if k not in ['run_arguments', 'resumed_from', 'physical_inputs']}
stamp['compiled_model_origin'] = binary.as_posix()
if args.frozen_model:
    stamp['frozen_model'] = {'scope': 'Exact existing compiled snapshot model; not current worktree RTL',
                             'identity_checkpoint': identity.as_posix(),
                             'current_source_mismatches': changed}
if args.resume:
    run_args += ['--load', str(identity)]
    stamp['resumed_from'] = {'base': identity.as_posix(), 'streams': {
        suffix: sha(str(identity)+suffix) for suffix in ['.rtl', '.host', '.json']}}
if args.inputs:
    inputs = Path(args.inputs).resolve()
    run_args += ['--inputs', str(inputs)]
    stamp['physical_inputs'] = {'path': inputs.as_posix(), 'sha256': sha(inputs)}
stamp['run_arguments'] = run_args
work = root/'sim/results/branches'/args.name
assert not work.exists(), 'Existing branch outputs retained; use a new name'
(work/'sim/results').mkdir(parents=True)
for name in ['rtl', 'roms']:
    (work/name).symlink_to(root/name, target_is_directory=True)
frozen_binary = work/'Vzero_av_top'
frozen_binary.write_bytes(binary.read_bytes())
frozen_binary.chmod(0o700)
assert sha(frozen_binary) == saved['model_binary_sha256']
(work/'sim/results/av-source-stamp.json').write_text(json.dumps(stamp, indent=2)+'\n')
subprocess.run([sys.executable, str(root/'scripts/validate_av_resume.py'), *run_args], cwd=work, check=True)
print(f'Verified exact existing compiled model. Isolated outputs: {work}/sim/results', flush=True)
raise SystemExit(subprocess.call([str(frozen_binary), *run_args], cwd=work))
