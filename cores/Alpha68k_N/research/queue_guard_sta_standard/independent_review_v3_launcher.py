from pathlib import Path
import hashlib
import json
import subprocess
import sys

root = Path(__file__).parent
original = root / 'independent_review_v2.py'
assert hashlib.sha256(original.read_bytes()).hexdigest() == '3cb3fc92d8803e0ec0677f63285ea9c5a8b9f06fdde264d53444a65e8bbfec5c'
source = original.read_text(encoding='utf-8').replace('independent_review_v2', 'independent_review_v3')
assert source.count("name in {'arg_0_2', 'arg_3_2'}") == 1
source = source.replace("name in {'arg_0_2', 'arg_3_2'}", "name == 'arg_0_2'")
source = source.replace('inherited parser whitespace normalization', 'inherited flag spelling handling; exact tokens preserved in evidence')
path = root / 'independent_review_v3.py'
with path.open('x', encoding='utf-8') as handle:
    handle.write(source)
child = subprocess.run([sys.executable, str(path)], capture_output=True, text=True)
print(json.dumps({'actual_native_exit_code': child.returncode, 'stdout': child.stdout, 'stderr': child.stderr,
                 'v3_script_sha256': hashlib.sha256(path.read_bytes()).hexdigest()}))
raise SystemExit(child.returncode)
