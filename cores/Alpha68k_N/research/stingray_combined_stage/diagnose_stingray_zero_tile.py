"""Exact ROM/layout/palette diagnostic; preserves reference contradiction."""
from pathlib import Path
from collections import Counter
import hashlib,json
HERE=Path(__file__).resolve().parent; SCOPE=HERE/'next_coupled_scope_v2'
H=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
def pin(p):return {'path':str(p),'sha256':H(p),'bytes':p.stat().st_size}
def main():
  job=SCOPE/'frame0_constant_fixture_recovery_v2'; pins=json.loads((job/'pins.json').read_text())
  rom=Path(pins['ROM']['path']); b=rom.read_bytes();ram=Path(pins['strip']['path']).read_bytes()
  words=[(ram[i]<<8)|ram[i+1] for i in range(0,len(ram),2)]
  palette=lambda i:tuple((b[off+i]&15)*17 for off in [0x30100,0x30200,0x30300])
  clut=lambda i:((b[0x30500+i]&15)<<4)|(b[0x30400+i]&15)
  tile=[]
  for y in range(8):
    row=[]
    for x in range(8):
      xo=[67,66,65,64,3,2,1,0][x]
      pen=0
      for p,plane in enumerate([4,0x10000*4,4+0x8000*8]):
        bit=plane+y*8+xo
        if b[0x40000+bit//8]&(0x80>>(bit%8)):pen|=1<<(2-p)
      row.append({'pen':pen,'indirect':clut(pen),'RGB':palette(clut(pen))})
    tile.append(row)
  actual=(job/'capture/actual.rgb').read_bytes();mame=Path(pins['MAME_RGB']['path']).read_bytes()
  hist=lambda data:[{'RGB':list(k),'count':v} for k,v in Counter(tuple(data[i:i+3]) for i in range(0,len(data),3)).most_common(16)]
  result={'schema':'actual_sstingry_zero_tile_layout_diagnostic_v1','ROM':pin(rom),
    'RAM_word_histogram':Counter(words),'bank0_tile0':tile,'background0_RGB':palette(0),
    'actual_histogram':hist(actual),'MAME_histogram':hist(mame),
    'first_different_pixel':next({'x':i//3%256,'y':i//3//256+16,'native':list(actual[i:i+3]),'MAME':list(mame[i:i+3])} for i in range(0,len(actual),3) if actual[i:i+3]!=mame[i:i+3]),
    'source_files':[pin(Path(r'D:/Arcade/AI/mame289/src/mame/alpha')/n) for n in ['alpha68k_n.cpp','alpha68k_v.cpp']],
    'no_new_game_run_no_production_change':True}
  dest=job/'zero_tile_diagnosis.json';assert not dest.exists();dest.write_text(json.dumps(result,indent=2)+'\n')
  print(json.dumps(result))
if __name__=='__main__':main()
