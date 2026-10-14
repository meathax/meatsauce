"""Generate Zero Team MRAs (US parent, 4-player US, MAME clones) from the pinned MAME 0.289 ROM definitions."""
from pathlib import Path
import json,re,struct,xml.etree.ElementTree as E
root=Path(__file__).resolve().parents[1]
manifest=json.loads((root/'reference/mame/manifest.json').read_text())
version='0'+re.search(r'0\.(\d+)',manifest['mame_version'])[1]
driver=(root/'reference/mame/raiden2.cpp').read_text()

def rom_regions(setname):
    """Return {region: [(name, offset, crc), ...]} for one ROM_START block."""
    block=re.search(rf'ROM_START\( {setname} \)(.*?)ROM_END',driver,re.S)[1]
    regions,current={},None
    for line in block.splitlines():
        if m:=re.search(r'ROM_REGION\w*\(\s*0x\w+,\s*"(\w+)"',line):current=regions.setdefault(m[1],[])
        elif m:=re.search(r'ROM_LOAD\w*\(\s*"([^"]+)",\s*(0x[0-9a-f]+).*?CRC\(([0-9a-f]+)\)',line,re.I):
            current.append((m[1],int(m[2],16),m[3]))
    return regions

def build(setname,title,manufacturer,output,cabinet=7,hiscore=True,parent=None):
    regions=rom_regions(setname)
    tree=E.Element('misterromdescription')
    for key,value in [('name',title),('setname',setname),('rbf','Arcade-ZeroTeam'),
                      ('mameversion',version),('year','1993'),('manufacturer',manufacturer),
                      ('category','Beat em up'),('rotation','horizontal'),('resolution','15kHz'),
                      ('players','4'),('joystick','8-way'),('num_buttons','2')]:
        E.SubElement(tree,key).text=value
    E.SubElement(tree,'buttons',names='Attack,Jump,-,-,-,-,Start,Coin,Pause,Service Credit,Service Menu',
                 default='A,B,Start,R,L,Select,Y')
    # Cabinet Setting is SW3:1-3 = MRA bits 24-26 (byte 3); 7 = 2P, 5 = 4P 4Slot.
    switches=E.SubElement(tree,'switches',default=f'FF,FF,FF,{0xF8|cabinet:02X}')
    settings=[
     ('Coin A','0,2','4C 1C,3C 1C,2C 1C,1C 4C,1C 6C,1C 3C,1C 2C,1C 1C'),
     ('Coin B','3,5','4C 1C,3C 1C,2C 1C,1C 4C,1C 6C,1C 3C,1C 2C,1C 1C'),
     ('Starting Coin','6','X 2,Normal'),('Flip Screen','7','On,Off'),
     ('Difficulty','8,9','Very Hard,Easy,Hard,Normal'),('Lives','10,11','1,3,4,2'),
     ('Bonus Life','12,13','No Extend,Every 1000000,2000000,1000000'),
     ('Demo Sounds','14','Off,On'),('Unused SW2:8','15','On,Off'),
     ('Cabinet Setting','24,26','4P Freeplay,2P Freeplay,4P 2Slot,2P x2,3P 2Slot,4P 4Slot,3P 3Slot,2P'),
     ('Service Menu','27','On,Off')]
    settings += [(f'Unused SW3:{i-23}',str(i),'On,Off') for i in range(28,32)]
    for name,bits,ids in settings:
        assert len(name)+max(map(len,ids.split(',')))+2<=28,name
        E.SubElement(switches,'dip',name=name,bits=bits,ids=ids)
    tree.append(E.Comment('SW1/2 are DSW; SW3 is SYSTEM high byte. Attack+Jump together performs the special move.'))
    zips=f'{setname}.zip|{parent}.zip' if parent else f'{setname}.zip'
    rom=E.SubElement(tree,'rom',index='0',zip=zips,md5='None')
    def part(parent_el,entry=None,length=None,map=None,fill=None):
        attrs={}
        if entry: attrs.update(name=entry[0],crc=entry[2])
        if length is not None: attrs['repeat' if fill is not None else 'length']=f'0x{length:x}'
        if map: attrs['map']=map
        p=E.SubElement(parent_el,'part',attrs)
        if fill is not None:p.text=f'{fill:02X}'
        return p
    def single(region):
        (entry,)=regions[region];assert entry[1]==0,region;return entry
    # Byte lanes follow the MAME load offset, not the label (zeroteamd labels are 1 3 4 2).
    prg=E.SubElement(rom,'interleave',output='32')
    lanes={e[1]:e for e in regions['maincpu']};assert sorted(lanes)==[0,1,2,3],setname
    for offset in range(4):part(prg,lanes[offset],map=''.join('1' if 3-i==offset else '0' for i in range(4)))
    chars=E.SubElement(rom,'interleave',output='16')
    lanes={e[1]:e for e in regions['chars']};assert sorted(lanes)==[0,1],setname
    part(chars,lanes[0],map='01');part(chars,lanes[1],map='10')
    tiles=sorted(regions['tiles'],key=lambda e:e[1])
    part(rom,tiles[0]);part(rom,tiles[1]);part(rom,length=0x280000,fill=0)
    part(rom,single('oki'));part(rom,single('audiocpu'));part(rom,length=0x90000,fill=0)
    sprites=E.SubElement(rom,'interleave',output='32')
    lanes={e[1]:e for e in regions['sprites']};assert sorted(lanes)==[0,2],setname
    part(sprites,lanes[0],map='0021');part(sprites,lanes[2],map='2100')
    part(rom,length=0x400000,fill=255)
    if hiscore:
        # MAME hiscore.dat: @:maincpu,program,9212,4b,40,55 (75 bytes).
        # Five seconds at 96 MHz, four-cycle RAM settling, sixteen-cycle access padding.
        header=struct.pack('>IHHHHHBB',480_000_000,0x3fff,4,4,1,15,16,0)
        entry=struct.pack('>IBBBB',0x9212,0x4b,0x40,0x55,0)
        E.SubElement(E.SubElement(tree,'rom',index='3'),'part').text=' '.join(f'{b:02X}' for b in header+entry)
        E.SubElement(tree,'nvram',index='4',size='75')
    E.indent(tree,space='  ')
    output=root/'releases'/output
    output.parent.mkdir(parents=True,exist_ok=True)
    output.write_text('<?xml version="1.0"?>\n'+E.tostring(tree,encoding='unicode')+'\n')
    print('Generated',output.relative_to(root))

build('zeroteam','Zero Team USA (US)','Seibu Kaihatsu (Fabtek license)','Zero Team USA (US).mra')
build('zeroteam','Zero Team USA (US, 4 players)','Seibu Kaihatsu (Fabtek license)','Zero Team USA (US, 4 players).mra',cabinet=5)
alt=Path('_alternatives/_Zero Team')
# zeroteamsr is a SEI251 key-reprogramming utility with no game code; not generated.
# zeroteame is absent from MAME hiscore.dat, so it gets no high-score config.
for setname,title,manufacturer,hiscore in [
    ('zeroteama','Zero Team (Japan, earlier, set 1)','Seibu Kaihatsu',True),
    ('zeroteamb','Zero Team (Japan, later batteryless)','Seibu Kaihatsu',True),
    ('zeroteamc','Zero Team (Taiwan)','Seibu Kaihatsu (Liang Hwa license)',True),
    ('zeroteamd','Zero Team (Korea)','Seibu Kaihatsu (Dream Soft license)',True),
    ('zeroteame','Zero Team (Japan, earlier, set 2)','Seibu Kaihatsu',False),
    ('zeroteams','Zero Team Selection','Seibu Kaihatsu',True)]:
    build(setname,title,manufacturer,alt/f'{title}.mra',hiscore=hiscore,parent='zeroteam')
