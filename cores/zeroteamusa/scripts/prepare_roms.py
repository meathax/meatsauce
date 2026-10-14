"""Create exact MAME 0.289 zeroteam region images from locally owned raw ROMs.

This assembles encrypted images only. No Zero Team decryption or game patch is
applied. The tracked layout contains metadata; game bytes stay under roms/.
"""
from pathlib import Path
import hashlib, json, re

ROOT = Path(__file__).resolve().parents[1]

def prepare():
    manifest=json.loads((ROOT/'reference/mame/manifest.json').read_text())
    if not manifest['mame_version'].startswith('0.289 '):
        raise ValueError('Reference binary must be MAME 0.289')
    text=(ROOT/'reference/mame/raiden2.cpp').read_text(encoding='utf-8')
    block=re.search(r'ROM_START\( zeroteam \)(.*?)ROM_END',text,re.S).group(1)
    regions={}; layout={}; current=None; previous=None; cursor=0
    for raw in block.splitlines():
        line=raw.split('//',1)[0]
        m=re.search(r'ROM_REGION(?:32_LE)?\(\s*(0x[0-9a-fA-F]+),\s*"([^"]+)"\s*,\s*([^)]*)\)',line)
        if m:
            size=int(m[1],16); current=m[2]; fill=255 if 'ERASEFF' in m[3] else 0
            regions[current]=bytearray([fill])*size
            layout[current]={'size':size,'fill':fill,'operations':[]}; continue
        m=re.search(r'(ROM_LOAD(?:32_BYTE|32_WORD|16_BYTE)?)\(\s*"([^"]+)",\s*(0x[0-9a-fA-F]+),\s*(0x[0-9a-fA-F]+)',line)
        if m:
            kind,name,offset,size=m[1],m[2],int(m[3],16),int(m[4],16)
            if 'NO_DUMP' in line:
                layout[current]['operations'].append({'kind':kind,'name':name,'offset':offset,'size':size,'status':'nodump'}); continue
            previous=(ROOT/'roms/zeroteam'/name).read_bytes(); cursor=size
            data=previous[:size]
            if len(data)!=size: raise ValueError('Short ROM '+name)
            target=regions[current]
            if kind=='ROM_LOAD32_BYTE': target[offset:offset+size*4:4]=data
            elif kind=='ROM_LOAD16_BYTE': target[offset:offset+size*2:2]=data
            elif kind=='ROM_LOAD32_WORD':
                target[offset:offset+size*2:4]=data[0::2]
                target[offset+1:offset+size*2+1:4]=data[1::2]
            else: target[offset:offset+size]=data
            layout[current]['operations'].append({'kind':kind,'name':name,'offset':offset,'size':size}); continue
        m=re.search(r'ROM_CONTINUE\(\s*(0x[0-9a-fA-F]+)\s*,\s*(0x[0-9a-fA-F]+)',line)
        if m:
            offset,size=int(m[1],16),int(m[2],16); data=previous[cursor:cursor+size]; cursor+=size
            if len(data)!=size: raise ValueError('Short ROM_CONTINUE')
            regions[current][offset:offset+size]=data
            layout[current]['operations'].append({'kind':'ROM_CONTINUE','offset':offset,'size':size}); continue
        m=re.search(r'ROM_COPY\(\s*"([^"]+)"\s*,\s*(0x[0-9a-fA-F]+)\s*,\s*(0x[0-9a-fA-F]+)\s*,\s*(0x[0-9a-fA-F]+)',line)
        if m:
            source,so,offset,size=m[1],int(m[2],16),int(m[3],16),int(m[4],16)
            regions[current][offset:offset+size]=regions[source][so:so+size]
            layout[current]['operations'].append({'kind':'ROM_COPY','source':source,'source_offset':so,'offset':offset,'size':size})
    dest=ROOT/'roms/regions'; dest.mkdir(parents=True,exist_ok=True)
    for name,data in regions.items():
        if len(data)!=layout[name]['size']: raise ValueError('Region geometry changed '+name)
        (dest/(name+'.bin')).write_bytes(data)
        layout[name]['sha256']=hashlib.sha256(data).hexdigest()
    report={'set':'zeroteam','mame_version':'0289','sprites_encrypted':True,
            'source':'reference/mame/raiden2.cpp:2719','regions':layout}
    (ROOT/'reference/rom_layout.json').write_text(json.dumps(report,indent=2)+'\n')
    print('Prepared '+', '.join(f'{name}={len(data):#x}' for name,data in regions.items()))
    return report

if __name__=='__main__': prepare()
