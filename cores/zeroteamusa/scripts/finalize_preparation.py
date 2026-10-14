"""Finish the staged references/scaffold and verify once before a local commit."""
from pathlib import Path
import hashlib, json, runpy, shutil, subprocess

ROOT=Path(__file__).resolve().parents[1]
SRC=Path(r'D:\Arcade\AI\mame289')
manifest_path=ROOT/'reference/mame/manifest.json'
manifest=json.loads(manifest_path.read_text())
known={x['path'] for x in manifest['source_files']}
extras=[SRC/'src/mame/shared/seibusound.cpp', SRC/'src/mame/shared/seibusound.h',
        SRC/'src/devices/video/bufsprite.cpp', SRC/'src/devices/video/bufsprite.h']
extras+=list((SRC/'src/devices/cpu/nec').glob('*'))
extras+=list((SRC/'3rdparty/ymfm/src').glob('*'))
for source in extras:
    if not source.is_file(): continue
    relative=source.relative_to(SRC)
    dest=ROOT/'reference/mame'/relative
    path=str(dest.relative_to(ROOT)).replace('\\','/')
    if path in known: continue
    dest.parent.mkdir(parents=True,exist_ok=True); shutil.copy2(source,dest)
    manifest['source_files'].append({'source':str(source),'path':path,'sha256':hashlib.sha256(source.read_bytes()).hexdigest()})
    known.add(path)
manifest_path.write_text(json.dumps(manifest,indent=2)+'\n')
donor_path=ROOT/'donors/manifest.json'
donors=json.loads(donor_path.read_text())
for donor in donors:
    if donor['name']=='jtcores':
        path=ROOT/'donors/jtcores'
        donor['license_files']=[str(p.relative_to(path)).replace('\\','/') for p in path.rglob('*')
                               if p.is_file() and '.git' not in p.parts and p.name.lower().startswith(('license','copying'))]
        (path/'STAGING_PROVENANCE.json').write_text(json.dumps(donor,indent=2)+'\n')
donor_path.write_text(json.dumps(donors,indent=2)+'\n')
for script in ['bootstrap_project.py','prepare_roms.py']:
    runpy.run_path(str(ROOT/'scripts'/script),run_name='__main__')

def git(*args):
    p=subprocess.run(['git',*args],cwd=ROOT,capture_output=True,text=True)
    if p.returncode: raise RuntimeError(p.stderr)
    return p.stdout.strip()

if git('branch','--show-current')!='develop': git('switch','-c','develop')
if 'origin' in git('remote').splitlines(): git('remote','rename','origin','template-upstream')
runpy.run_path(str(ROOT/'scripts/verify_preparation.py'),run_name='__main__')
git('add','--all')
tracked=git('diff','--cached','--name-only').splitlines()
if any(p.startswith('roms/') or (p.startswith('donors/') and p!='donors/manifest.json') for p in tracked):
    raise RuntimeError('Local staging entered the commit')
git('commit','-m','chore: prepare Zero Team USA scaffold, donors and simulation-first plan')
print('LOCAL_COMMIT '+git('rev-parse','HEAD'))
print('TRACKED_CHANGE_COUNT '+str(len(tracked)))
print('GIT_STATUS '+(git('status','--short') or 'clean'))
