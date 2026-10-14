"""Check the production source graph and independently recover the MRA image."""
from pathlib import Path
import argparse,hashlib,importlib.util,json,re,xml.etree.ElementTree as E
root=Path(__file__).resolve().parents[1]
parser=argparse.ArgumentParser()
parser.add_argument('--mra-parser',required=True,help='Existing trusted MiSTer MRA byte-map decoder')
args=parser.parse_args()
spec=importlib.util.spec_from_file_location('mra_decoder',args.mra_parser)
decoder=importlib.util.module_from_spec(spec);spec.loader.exec_module(decoder)
mra=root/'releases/Zero Team USA (US).mra'
xml=E.parse(mra).getroot()
zip_path=root/'roms/zeroteam.zip'
# If raw ROMs were supplied, make an ignored local zip for independent assembly.
if not zip_path.exists():
    import zipfile
    zip_path=root/'sim/results/zeroteam-validation.zip'
    with zipfile.ZipFile(zip_path,'w') as z:
        for file in (root/'roms/zeroteam').iterdir():
            if file.is_file():z.write(file,file.name)
image=decoder.build_image(mra,zip_path,size=0xe00000)
checks={}
for name,start,length in [('maincpu',0,0x100000),('chars',0x100000,0x20000),
                          ('tiles',0x120000,0x400000),('oki',0x520000,0x40000),
                          ('sprites',0x600000,0x800000)]:
    expected=(root/f'roms/regions/{name}.bin').read_bytes()[:length]
    assert image[start:start+length]==expected,f'MRA {name} differs from pinned MAME region'
    checks[name]={'bytes':length,'sha256':hashlib.sha256(expected).hexdigest()}
raw=(root/'roms/zeroteam/seibu__5.u1110.5b').read_bytes()
assert image[0x560000:0x570000]==raw and len(raw)==0x10000
switches=xml.find('switches')
assert switches.get('default')=='FF,FF,FF,FF'
physical=set(range(16))|set(range(24,32));seen=set()
for dip in switches:
    bits=list(map(int,dip.get('bits').split(',')))
    group=set(range(bits[0],bits[-1]+1))
    assert not seen.intersection(group),dip.attrib
    seen.update(group)
    assert len(dip.get('ids').split(','))==1<<len(group)
    assert len(dip.get('name'))+max(map(len,dip.get('ids').split(',')))+2<=28
assert seen==physical
# Every Zero Team setting follows the raw bit values in pinned raiden2.cpp.
expected={'Difficulty':'Very Hard,Easy,Hard,Normal','Lives':'1,3,4,2',
          'Bonus Life':'No Extend,Every 1000000,2000000,1000000'}
for name,values in expected.items():assert next(d for d in switches if d.get('name')==name).get('ids')==values
cfg=bytes.fromhex(xml.find("rom[@index='3']/part").text)
assert len(cfg)==24 and cfg[16:]==bytes.fromhex('00 00 92 12 4B 40 55 00')
assert xml.find('nvram').attrib=={'index':'4','size':'75'}
assert xml.find('mameversion').text=='0289'
body=(root/'rtl/ZeroTeam_platform.svh').read_text()
assert xml.find('buttons').get('names') in body
assert '.WIDE(0)' in body and '.autosave(1\'b1)' in body
assert 'DIP;' in body and '60Hz' not in body
qip=(root/'files.qip').read_text()
sources=re.findall(r'-name (?:SYSTEMVERILOG_FILE|VERILOG_FILE) ([^\n]+)',qip)
for s in sources:assert (root/s).is_file(),s
sources += ['rtl/ZeroTeam_platform.svh','rtl/ZeroTeam_audio.sv','rtl/ZeroTeam_audio.qip',
            'releases/Zero Team USA (US).mra','rtl/pll/pll_0002.v',
            'sim/zero_platform_checks.sv','sim/platform_checks.cpp',
            'sim/zero_platform_boot.sv','sim/platform_boot.cpp',
            'sim/zero_video_top.sv','sim/video_main.cpp']
for line in (root/'rtl/ZeroTeam_audio.qip').read_text().splitlines():
    if match:=re.search(r'"([^"]+)"',line):assert (root/'rtl'/match[1]).exists(),line
assert '96.000000 MHz' in (root/'rtl/pll/pll_0002.v').read_text()
assert not re.search(r'^\s*set_global_assignment[^\n]*MISTER_DISABLE_YC=1', (root/'ZeroTeam.qsf').read_text(),re.M)
rtl=json.loads((root/'sim/results/platform-checks.json').read_text())
assert rtl['failures']==0
inputs=json.loads((root/'sim/results/inputs-front-end.json').read_text())
assert inputs['vectors']==30 and inputs['failures']==0
boot=json.loads((root/'sim/results/platform-boot.json').read_text())
assert boot['frames']==60 and boot['interrupts']>=50 and boot['failures']==0
flip=json.loads((root/'docs/evidence/platform-flip.json').read_text())
assert flip['different_pixels']==0
meta={'scope':'Target MiSTer platform source and focused real RTL verification',
      'mra_regions':checks,'physical_dip_bits':24,'rtl':rtl,'inputs':inputs,'native_bridge_boot':boot,'rotate_180':flip,
      'lint_exceptions':['Intel PLL/DDR output primitives black-boxed',
                         'Legacy framework PROCASSWIRE and BLKANDNBLK compatibility diagnostics disabled'],
      'source_sha256':{s:hashlib.sha256((root/s).read_bytes()).hexdigest() for s in sources},
      'limits':['No RBF build, placement/timing analysis or MiSTer hardware test.',
                'Full gameplay and analog/direct-video/YC measurements remain release gates.',
                '90-degree rotation uses the HDMI framebuffer; direct video uses native raster.']}
(root/'docs/evidence/platform-options.json').write_text(json.dumps(meta,indent=2)+'\n')
print('MRA matches all five pinned MAME regions; sound ROM matches raw file; all 24 DIP bits and source closure verified.')
