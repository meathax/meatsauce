"""Bind the focused actual-RTL frontend check; this is not gameplay evidence."""
from pathlib import Path
import hashlib,json
root=Path(__file__).resolve().parents[1]
result=json.loads((root/'sim/results/inputs-front-end.json').read_text())
assert result['vectors']==30 and result['failures']==0,result
paths=['rtl/ZeroTeam_inputs.sv','sim/zero_inputs_top.sv','sim/inputs_main.cpp',
       'ZeroTeam.sv','files.qip','rtl/ZeroTeam_audio.qip','rtl/ZeroTeam_audio.sv']
meta={'scope':'Actual target frontend: four pad ports, keyboard event decoding and raw MAME input layout',
      'result':result,'reference':'MAME 0.289 zeroteam input ports; docs/INPUTS.md',
      'checks':['Idle and 4P cabinet','All four start bits','Coin 4 and simultaneous coins 3/4',
                'Spare bit 6 ignored (no Special macro)','Right+button1','Extended arrow versus nonextended keypad',
                'Independent releases','Keyboard starts 3/4','Service credit and test',
                'Keyboard actions for players 2/3','Reset releases keyboard state'],
      'source_sha256':{path:hashlib.sha256((root/path).read_bytes()).hexdigest() for path in paths},
      'limits':['This is frontend component evidence; the live CPU gameplay/four-player gate remains pending.',
                'The MiSTer wrapper now selects target audio/inputs but still requires loader/video adaptation and final acceptance.',
                'No Quartus/RBF build or MiSTer hardware test was performed.']}
(root/'docs/evidence/platform-frontend.json').write_text(json.dumps(meta,indent=2)+'\n')
print('Recorded bounded frontend proof and staged platform source hashes.')
doc=root/'docs/INPUTS.md'
heading='## Staged MiSTer frontend'
text=doc.read_text()
if heading not in text:
    doc.write_text(text.rstrip()+'''\n\n## Staged MiSTer frontend

The wrapper accepts four pads with three action buttons each. Every pad has
its own start and coin, and can request pause. Service credit and service-mode
switch are available as remappable Service/Test actions. The second loaded
DIP word supplies SYSTEM cabinet bits 10:8 and service-mode bit 11; the final
MRA must use this layout. These frontend component checks do not prove live
four-player gameplay or final MiSTer integration.

| Player | Directions | Buttons 1 / 2 / 3 | Start | Coin |
| --- | --- | --- | --- | --- |
| 1 | Arrow keys | Left Ctrl / Left Alt / Space | 1 | 5 |
| 2 | I / K / J / L | Z / X / C | 2 | 6 |
| 3 | T / G / F / H | B / N / M | 3 | 7 |
| 4 | Keypad 8 / 5 / 4 / 6 | Keypad 1 / 2 / 3 | 4 | 8 |

Keyboard P requests pause; F2 supplies a service credit; F3 holds the
service-mode switch active. Extended arrow keys and nonextended keypad keys
are decoded separately. User savestates are disabled because target audio
state capture/restoration is not implemented; native simulation checkpoints
are a separate diagnostic facility. Analog-stick mapping and final loader/
video acceptance remain pending platform work.
''')
