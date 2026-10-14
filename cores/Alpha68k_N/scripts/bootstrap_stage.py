"""Stage public donor source and locally supplied ROMs; never run Quartus."""
from pathlib import Path
import concurrent.futures
import hashlib
import json
import shutil
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
DONORS = [
    ('snk_triplez80', 'MiSTer-devel/Arcade-SNK_TripleZ80_MiSTer', []),
    ('fx68k', 'ijor/fx68k', []),
    ('jt12', 'jotego/jt12', []),
    ('jt49', 'jotego/jt49', []),
    ('t80', 'MiSTer-devel/T80', []),
    ('t48', 'devsaurus/t48', []),
    ('jtcores', 'jotego/jtcores', ['modules/jt680x', 'modules/jtframe', 'cores/kiwi']),
    ('alpha68k', 'va7deo/alpha68k', []),
    ('nmk16', 'kuzearcade/Arcade-NMK16_MiSTer', ['rtl/m68705', 'tools', 'docs']),
    ('ql', 'MiSTer-devel/QL_MiSTer', ['rtl/T48']),
    ('hiscores', 'MiSTer-devel/Hiscores_MiSTer', []),
    ('crt_adjust', 'rmonic79/MiSTer-CRT-Adjust', []),
]


def git(args, cwd, timeout=240):
    result = subprocess.run(['git', *args], cwd=cwd, capture_output=True,
                            text=True, encoding='utf-8', errors='replace', timeout=timeout)
    if result.returncode:
        raise RuntimeError(f'git {args}: exit={result.returncode} {result.stderr[-1600:]}')
    return result.stdout.strip()


def stage_donor(spec):
    name, repository, sparse = spec
    dest = ROOT / 'donors' / name
    url = f'https://github.com/{repository}.git'
    if not (dest / '.git').exists():
        args = ['clone', '--depth', '1']
        if sparse:
            args += ['--filter=blob:none', '--sparse']
        args += [url, str(dest)]
        git(args, ROOT)
    if sparse:
        git(['sparse-checkout', 'set', *sparse], dest)
    # jt03 instantiates its own pinned jt49 dependency. Retrieve recorded gitlinks.
    if name in ('jt12', 'alpha68k', 'snk_triplez80', 't48') and (dest / '.gitmodules').exists():
        git(['submodule', 'update', '--init', '--recursive', '--depth', '1'], dest)
    tracked = git(['ls-files'], dest).splitlines()
    files = [p for p in tracked if (dest / p).is_file()]
    licenses = [p for p in files if any(x in Path(p).name.lower()
                for x in ('license', 'licence', 'copying'))]
    result = {'name': name, 'url': url, 'commit': git(['rev-parse', 'HEAD'], dest),
              'path': dest.relative_to(ROOT).as_posix(), 'sparse_paths': sparse,
              'files': len(files), 'bytes': sum((dest / p).stat().st_size for p in files),
              'license_files': licenses, 'submodules': git(['submodule', 'status', '--recursive'], dest),
              'status': 'staged'}
    (dest / 'STAGED_PROVENANCE.json').write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
    return result


def main():
    for name in ['donors', 'roms', 'research/mame0289', 'research/online', 'docs', 'sim', 'rtl', 'releases']:
        (ROOT / name).mkdir(parents=True, exist_ok=True)
    ignore = ROOT / '.gitignore'
    extra = '\n# Alpha68k N local staging and generated evidence\n/roms/\n/donors/\n/research/online/\n/research/mame0289/\n/sim/build/\n/sim/captures/\n/artifacts/\n/mister.env\n/__pycache__/\n*.pyc\n'
    if '# Alpha68k N local staging' not in ignore.read_text():
        with ignore.open('a', encoding='utf-8', newline='\n') as f:
            f.write(extra)
    template_commit = git(['rev-parse', 'HEAD'], ROOT)
    if (ROOT / 'Template.qpf').exists():
        for ext in ['qpf', 'qsf', 'sdc', 'srf', 'sv']:
            source = ROOT / ('Template.' + ext)
            if source.exists():
                source.rename(ROOT / ('Alpha68k_N.' + ext))
        for name in ['Alpha68k_N.qpf', 'Alpha68k_N.qsf', 'Alpha68k_N.sdc', 'files.qip']:
            p = ROOT / name
            p.write_text(p.read_text().replace('Template.', 'Alpha68k_N.').replace('"Template"', '"Alpha68k_N"'), encoding='utf-8', newline='\n')
        qpf = ROOT / 'Alpha68k_N.qpf'
        qpf.write_text(qpf.read_text().replace('Template', 'Alpha68k_N'), encoding='utf-8', newline='\n')
        top = ROOT / 'Alpha68k_N.sv'
        top.write_text(top.read_text().replace('"Template;', '"Alpha68k N;'), encoding='utf-8', newline='\n')
        # Keep the untouched legacy Q13 files as template references, never active projects.
    if git(['branch', '--show-current'], ROOT) != 'develop':
        git(['checkout', '-b', 'develop'], ROOT)
    if 'origin' in git(['remote'], ROOT).splitlines():
        git(['remote', 'rename', 'origin', 'template'], ROOT)
    source_root = Path(r'D:\Arcade\AI\mame289')
    sources = ['src/mame/alpha/alpha68k_n.cpp', 'src/mame/alpha/alpha68k.h',
               'src/mame/alpha/alpha68k.cpp', 'src/mame/alpha/alpha68k_v.cpp',
               'src/mame/shared/alpha68k_palette.cpp', 'src/mame/shared/alpha68k_palette.h',
               'src/devices/cpu/m6805/m6805.cpp', 'src/devices/cpu/m6805/m68705.cpp',
               'src/devices/cpu/mcs48/mcs48.cpp', 'src/devices/sound/ay8910.cpp',
               'src/devices/sound/ymopn.cpp', 'src/devices/sound/dac.h', 'COPYING']
    reference = []
    for rel in sources:
        p = source_root / rel
        if p.exists():
            dest = ROOT / 'research/mame0289' / rel
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(p, dest)
            reference.append({'source': str(p), 'path': dest.relative_to(ROOT).as_posix(),
                              'sha256': hashlib.sha256(p.read_bytes()).hexdigest()})
    roms = []
    for name in ['kyros.zip', 'sstingry.zip']:
        source = Path(r'D:\Arcade\AI\MAME 0.289 ROMs (merged)') / name
        if not source.exists():
            raise FileNotFoundError(source)
        dest = ROOT / 'roms' / name
        shutil.copy2(source, dest)
        roms.append({'source': str(source), 'path': dest.relative_to(ROOT).as_posix(),
                     'bytes': dest.stat().st_size, 'sha256': hashlib.sha256(dest.read_bytes()).hexdigest()})
    (ROOT / 'research/source_manifest.json').write_text(json.dumps({'template': {'url': 'https://github.com/MiSTer-devel/Template_MiSTer', 'commit': template_commit}, 'mame': reference, 'roms': roms}, indent=2) + '\n', encoding='utf-8')
    lock = []
    failures = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
        jobs = {pool.submit(stage_donor, spec): spec[0] for spec in DONORS}
        for job in concurrent.futures.as_completed(jobs):
            name = jobs[job]
            try:
                item = job.result()
                lock.append(item)
                print(f'STAGED {name} {item["commit"]} files={item["files"]}', flush=True)
            except Exception as e:
                failures.append({'name': name, 'error': str(e)})
                print(f'FAILED {name}: {e}', flush=True)
    (ROOT / 'donors.lock.json').write_text(json.dumps({'donors': sorted(lock, key=lambda x: x['name']), 'failures': failures}, indent=2) + '\n', encoding='utf-8')
    print(f'Bootstrap: {len(lock)} donors; {len(roms)} local ROM archives; {len(reference)} MAME references. No FPGA tools invoked.', flush=True)
    return bool(failures)


if __name__ == '__main__':
    sys.exit(main())
