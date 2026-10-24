"""Copy the required source trees on Windows before WSL project generation."""
from pathlib import Path
import shutil
import sys

root=Path(__file__).resolve().parents[1]
snapshot=Path(sys.argv[1]).resolve()
if snapshot.exists():
    raise SystemExit(f"refusing to replace existing snapshot: {snapshot}")
snapshot.mkdir(parents=True)
for group,names in (("cores",("osman","cninja")),("modules",("jtframe","jt6295","jteeprom"))):
    for name in names:
        shutil.copytree(root/group/name,snapshot/group/name,ignore=shutil.ignore_patterns(".git"))
print(f"Seeded isolated source snapshot: {snapshot}")
