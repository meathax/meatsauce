"""Require actual RTL 180-degree rendering to equal the reversed native image."""
from pathlib import Path
import hashlib,json
from PIL import Image
root=Path(__file__).resolve().parents[1]
native=Image.open(root/'sim/results/rtl-logo.ppm').convert('RGB')
flipped=Image.open(root/'sim/results/rtl-logo-flip.ppm').convert('RGB')
expected=native.transpose(Image.Transpose.ROTATE_180)
assert native.size==flipped.size==(320,256)
differences=sum(a!=b for a,b in zip(expected.get_flattened_data(),flipped.get_flattened_data()))
meta={'scope':'Actual RTL 180-degree boot-logo rendering versus native pixels rotated 180 degrees',
      'different_pixels':differences,'width':320,'height':256,
      'native_sha256':hashlib.sha256(native.tobytes()).hexdigest(),
      'flipped_sha256':hashlib.sha256(flipped.tobytes()).hexdigest(),
      'limits':'Boot-logo fixture; does not cover every scrolling or sprite scene.'}
(root/'docs/evidence/platform-flip.json').write_text(json.dumps(meta,indent=2)+'\n')
print(f'Actual RTL rotate 180: {differences} different pixels')
assert differences==0,meta
