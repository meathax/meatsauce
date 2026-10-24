"""Cross-compile the pinned JTFRAME CLI as a Linux ELF for WSL source generation."""
from pathlib import Path
import hashlib
import json
import os
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
DONOR = ROOT/'donors/jtcores'
PINNED_DONOR = '58f29cdbc997927cf1e56961f9b36f84400e67cf'

if len(sys.argv) != 2:
    raise SystemExit('usage: python scripts/build_jtframe_linux.py <output-elf-path>')
output = Path(sys.argv[1]).resolve()
subprocess.run([sys.executable, str(ROOT/'scripts/prepare_donor.py')], cwd=ROOT, check=True)
head = subprocess.check_output(['git', '-C', str(DONOR), 'rev-parse', 'HEAD'], text=True).strip()
if head != PINNED_DONOR:
    raise SystemExit(f'unexpected JTFRAME donor commit: {head}')
source = DONOR/'modules/jtframe/src/jtframe'
macro_source = source/'macros/macros.go'
macro_text = macro_source.read_text(encoding='utf-8')
anchor = 'func make_clocks(target string) (mclk int) {\n'
if macro_text.count(anchor) != 1 or 'target = strings.ToUpper(target)' not in macro_text:
    raise SystemExit('target-case clock normalization is missing from JTFRAME macros.go')
go = shutil.which('go')
if not go:
    raise SystemExit('Go is missing from the Windows PATH')
output.parent.mkdir(parents=True, exist_ok=True)
env = os.environ.copy()
env.update(GOOS='linux', GOARCH='amd64', CGO_ENABLED='0')
build = subprocess.run(
    [go, 'build', '-o', str(output), '.'],
    cwd=source, env=env, capture_output=True, text=True
)
if build.returncode:
    raise SystemExit(build.stderr[-4000:] or f'go build exited {build.returncode}')
if output.open('rb').read(4) != b'\x7fELF':
    raise SystemExit('cross-compiled JTFRAME tool is not a Linux ELF')
print(json.dumps({
    'tool': str(output),
    'donor_commit': head,
    'sha256': hashlib.sha256(output.read_bytes()).hexdigest(),
    'compiler_invoked': False,
}))
