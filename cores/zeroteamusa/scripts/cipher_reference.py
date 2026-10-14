"""Prepare the original MAME cipher routines for the standalone differential test."""
from pathlib import Path
import re
root=Path(__file__).resolve().parents[1]
parts=[]
for name in ['seibu_helper.cpp','r2crypt.cpp']:
    text=(root/'reference/mame'/name).read_text()
    parts.append(re.sub(r'^#include.*\n','',text,flags=re.M))
(root/'sim/results/mame_crypt_reference.hpp').write_text('\n'.join(parts))
print('Prepared original MAME routines; only external include directives removed.')
