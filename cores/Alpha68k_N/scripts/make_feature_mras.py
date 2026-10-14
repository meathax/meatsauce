"""Generate and verify MRAs against audited ROM bytes and MAME 0.289 DIPs.

No ROM data is embedded except the non-copyrighted loader/config header.
Use --set sstingry for a scoped Stingray MRA/receipt update.
Release MRAs describe loaders and controls; about retains game qualification limits.
"""
from pathlib import Path
import argparse,hashlib,json,zipfile,xml.etree.ElementTree as ET
ROOT=Path(__file__).resolve().parents[1]
HS={'kyros':[(0x20e00,0xae,1,2),(0x20020,4,0,0)],
    'kyrosj':[(0x20e00,0xae,1,2),(0x20020,4,0,0)],
    'sstingry':[(0x20028,4,0,0x73),(0x20770,0x90,0,0)]}
BUTTONS={'kyros':'Punch,Jump,Start,Coin,Pause','kyrosj':'Punch,Jump,Start,Coin,Pause',
         'sstingry':'Main weapon,Sub weapon,Start,Coin,Pause'}
def text(parent,tag,value):
    ET.SubElement(parent,tag).text=str(value)
def pad(parent,count):
    if count: ET.SubElement(parent,'part',repeat=hex(count)).text='00'
def part(parent,load,offset,length,map_=None):
    a={'name':load['zip_entry'],'crc':load['crc32'],'offset':hex(offset),'length':hex(length)}
    if map_: a['map']=map_
    ET.SubElement(parent,'part',a)
def expand(node,archive):
    out=bytearray()
    for el in node:
        if el.tag=='part':
            if 'name' in el.attrib:
                names=[i for i in archive.infolist() if f'{i.CRC:08x}'==el.attrib['crc']]
                assert names,el.attrib
                data=archive.read(names[0]);begin=int(el.attrib['offset'],0)
                out.extend(data[begin:begin+int(el.attrib['length'],0)])
            else: out.extend(bytes.fromhex(el.text)*int(el.get('repeat','1'),0))
        elif el.tag=='interleave':
            lanes={}
            for lane in el:
                holder=ET.Element('holder');holder.append(lane)
                lanes[lane.attrib['map']]=expand(holder,archive)
            assert len(lanes['01'])==len(lanes['10'])
            # MiSTer map bit zero is first output byte, matching MAME big endian
            # maincpu region bytes before the board loader's endian conversion.
            out.extend(b for pair in zip(lanes['01'],lanes['10']) for b in pair)
    return bytes(out)
def main(selected_sets=None):
    profiles=json.loads((ROOT/'board_profiles.json').read_text())
    source=json.loads((ROOT/'research/rom_manifest.json').read_text())
    layout=json.loads((ROOT/'rom_layout.json').read_text());receipt={}
    if selected_sets:
        assert set(selected_sets)<=set(source),selected_sets
    for index,(name,info) in enumerate(source.items()):
        if selected_sets and name not in selected_sets: continue
        profile=profiles['profiles'][name];mra=ET.Element('misterromdescription')
        for tag,value in [('name',profile['description']),('setname',name),('mameversion',profiles['mame_version']),('rbf','Alpha68k_N'),('manufacturer','Alpha Denshi'),('year','1986' if name!='kyros' else '1987'),('rotation','vertical (cw)')]:text(mra,tag,value)
        text(mra,'about','Development core: simulation and hardware gates pending.' if name!='sstingry' else 'Super Stingray profile 2: simulation, gameplay/input, cocktail, earned-score and hardware qualification remain incomplete.')
        ET.SubElement(mra,'buttons',names=BUTTONS[name],default='A,B,Start,Select,X')
        default=0
        for dip in profile['dips']:
            default|=int(next(v['value'] for v in dip['values'] if v['default']=='yes'))
        switches=ET.SubElement(mra,'switches',default=f'{default:02X}')
        seen=0
        for dip in profile['dips']:
            mask=int(dip['mask']);assert not seen&mask;seen|=mask
            low=(mask&-mask).bit_length()-1;high=mask.bit_length()-1
            ids=[v['name'] for v in dip['values']]
            assert max(len(dip['name'])+len(i)+2 for i in ids)<=28
            ET.SubElement(switches,'dip',name=dip['name'],bits=str(low) if low==high else f'{low},{high}',ids=','.join(ids),values=','.join(str(int(v['value'])>>low) for v in dip['values']))
        assert seen==255 and profile['input']['service']=='no'
        rom=ET.SubElement(mra,'rom',index='0',zip=Path(info['archive']).name,md5='None')
        ET.SubElement(rom,'part').text=(bytes.fromhex('4136384e')+bytes([1,index])).hex(' ')
        cursor=6
        for region in sorted(layout['sets'][name]['regions'],key=lambda r:r['base']):
            pad(rom,region['base']-cursor);cursor=region['base']
            logical=region['name'];actual=next(v for v in info['regions'] if v['name']==logical or (logical=='mcu' and v['name']=='alpha8511'))
            loads=actual['loads']
            if logical=='mcu' and name!='sstingry': loads=[next(x for x in loads if x['name']=='kyros_68705u3.bin')]
            segments=[]
            for load in loads:
                pos=0
                for piece in [{'offset':load['offset'],'length':load['length']}]+load['continuations']:
                    segments.append((piece['offset'],load,pos,piece['length']));pos+=piece['length']
            segments.sort(key=lambda x:x[0]);rpos=0;i=0
            while i<len(segments):
                offset,load,pos,length=segments[i];pad(rom,offset-rpos)
                if load['kind']=='ROM_LOAD16_BYTE':
                    odd,other,opos,olen=segments[i+1];assert odd==offset+1 and olen==length
                    lanes=ET.SubElement(rom,'interleave',output='16')
                    part(lanes,load,pos,length,'01');part(lanes,other,opos,olen,'10');rpos=offset+2*length;i+=2
                else:part(rom,load,pos,length);rpos=offset+length;i+=1
            cursor+=rpos
        pad(rom,layout['download_bytes']-cursor)
        with zipfile.ZipFile(ROOT/info['archive']) as z: packed=expand(rom,z)
        expected=(ROOT/layout['sets'][name]['path']).read_bytes();assert packed==expected,name
        config=bytes.fromhex('00 00 00 00 00 ff 00 04 00 04 00 01 00 0f 04 00')
        for addr,length,start,end in HS[name]:
            assert 0x20000<=addr<=addr+length-1<0x21000
            config+=addr.to_bytes(4,'big')+bytes([length,start,end,0])
        cfg=ET.SubElement(mra,'rom',index='3',md5='None');ET.SubElement(cfg,'part').text=config.hex(' ')
        ET.SubElement(mra,'nvram',index='4',size=str(sum(x[1] for x in HS[name])))
        (ROOT/'roms'/name/'hiscore_config.bin').write_bytes(config)
        target=ROOT/'releases'/(profile['description']+'.mra')
        target.parent.mkdir(parents=True,exist_ok=True);ET.indent(mra,space='  ');ET.ElementTree(mra).write(target,encoding='utf-8',xml_declaration=True)
        receipt[name]={'mra':target.relative_to(ROOT).as_posix(),'rom_bytes':len(packed),'rom_sha256':hashlib.sha256(packed).hexdigest(),'dip_default':default,'dip_fields':len(profile['dips']),'dip_coverage':seen,'service_input':False,'hiscore_bytes':sum(x[1] for x in HS[name]),'hiscore_config_sha256':hashlib.sha256(config).hexdigest(),'runtime_qualified':False,'control_label_limit':None if name!='sstingry' else 'Main weapon/Sub weapon are descriptive translations supported by the Japanese flyer review; original printed panel wording has not been visually transcribed. See docs/sstingry_controls.md.'}
    receipt_name='feature_mra_validation'+('_'+'_'.join(selected_sets) if selected_sets else '')+'.json'
    (ROOT/'research'/receipt_name).write_text(json.dumps({'mame_version':profiles['mame_version'],'sets':receipt,'hiscore_source':'https://github.com/mamedev/mame/blob/mame0289/plugins/hiscore/hiscore.dat','limits':['Generated ROM expansion is checked independently against the audited packed ROM; Main firmware hardware load is pending.','All-games DIP effects, cockpit behavior and earned-score roundtrip remain acceptance gates.']},indent=2)+'\n')
    print('MRA ROM streams match audited packed bytes; DIP masks/defaults and hiscore ranges pass: '+','.join(receipt))
if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--set',dest='sets',action='append',choices=tuple(BUTTONS),help='Generate only this set; repeat to select several sets.')
    main(parser.parse_args().sets)
