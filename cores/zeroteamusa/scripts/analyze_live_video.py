"""Record CPU-driven video evidence with the frozen build-input inventory."""
from pathlib import Path
from PIL import Image
import json,hashlib
root=Path(__file__).resolve().parents[1]
out=root/'sim/results'
result=json.loads((out/'board-av-boot.json').read_text())
assert result['cycles']==104000000 and result['complete_video_frames']>50
image=Image.open(out/'rtl-live-logo.ppm').convert('RGB')
reference=Image.open(out/'mame-attract-60/reference.png').convert('RGB')
assert image.size==reference.size==(320,256)
image.save(out/'rtl-live-logo.png')
differences=[(i%320,i//320,a,b) for i,(a,b) in enumerate(zip(image.get_flattened_data(),reference.get_flattened_data())) if a!=b]
detail={'rows':sorted(set(y for x,y,a,b in differences)),
        'bounds': [min(x for x,y,a,b in differences),min(y for x,y,a,b in differences),max(x for x,y,a,b in differences),max(y for x,y,a,b in differences)] if differences else None,
        'rtl_diff_colors':sorted(set(a for x,y,a,b in differences)),
        'reference_diff_colors':sorted(set(b for x,y,a,b in differences))}
meta={'set':'zeroteam','scope':'Live, real V30/COP/CRTC/DMA/video RTL from reset; no injected memory or CPU state',
      'result':result,'different_pixels':len(differences),'difference_detail':detail,
      'rtl_nonblack_pixels':sum(p!=(0,0,0) for p in image.get_flattened_data()),
      'build_inventory':json.loads((out/'av-source-stamp.json').read_text()),
      'rtl_image_sha256':hashlib.sha256((out/'rtl-live-logo.png').read_bytes()).hexdigest(),
      'limits':'Early logo only. Audio, protection/sorting, attract, inputs and gameplay still pending; cipher is integrated but the logo does not exercise populated sprites.'}
(root/'docs/evidence/live-logo.json').write_text(json.dumps(meta,indent=2)+'\n')
print(json.dumps({k:meta[k] for k in ['different_pixels','rtl_nonblack_pixels']},indent=2))
print('Real CPU/video completed frames: '+str(result['complete_video_frames']))
print(json.dumps(detail))
