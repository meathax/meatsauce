"""Retain the measured sprite-origin diagnosis without embedding ROM artwork."""
from pathlib import Path
from PIL import Image
import json,hashlib
root=Path(__file__).resolve().parents[1]
rtl=root/'sim/results/diagnostic/pre-fix-title-240.ppm'
mame=root/'sim/results/mame-attract-240/reference.png'
a=list(Image.open(rtl).convert('RGB').get_flattened_data())
b=list(Image.open(mame).convert('RGB').get_flattened_data())
def different(dx):
    return sum(a[y*320+x]!=(b[y*320+x+dx] if 0<=x+dx<320 else (0,0,0)) for y in range(256) for x in range(320))
assert different(0)==6869 and different(-1)==0
meta={'scope':'Pre-fix live title diagnostic at 240 IRQs, compared with pristine MAME frame 240',
      'unshifted_different_pixels':different(0),'rtl_x_vs_mame_x_minus_1_different_pixels':different(-1),
      'verified_observation':'Every RGB pixel is identical when accounting for the RTL title being one pixel right',
      'responsible_source':'Raiden2_sprite_renderer.sv added a fixed +1 to decoded sprite X',
      'change':'Removed the fixed donor X bias; retain explicit CRT xoff and shared read lookahead',
      'image_hashes':{str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in (rtl,mame)},
      'limits':['This is a diagnostic coordinate comparison, not a shifted output artifact or a passing fixed-RTL result.',
                'The pre-fix COP was also missing 3b30; its later state is not validated bring-up evidence.',
                'Corrected live CPU/video output is checked separately in live-title-origin-fixed.json.']}
(root/'docs/evidence/title-origin-diagnosis.json').write_text(json.dumps(meta,indent=2)+'\n')
print('Recorded pre-fix sprite-origin diagnosis; corrected live evidence is separate.')
