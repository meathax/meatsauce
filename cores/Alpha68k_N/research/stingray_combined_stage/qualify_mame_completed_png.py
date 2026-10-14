"""Decode lossless snapshots from the completed render texture, preserving stale RGB evidence."""
from pathlib import Path
from collections import Counter
import hashlib,json,struct,zlib
HERE=Path(__file__).resolve().parent
CAN=Path(r'D:/Arcade/AI/aCORES/meatsauce-alpha68kn/cores/Alpha68k_N')
H=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
def pin(p):return {'path':str(p),'sha256':H(p),'bytes':p.stat().st_size}
def png(p):
  data=p.read_bytes();assert data[:8]==b'\x89PNG\r\n\x1a\n';at=8;chunks=[]
  while at<len(data):
    size=struct.unpack('>I',data[at:at+4])[0];tag=data[at+4:at+8];body=data[at+8:at+8+size]
    assert zlib.crc32(tag+body)&0xffffffff==struct.unpack('>I',data[at+8+size:at+12+size])[0]
    chunks.append((tag,body));at+=size+12
  assert at==len(data) and chunks[-1][0]==b'IEND'
  w,h,depth,kind,compression,filt,interlace=struct.unpack('>IIBBBBB',chunks[0][1])
  assert depth==8 and kind in [2,3,6] and compression==filt==interlace==0
  channels={2:3,3:1,6:4}[kind];stride=w*channels
  raw=zlib.decompress(b''.join(b for t,b in chunks if t==b'IDAT'));assert len(raw)==h*(stride+1)
  rows=[];prev=bytearray(stride)
  def paeth(a,b,c):
    p=a+b-c;dist=[abs(p-a),abs(p-b),abs(p-c)];return [a,b,c][dist.index(min(dist))]
  for y in range(h):
    typ=raw[y*(stride+1)];row=bytearray(raw[y*(stride+1)+1:(y+1)*(stride+1)])
    for i in range(stride):
      a=row[i-channels] if i>=channels else 0;b=prev[i];c=prev[i-channels] if i>=channels else 0
      delta=[0,a,b,(a+b)//2,paeth(a,b,c)][typ];row[i]=(row[i]+delta)&255
    rows.append(row);prev=row
  palette=next((b for t,b in chunks if t==b'PLTE'),None)
  rgb=bytearray()
  for row in rows:
    for x in range(w):rgb+=palette[row[x]*3:row[x]*3+3] if kind==3 else row[x*channels:x*channels+3]
  # screen:snapshot may apply the driver's declared ROT90, never a fitted transform.
  if (w,h)==(224,256):
    native=bytearray(172032)
    for y in range(224):
      for x in range(256):native[(y*256+x)*3:(y*256+x+1)*3]=rgb[(x*224+(223-y))*3:(x*224+(224-y))*3]
    return bytes(native),{'width':w,'height':h,'kind':kind,'mapping':'inverse declared ROT90: output(223-y,x)'}
  assert (w,h)==(256,224)
  return bytes(rgb),{'width':w,'height':h,'kind':kind,'mapping':'native axes, identity'}
def compare(a,b):
  assert len(a)==len(b)==172032
  pixels=[i//3 for i in range(0,len(a),3) if a[i:i+3]!=b[i:i+3]]
  return {'exact':not pixels,'different_pixels':len(pixels),'bbox':[min(i%256 for i in pixels),min(i//256 for i in pixels),max(i%256 for i in pixels),max(i//256 for i in pixels)] if pixels else None}
def main():
  out=HERE/'next_coupled_scope_v2/completed_png_diagnosis';assert not out.exists();out.mkdir()
  result={'schema':'sstingry_completed_PNG_vs_pixels_same_callback_v1','frames':[],
   'source_mechanism':'video.cpp214-258 finishes/screens swaps before MACHINE_NOTIFY_FRAME; screen.cpp1778-1795 binds m_curtexture then flips m_curbitmap; pixels1493 reads new m_curbitmap, while screen:snapshot renders completed texture.',
   'source_pins':[pin(Path(r'D:/Arcade/AI/mame289/src')/n) for n in ['emu/screen.cpp','emu/video.cpp','frontend/mame/luaengine.cpp','mame/alpha/alpha68k_n.cpp']],
   'recorder_pin':pin(CAN/'sim/mame/capture.lua'),'no_RTL_changes_no_frame_shift':True}
  for frame in [0,30,90,119,179]:
    ref=CAN/'sim/captures/sstingry/gameplay';prefix=f'frame_{frame:06d}'
    image,metadata=png(ref/(prefix+'.png'));derived=out/(prefix+'.completed.rgb');derived.write_bytes(image)
    original=(ref/(prefix+'.rgb')).read_bytes(); native=HERE/'next_coupled_scope_v2/coupled181/capture'/(prefix+'.rgb')
    result['frames'].append({'frame':frame,'PNG':pin(ref/(prefix+'.png')),'PNG_decode':metadata,
       'completed_RGB':pin(derived),'original_pixels_RGB':pin(ref/(prefix+'.rgb')),
       'PNG_vs_pixels':compare(image,original),'native_vs_PNG':compare(native.read_bytes(),image),
       'native_pin':pin(native)})
  q=out/'qualification.json';q.write_text(json.dumps(result,indent=2)+'\n')
  manifest={'schema':'completed_mame_texture_diagnosis_import_v1','files':[pin(q),pin(Path(__file__))],
      'recovery_files':[pin(p) for p in out.glob('*.rgb')],'source_pins':result['source_pins'],
      'recorder':result['recorder_pin'],'diagnostic_only_no_graphics_gate':True}
  m=out/'import_manifest.json';m.write_text(json.dumps(manifest,indent=2)+'\n')
  print(json.dumps({'frames':[{k:v for k,v in x.items() if k in ['frame','PNG_decode','PNG_vs_pixels','native_vs_PNG']} for x in result['frames']], 'manifest':pin(m)}))
if __name__=='__main__':main()
