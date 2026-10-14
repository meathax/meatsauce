"""Bounded first-divergence report for native Sheriff reference captures.

Live scanout and MAME end-of-frame images are reported separately. Matching
at a different frame is diagnostic alignment, never silently accepted.
"""
from pathlib import Path
import csv
import json
import struct
import zlib
import argparse

ROOT=Path(__file__).resolve().parents[1]
parser=argparse.ArgumentParser()
parser.add_argument('--mame',type=Path,default=ROOT/'sim/results/mame289')
parser.add_argument('--rtl',type=Path,default=ROOT/'sim/results/rtl')
parser.add_argument('--report',type=Path,default=ROOT/'sim/results/comparison.json')
args=parser.parse_args()
MAME=args.mame
RTL=args.rtl

def png(path, width, height, rgb):
    def chunk(name,data):
        return struct.pack('>I',len(data))+name+data+struct.pack('>I',zlib.crc32(name+data))
    scan=b''.join(b'\0'+rgb[y*width*3:(y+1)*width*3] for y in range(height))
    path.write_bytes(b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',width,height,8,2,0,0,0))+
                    chunk(b'IDAT',zlib.compress(scan))+chunk(b'IEND',b''))

report={'scope':'diagnostic comparison; not the complete simulation gate','ram':[], 'pixels':[]}
for file in sorted(RTL.glob('frame_*.ram')):
    other=MAME/file.name
    if not other.exists(): continue
    actual=file.read_bytes(); expected=other.read_bytes()
    diffs=[i for i,(a,b) in enumerate(zip(actual,expected)) if a!=b]
    report['ram'].append({'frame':file.stem,'different_bytes':len(diffs),
                         'first_address':hex(0x4000+diffs[0]) if diffs else None})
    ppm=file.with_suffix('.ppm')
    if ppm.exists():
        live=ppm.read_bytes().split(b'\n',3)[3]
        png(ppm.with_suffix('.png'),256,224,live)
    native=other.with_suffix('.idx32')
    if native.exists():
        indices=[i[0] for i in struct.iter_unpack('<I',native.read_bytes())]
        # MAME bitmap_ind16 uses palette indices; preserve/report unexpected
        # direct RGB values instead of coercing them into a palette silently.
        if max(indices,default=0)>7:
            ref=bytes(c for p in indices for c in ((p>>16)&255,(p>>8)&255,p&255))
            kind='RGB32'
        else:
            ref=bytes(c for p in indices for c in (255 if p&1 else 0,255 if p&2 else 0,255 if p&4 else 0))
            kind='palette'
        png(native.with_suffix('.png'),256,224,ref)
        if ppm.exists() and len(live)==len(ref):
            differences=sum(live[i:i+3]!=ref[i:i+3] for i in range(0,len(ref),3))
            report['pixels'].append({'frame':file.stem,'different_pixels':differences,'format':kind})

def outputs(path):
    with path.open() as f:
        reader=csv.reader(f); header=next(reader); result=[]
        for row in reader:
            # Recover the first capture's unquoted attotime string, which uses
            # commas between fractional digit groups. Originals are retained.
            if len(row)>len(header):
                extra=len(row)-len(header)
                row=[''.join(row[:extra+1])]+row[extra+1:]
            if len(row)!=len(header): continue
            r=dict(zip(header,row))
            if r['kind']=='out': result.append((int(r['address'])&7,int(r['data'])))
        return result
if (MAME/'io.csv').exists() and (RTL/'io.csv').exists():
    m=outputs(MAME/'io.csv');r=outputs(RTL/'io.csv')
    # Open live logs may contain an incomplete last line; rerun after exit.
    n=next((i for i,(a,b) in enumerate(zip(m,r)) if a!=b),min(len(m),len(r)))
    report['io']={'matching_prefix':n,'mame_outputs':len(m),'rtl_outputs':len(r),
                  'first_mame':m[n:n+5],'first_rtl':r[n:n+5]}
target=args.report;target.parent.mkdir(parents=True,exist_ok=True)
target.write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps({'report':str(target),
                  'ram_nonzero':[r for r in report['ram'] if r['different_bytes']][:5],
                  'pixels_nonzero':[r for r in report['pixels'] if r['different_pixels']][:5],
                  'matched_ram_frames':sum(r['different_bytes']==0 for r in report['ram']),
                  'matched_pixel_frames':sum(r['different_pixels']==0 for r in report['pixels']),
                  'io':report.get('io')},indent=2))
