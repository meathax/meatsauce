"""Generate and materialize the Sheriff MRA against local parent chips.

ROM payloads stay ignored. Only names/CRCs, zero padding and hiscore metadata
are published in the MRA. No donor wrapper or proprietary ROM bytes are copied.
"""
from pathlib import Path
import hashlib, json, struct, xml.etree.ElementTree as ET, zlib
ROOT=Path(__file__).resolve().parents[1]
chips=[('sh.f1','e79df6e8'),('sh.f2','da67721a'),('sh.g1','3fb7888e'),
       ('sh.g2','585fcfee'),('sh.h1','e59eab52'),('sh.h2','79e69a6a'),
       ('sh.i1','dda7d1e8'),('sh.i2','5c5f3f86'),('sh.j1','0aa8b79a'),
       ('sh.snd','75731745'),('82s137.3l','820f8cdd')]
root=ET.Element('misterromdescription')
for name,value in [('name','Sheriff'),('year','1979'),('manufacturer','Nintendo'),
    ('category','Shooter'),('setname','sheriff'),('parent','sheriff'),
    ('mameversion','0289'),('rbf','Nintendo8080'),('resolution','15kHz'),
    ('rotation','vertical (ccw)'),('players','2 (alternating)'),
    ('joystick','8-way, dual sticks'),('num_buttons','1')]:
    ET.SubElement(root,name).text=value
ET.SubElement(root,'buttons',names='Fire,Start 1,Start 2,Coin,Aim Right,Aim Left,Aim Up,Aim Down,Pause')
# OSD status owns lives/cabinet: its defaults select 3 lives and Upright.
rom=ET.SubElement(root,'rom',index='0',zip='sheriff.zip')
for i,(name,crc) in enumerate(chips):
    if i==9: ET.SubElement(rom,'part',repeat='7168').text='00'
    ET.SubElement(rom,'part',name=name,crc=crc)
# JimmyStones hiscore format: big-endian 16-byte header and 8-byte entry.
# Sheriff source: MAME hiscore.dat @:maincpu,program,60f1,3,0,0.
# One second startup guard prevents restoring into not-yet-initialized RAM.
config=struct.pack('>IHHHHHBB',50400000,255,2,2,1,255,4,0)+struct.pack('>IBBBB',0x60f1,3,0,0,0)
ET.SubElement(ET.SubElement(root,'rom',index='3',md5='none'),'part').text=config.hex(' ').upper()
ET.SubElement(root,'nvram',index='4',size='3')
path=ROOT/'releases/Sheriff.mra';path.parent.mkdir(exist_ok=True)
ET.indent(root);ET.ElementTree(root).write(path,encoding='utf-8',xml_declaration=True)
# Validate the actual saved XML by independently materializing each part.
saved=ET.parse(path).getroot();payload=bytearray()
for part in saved.find("rom[@index='0']"):
    if 'name' in part.attrib:
        data=(ROOT/'roms/sheriff'/part.attrib['name']).read_bytes()
        assert len(data)==1024 and f'{zlib.crc32(data):08x}'==part.attrib['crc']
        payload+=data
    else: payload+=bytes.fromhex(part.text)*int(part.attrib.get('repeat','1'),0)
packed=(ROOT/'roms/sheriff.bin').read_bytes()
assert payload==packed and len(payload)==0x4800
parsed_config=bytes.fromhex(saved.find("rom[@index='3']/part").text)
assert len(parsed_config)==24 and struct.unpack('>IBBBB',parsed_config[16:])==(0x60f1,3,0,0,0)
fixture=ROOT/'sim/results/mra/sheriff_hiscore.cfg';fixture.parent.mkdir(parents=True,exist_ok=True)
fixture.write_bytes(parsed_config)
report={'scope':'MRA XML/part/CRC/layout and hiscore descriptor validation; FPGA/HPS integration pending',
        'mra':'releases/Sheriff.mra','parent':'sheriff','payload_bytes':len(payload),
        'payload_sha256':hashlib.sha256(payload).hexdigest(),'equals_verified_simulation_pack':True,
        'hiscore_address':'0x60f1','hiscore_bytes':3,'config_bytes':24,'release_gate_pass':False}
out=ROOT/'docs/evidence/sheriff_mra.json';out.write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(report,indent=2))
