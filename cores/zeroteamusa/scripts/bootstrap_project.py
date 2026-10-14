"""Rename the local MiSTer template without modifying sys/ or integrating RTL."""
from pathlib import Path
import hashlib, json, shutil, subprocess

ROOT=Path(__file__).resolve().parents[1]
ref=ROOT/'reference/template'; ref.mkdir(parents=True,exist_ok=True)
for suffix in ['qpf','qsf','sdc','srf','sv']:
    source=ROOT/('Template.'+suffix)
    if source.exists():
        shutil.copy2(source,ref/source.name)
        (ROOT/('ZeroTeam.'+suffix)).write_text(source.read_text().replace('Template','ZeroTeam'),encoding='utf-8')
        source.unlink()
for name in ['Template_Q13.qpf','Template_Q13.qsf','Template_Q13.srf']:
    source=ROOT/name
    if source.exists(): shutil.copy2(source,ref/name); source.unlink()
qip=ROOT/'files.qip'
qip.write_text(qip.read_text().replace('Template.sdc','ZeroTeam.sdc').replace('Template.sv','ZeroTeam.sv'))
template=json.loads((ROOT/'reference/research/template.json').read_text())
original_readme=subprocess.run(['git','show',template['commit']+':Readme.md'],cwd=ROOT,capture_output=True,text=True,check=True).stdout
(ref/'README.md').write_text(original_readme)
# Windows treats Readme.md and README.md as the same pathname. Preserve the
# new project README and normalize its spelling through a temporary name.
for candidate in ROOT.iterdir():
    if candidate.is_file() and candidate.name.lower()=='readme.md' and candidate.name!='README.md':
        temporary=ROOT/'README.case-rename.tmp'; candidate.rename(temporary); temporary.rename(ROOT/'README.md')
license_path=ROOT/'LICENSE'
if not (ref/'LICENSE').exists(): shutil.copy2(license_path,ref/'LICENSE')
shutil.copy2(ROOT/'donors/raiden2-rmonic/LICENSE',license_path)
sys_hashes={str(p.relative_to(ROOT)).replace('\\','/'):hashlib.sha256(p.read_bytes()).hexdigest()
            for p in (ROOT/'sys').rglob('*') if p.is_file()}
(ROOT/'reference/template/sys-sha256.json').write_text(json.dumps(sys_hashes,indent=2)+'\n')
ignore=ROOT/'.gitignore'
extra='''
# Local copyrighted game data and immutable donor workspaces.
/roms/
/donors/*
!/donors/manifest.json
/mister.env
/sim/build/
/sim/results/
/reference/research/rmonic79-repositories.json
__pycache__/
*.pyc
# MAME listxml is reference metadata, not ROM content.
!/reference/mame/zeroteam.xml
'''
if '/roms/' not in ignore.read_text(): ignore.write_text(ignore.read_text()+extra)
print('ZeroTeam template scaffold prepared; sys/ preserved byte-for-byte.')
