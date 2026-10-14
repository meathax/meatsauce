from pathlib import Path
import json, re, hashlib
r=Path(__file__).resolve().parents[1]
s=(r/'Nintendo8080.sv').read_text()
assert 'P1,DIP switches;' in s
assert 'input3={!status[10],~status[40:36],status[9:8]}' in s
assert '.direct_video(direct_video)' in s
assert '.no_rotate(status[12]||direct_video)' in s
assert '.flip_screen(status[32])' in s
assert '.rotate_ccw(!status[31])' in s
assert '.autosave(!status[29])' in s
assert 'Autosave Hiscore,On,Off' in s
assert '.crt_enabled(status[16]&&!direct_video)' in s
assert 'Button 1' not in s and 'Button 2' not in s
print('PASS named controls, MAME DIP wiring, direct-video bypass, rotation and OSD autosave defaults')
