"""Compare the isolated captured-scene renderer to its original MAME image."""
from pathlib import Path
import argparse, hashlib, json
from collections import Counter
from PIL import Image
root = Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('name')
p.add_argument('--capture', required=True)
p.add_argument('--expect-equal', action='store_true', help='Exit nonzero if any RGB pixel differs')
a = p.parse_args()
out = root/'sim/results/video-scenes'/a.name/'sim/results'
capture = Path(a.capture).resolve()
actual = out/'rtl-logo.ppm'
reference = capture/'reference.png'
left = Image.open(actual).convert('RGB')
right = Image.open(reference).convert('RGB')
source_stamp = json.loads((out/'scene-source-stamp.json').read_text())
flipped = source_stamp.get('flip_screen', False)
if flipped:
    right = right.transpose(Image.Transpose.ROTATE_180)
assert left.size == right.size == (320,256)
pixels = lambda image: image.get_flattened_data() if hasattr(image,'get_flattened_data') else image.getdata()
differences = [(i%320,i//320,l,r) for i,(l,r) in enumerate(zip(pixels(left),pixels(right))) if l!=r]
xs = [d[0] for d in differences]
ys = [d[1] for d in differences]
columns = Counter(xs)
edge = sum(x<2 for x in xs)
regions = {'building':(0,32,70,116), 'water':(150,88,317,118),
           'logo':(78,44,241,84), 'hud':(20,2,108,22), 'ground':(2,219,318,234)}
roi = {name: sum(x0<=x<x1 and y0<=y<y1 for x,y,_,_ in differences)
       for name,(x0,y0,x1,y1) in regions.items()}
sha = lambda q: hashlib.sha256(Path(q).read_bytes()).hexdigest()
stamp = out/'scene-source-stamp.json'
meta = {'scope': 'Observed MAME RAM fixture in real video RTL; component only, not live CPU/gameplay proof',
        'reference_transform': 'rotate_180' if flipped else 'none',
        'actual_sha256': sha(actual), 'reference_sha256': sha(reference),
        'source_inventory_sha256': sha(stamp),
        'model_binary_sha256': json.loads(stamp.read_text())['model_binary_sha256'],
        'different_pixels': len(differences), 'first_two_columns': edge,
        'remaining_columns': len(differences)-edge,
        'bbox': [min(xs),min(ys),max(xs),max(ys)] if xs else None,
        'column_counts': {str(x): columns[x] for x in sorted(columns)},
        'static_roi_differences': roi,
        'first_differences': [{'x':x,'y':y,'actual':list(l),'reference':list(r)}
                              for x,y,l,r in differences[:24]],
        'renderer': json.loads((out/'video-fixture.json').read_text())}
(out/'scene-comparison.json').write_text(json.dumps(meta,indent=2)+'\n')
left.save(out/'scene.png')
print(json.dumps({k:meta[k] for k in ['different_pixels','first_two_columns','remaining_columns','bbox','static_roi_differences']}))
if a.expect_equal and meta['different_pixels']:raise SystemExit(1)
