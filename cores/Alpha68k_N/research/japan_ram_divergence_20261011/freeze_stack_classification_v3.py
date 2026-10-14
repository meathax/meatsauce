"""Preserve V2 consumer NameError; add only its missing read-only path bindings."""
from pathlib import Path
stage=Path(__file__).resolve().parent
failed=stage/'freeze_stack_classification_v2.py'
code=failed.read_text().replace('_v2','_v3').replace('.v2','.v3')
needle="source=source.replace('.asm.txt','.v3.asm.txt').replace('retired_stack_classification.json','retired_stack_classification_v3.json')"
assert code.count(needle)==1
code=code.replace(needle,needle+"\nsource=source.replace('regions=[]', \"proof=Path(r'D:\\\\Arcade\\\\AI\\\\mame289\\\\src\\\\tools\\\\unidasm.cpp')\\nprior=Path(__file__).resolve().parent/'disassemble_stack_sources601.py'\\nregions=[]\")")
needle='manifest=dict('
assert code.count(needle)==1
code=code.replace(needle,"files += [STAGE/'freeze_stack_classification_v2.py',STAGE/'disassemble_stack_sources601_v2.py',HERE/'retired_stack_classification_v2.log',HERE/'retired_stack_classification_v2_exit.json']\nfiles += [HERE/f'ROM_{base:06x}.v2.asm.txt' for base in [0x500,0x580,0x1ff0]]\n"+needle)
exec(compile(code,str(Path(__file__).resolve()),'exec'),globals())
