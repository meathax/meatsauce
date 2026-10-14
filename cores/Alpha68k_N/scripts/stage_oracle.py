"""Acquire the pinned official MAME oracle without replacing the user's subset binary."""
from pathlib import Path
import hashlib
import json
import subprocess
import urllib.request
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]


def run(args):
    result = subprocess.run([str(a) for a in args], cwd=ROOT, capture_output=True,
                            text=True, encoding='utf-8', errors='replace')
    if result.returncode:
        raise RuntimeError(f'exit={result.returncode} {args}: {result.stdout[-1500:]} {result.stderr[-1500:]}')
    return result


def main():
    release = json.loads((ROOT/'research/mame0289_release.json').read_text())
    asset = next(a for a in release['assets'] if a['name'] == 'mame0289b_x64.exe')
    cache = ROOT/'tools/cache'
    destination = ROOT/'tools/mame0289'
    cache.mkdir(parents=True, exist_ok=True)
    destination.mkdir(parents=True, exist_ok=True)
    archive = cache/asset['name']
    expected = asset['digest'].split(':',1)[1]
    if not archive.exists() or hashlib.sha256(archive.read_bytes()).hexdigest() != expected:
        partial = archive.with_suffix('.exe.part')
        request = urllib.request.Request(asset['browser_download_url'],headers={'User-Agent':'Alpha68k-N-P1'})
        print('Downloading official MAME 0.289 x64 asset',flush=True)
        with urllib.request.urlopen(request, timeout=40) as source, partial.open('wb') as target:
            while data := source.read(1024*1024):
                target.write(data)
        assert partial.stat().st_size == asset['size'], 'Asset length mismatch'
        assert hashlib.sha256(partial.read_bytes()).hexdigest() == expected, 'Official asset digest mismatch'
        partial.replace(archive)
    executable = destination/'mame.exe'
    if not executable.exists():
        result = run([r'C:\Program Files\7-Zip\7z.exe','x',archive,'mame.exe','COPYING','plugins/*','-y','-o'+str(destination)])
        (ROOT/'research/mame0289_extract.log').write_text(result.stdout+result.stderr,encoding='utf-8')
    version = run([executable,'-version']).stdout.strip()
    assert version.startswith('0.289'),version
    manifest = json.loads((ROOT/'research/rom_manifest.json').read_text())
    profiles = {}
    for name in ['kyros','kyrosj','sstingry']:
        xml = run([executable,'-listxml',name]).stdout
        (ROOT/'research'/f'{name}.xml').write_text(xml,encoding='utf-8',newline='\n')
        machine = ET.fromstring(xml).find('machine')
        assert machine is not None and machine.get('name') == name
        expected_roms = {(rom['name'],rom['crc32'],rom['sha1']) for region in manifest[name]['regions'] for rom in region['loads']}
        actual_roms = {(rom.get('name'),rom.get('crc'),rom.get('sha1')) for rom in machine.findall('rom')}
        assert expected_roms == actual_roms, f'{name}: XML/source ROM definitions disagree'
        profiles[name] = {'name':name,'description':machine.findtext('description'),
                          'cloneof':machine.get('cloneof'),'sourcefile':machine.get('sourcefile'),
                          'chips':[x.attrib for x in machine.findall('chip')],
                          'display':machine.find('display').attrib,'driver':machine.find('driver').attrib,
                          'input':machine.find('input').attrib,
                          'controls':[x.attrib for x in machine.findall('input/control')],
                          'dips':[{'name':d.get('name'),'tag':d.get('tag'),'mask':d.get('mask'),
                                   'values':[v.attrib for v in d.findall('dipvalue')]} for d in machine.findall('dipswitch')],
                          'roms':[x.attrib for x in machine.findall('rom')]}
        print('Target XML/source matched',name,flush=True)
    audits = {}
    for pattern in ['kyros*','sstingry']:
        result = run([executable,'-verifyroms',pattern,'-rompath',ROOT/'roms'])
        key = pattern.replace('*','all')
        text = result.stdout+result.stderr
        (ROOT/'research'/f'verifyroms_{key}.txt').write_text(text,encoding='utf-8',newline='\n')
        audits[key] = text.strip()
        print('MAME audit',pattern,text.strip(),flush=True)
    raw = {'pixel_clock_hz':6000000,'htotal':384,'vtotal':264,
           'x_first':0,'x_last_exclusive':256,'y_first':16,'y_last_exclusive':240}
    for name,p in profiles.items():
        p['raw_raster']=raw
        p['interrupts']={'main_irq1':'vblank','main_irq2':'MCU firmware' if name=='sstingry' else '60 Hz compatibility tick',
                         'sound_irq0':'vblank','sound_nmi_hz':4000}
        p['graphics']={'sentinel_tile':0x40 if name=='sstingry' else 0x20,
                       'bankshift':0 if name=='sstingry' else 13,'bank_count':4 if name=='sstingry' else 8,
                       'tile_pixels':[8,8],'bpp':3,'strip_groups':[[2,0x800],[3,0xc00],[1,0x400]]}
        p['mcu']={'mode':'8748 firmware','oscillator_hz':9263750,'internal_divisor':15,'physical_clock_qualified':False} if name=='sstingry' else {'mode':'MAME compatibility HLE initially; full U3 firmware experiment staged','id':0x12,'coin_ids':[0x22,0x22],'physical_clock_qualified':False}
    (ROOT/'board_profiles.json').write_text(json.dumps({'mame_version':'0289','profiles':profiles},indent=2)+'\n',encoding='utf-8',newline='\n')
    source=ROOT/'research/mame0289/src/mame/alpha/alpha68k_n.cpp'
    identity={'release_url':release['url'],'asset':asset,'executable':str(executable),
              'executable_sha256':hashlib.sha256(executable.read_bytes()).hexdigest(),'version':version,
              'driver_sha256':hashlib.sha256(source.read_bytes()).hexdigest(),
              'sets':list(profiles),'rom_audits':audits,'source_xml_roms_matched':True}
    (ROOT/'research/oracle_identity.json').write_text(json.dumps(identity,indent=2)+'\n',encoding='utf-8',newline='\n')
    env=ROOT/'mister.env'
    lines=[l for l in env.read_text().splitlines() if not l.startswith('MAME_EXE=')]
    lines.append('MAME_EXE='+str(executable).replace('\\','/'))
    env.write_text('\n'.join(lines)+'\n',encoding='utf-8',newline='\n')
    print('ORACLE_READY',executable,'asset SHA256 verified; 3 sets available; source/XML/ROM audit passed',flush=True)


if __name__ == '__main__':
    main()
