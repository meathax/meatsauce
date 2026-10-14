"""Commit current source progress locally after checking confidential staging."""
from pathlib import Path
import subprocess
import sys
ROOT=Path(__file__).resolve().parents[1]
def git(*args):
    p=subprocess.run(['git',*args],cwd=ROOT,capture_output=True,text=True)
    if p.returncode: raise RuntimeError(p.stderr)
    return p.stdout.strip()
if git('branch','--show-current')!='develop': raise RuntimeError('Expected develop branch')
if git('diff','--name-only','--','sys/'): raise RuntimeError('MiSTer sys/ changed')
git('add','--all')
for path in git('diff','--cached','--name-only').splitlines():
    if path.startswith(('roms/','sim/results/','sim/build/')) or path.endswith(('.bin','.zip','.rbf','.sof')):
        raise RuntimeError('Confidential/generated artifact entered staging: '+path)
    if path.startswith('donors/') and path!='donors/manifest.json': raise RuntimeError('Donor checkout entered staging')
message=sys.argv[1] if len(sys.argv)>1 else 'feat: import Seibu hardware and run target V30 in Verilator'
git('commit','-m',message)
print('LOCAL_COMMIT '+git('rev-parse','HEAD'))
print('STATUS '+(git('status','--short') or 'clean'))
