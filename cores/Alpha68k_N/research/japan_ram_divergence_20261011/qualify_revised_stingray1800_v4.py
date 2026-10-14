"""Bind the P2 witness to its actual callback iterator/screen epoch; no replay."""
from pathlib import Path
stage=Path(__file__).resolve().parent
failed=stage/'qualify_revised_stingray1800_v2.py'
code=failed.read_text().replace('_v2','_v4').replace('.v2','.v4')
assert code.count("x['frame']==1644 and x['value']")==1
code=code.replace("x['frame']==1644 and x['value']","x['frame']=='1644' and x['value']")
assert code.count("int(x['frame'])==1644 and int(x['mask'])")==1
code=code.replace("int(x['frame'])==1644 and int(x['mask'])","int(x['frame'])==1645 and int(x['screen_frame'])==1644 and int(x['mask'])")
code=code.replace('selected guest latch11 at1645','accepted P2 bank1100 at iterator1645/screen1644 and selected guest latch11 at1645')
exec(compile(code,str(Path(__file__).resolve()),'exec'),globals())
