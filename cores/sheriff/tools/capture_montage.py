"""Inspect selected native MAME RGB32 frames and cabinet flip commands."""
import argparse,csv,struct
from pathlib import Path
from PIL import Image,ImageDraw
p=argparse.ArgumentParser()
p.add_argument('directory',type=Path)
p.add_argument('--frames',default='1200,1800,2400,3000,3600,4200,4800,5400,6000')
p.add_argument('--output',default='coverage.png')
a=p.parse_args();frames=[int(x) for x in a.frames.split(',')]
canvas=Image.new('RGB',(3*224,((len(frames)+2)//3)*276),(25,25,25))
draw=ImageDraw.Draw(canvas)
for n,frame in enumerate(frames):
    file=a.directory/f'frame_{frame:05d}.idx32'
    values=[v[0] for v in struct.iter_unpack('<I',file.read_bytes())]
    if len(values)!=256*224:raise ValueError(f'Unexpected native geometry: {file}')
    if max(values)>7:
        rgb=bytes(c for v in values for c in ((v>>16)&255,(v>>8)&255,v&255))
    else:
        rgb=bytes(c for v in values for c in (255 if v&1 else 0,255 if v&2 else 0,255 if v&4 else 0))
    image=Image.frombytes('RGB',(256,224),rgb).transpose(Image.Transpose.ROTATE_90)
    x=(n%3)*224;y=(n//3)*276
    canvas.paste(image,(x,y+20));draw.text((x+4,y+3),f'frame {frame}',fill='white')
target=a.directory/a.output;canvas.save(target)
flips={};last=None
with (a.directory/'io.csv').open() as f:
    for r in csv.DictReader(f):
        if r['kind']=='out' and int(r['address'])&7==6:
            flip=bool(int(r['data'])&0x20)
            if flip!=last:flips[r['frame']]=flip;last=flip
print(f'{target}; cabinet flip transitions={flips}')
