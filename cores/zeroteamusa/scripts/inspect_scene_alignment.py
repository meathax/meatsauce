"""Bounded ROI displacement diagnosis; never modify the rendered image."""
from pathlib import Path
from PIL import Image
import json
from collections import Counter
root=Path(__file__).resolve().parents[1]
a=Image.open(root/'sim/results/rtl-live-logo.ppm').convert('RGB')
b=Image.open(root/'sim/results/mame-attract-600/reference.png').convert('RGB')
assert a.size==b.size==(320,256)
pa=a.load();pb=b.load()
regions={'building':(0,32,70,116),'water':(150,88,317,118),
         'ground':(2,219,318,234),'hud':(20,2,108,22),'logo':(78,44,241,84)}
result={}
for name,(left,top,right,bottom) in regions.items():
    def diff(dx,dy):
        return sum(pa[x,y]!=pb[x+dx,y+dy] for y in range(top,bottom) for x in range(left,right)
            if 0<=x+dx<320 and 0<=y+dy<256)
    candidates=sorted((diff(dx,dy),dx,dy) for dx in range(-2,3) for dy in range(-2,3))
    changed=[(x,y) for y in range(top,bottom) for x in range(left,right) if pa[x,y]!=pb[x,y]]
    result[name]={'box':[left,top,right,bottom],'raw_different_pixels':diff(0,0),
        'best':{'different_pixels':candidates[0][0],'mame_dx':candidates[0][1],'mame_dy':candidates[0][2]},
        'top_columns':Counter(x for x,y in changed).most_common(6),
        'first_positions':changed[:6]}
path=root/'sim/results/scene-alignment-rois.json';path.write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps(result));print('Exact recovery:',path)
