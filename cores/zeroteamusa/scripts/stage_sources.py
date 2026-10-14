"""Stage pinned public donors and local MAME/ROM references; never builds an RBF."""
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor, as_completed
import hashlib, json, shutil, subprocess, urllib.request, xml.etree.ElementTree as ET, zipfile

ROOT = Path(__file__).resolve().parents[1]
DONORS = [
    ('raiden2-spacestate', 'spacestate1/Arcade-Raiden2_MiSTer'),
    ('raiden2-rmonic', 'rmonic79/Arcade-Raiden2_MiSTer'),
    ('seibu-cup-soccer', 'rmonic79/Arcade-SeibuCupSoccer_MiSTer'),
    ('raiden', 'rmonic79/Arcade-Raiden_MiSTer'),
    ('dcon', 'rmonic79/Arcade-Dcon_MiSTer'),
    ('denjin-makai', 'rmonic79/Arcade-DenjinMakai_MiSTer'),
    ('gundam-sd', 'rmonic79/Arcade-GundamSD_MiSTer'),
    ('seibu-spi', 'zakk4223/Arcade-SeibuSPI_MiSTer'),
    ('irem-m72', 'MiSTer-devel/Arcade-IremM72_MiSTer'),
    ('irem-m92', 'MiSTer-devel/Arcade-IremM92_MiSTer'),
    ('jtopl', 'jotego/jtopl'),
    ('jt6295', 'jotego/jt6295'),
    ('nec-test', 'wickerwaka/nec_test'),
    ('legionnaire', 'rmonic79/Arcade-Legionnaire_MiSTer'),
    ('sdgundam-rainbow', 'rmonic79/Arcade-SDGundamRainbow_MiSTer'),
    ('blood-bros', 'rmonic79/Arcade-BloodBros_MiSTer'),
    ('sky-smasher', 'rmonic79/Arcade_SkySmasher_MiSTer'),
    ('t80', 'MiSTer-devel/T80'),
    ('hiscores', 'MiSTer-devel/Hiscores_MiSTer'),
    ('crt-adjust', 'rmonic79/MiSTer-CRT-Adjust'),
]

def run(args, cwd=ROOT, timeout=300):
    p = subprocess.run(args, cwd=cwd, capture_output=True, text=True, errors='replace', timeout=timeout)
    if p.returncode:
        raise RuntimeError(f"exit {p.returncode}: {' '.join(str(a) for a in args)}\n{p.stderr[-3000:]}")
    return p.stdout.strip()

def fetch(url):
    req = urllib.request.Request(url, headers={'User-Agent':'ZeroTeam-MiSTer-source-preparation'})
    with urllib.request.urlopen(req, timeout=60) as response:
        return json.load(response)

def stage(item):
    name, repo = item
    dest = ROOT / 'donors' / name
    url = f'https://github.com/{repo}.git'
    try:
        if not (dest / '.git').exists():
            run(['git', 'clone', '--depth', '1', '--recurse-submodules', '--shallow-submodules', url, str(dest)], timeout=600)
        sha = run(['git', 'rev-parse', 'HEAD'], dest)
        modules = run(['git', 'submodule', 'status', '--recursive'], dest)
        licenses = [str(p.relative_to(dest)).replace('\\','/') for p in dest.rglob('*')
                    if p.is_file() and '.git' not in p.parts and p.name.lower().startswith(('license','copying'))]
        record = {'name':name, 'repository':repo, 'url':url, 'commit':sha,
                  'submodules':modules.splitlines(), 'license_files':licenses, 'status':'staged'}
        (dest / 'STAGING_PROVENANCE.json').write_text(json.dumps(record, indent=2)+'\n')
        return record
    except Exception as error:
        return {'name':name, 'repository':repo, 'url':url, 'status':'failed', 'error':str(error)}

def main():
    for directory in ['donors','reference/mame','reference/research','roms/source','roms/zeroteam','docs','sim','releases']:
        (ROOT / directory).mkdir(parents=True, exist_ok=True)
    template_path=ROOT/'reference/research/template.json'
    if not template_path.exists():
        template = {'url':run(['git','remote','get-url','origin']), 'commit':run(['git','rev-parse','HEAD'])}
        template_path.write_text(json.dumps(template,indent=2)+'\n')
    records=[]
    with ThreadPoolExecutor(max_workers=4) as pool:
        for future in as_completed([pool.submit(stage,item) for item in DONORS]):
            record=future.result(); records.append(record)
            print(f"{record['name']}: {record['status']} {record.get('commit',record.get('error',''))[:180]}",flush=True)
    jtcores=ROOT/'donors/jtcores'
    if (jtcores/'.git').exists():
        record={'name':'jtcores','repository':'jotego/jtcores','url':'https://github.com/jotego/jtcores.git',
                'commit':run(['git','rev-parse','HEAD'],jtcores),'submodules':[],
                'license_files':[str(p.relative_to(jtcores)).replace('\\','/') for p in jtcores.rglob('*')
                                 if p.is_file() and '.git' not in p.parts and p.name.lower().startswith(('license','copying'))],'status':'staged',
                'scope':'Sparse checkout: modules/jtframe (HDL, simulation utilities and sprite-engine fallbacks).'}
        records.append(record)
        (jtcores/'STAGING_PROVENANCE.json').write_text(json.dumps(record,indent=2)+'\n')
    try:
        repos=fetch('https://api.github.com/users/rmonic79/repos?per_page=100&sort=updated')
        (ROOT/'reference/research/rmonic79-repositories.json').write_text(json.dumps(repos,indent=2)+'\n')
        print('rmonic79 inventory: '+', '.join(r['name'] for r in repos if any(s in r['name'].lower() for s in ['seibu','raiden','zero','dcon','denjin','gundam','blood','sky'])),flush=True)
    except Exception as error:
        print(f'profile inventory failed: {error}',flush=True)
    (ROOT/'donors/manifest.json').write_text(json.dumps(sorted(records,key=lambda r:r['name']),indent=2)+'\n')
    src=Path(r'D:\Arcade\AI\mame289')
    files=[]
    paths=list((src/'src/mame/seibu').glob('*'))
    chosen=['raiden2','raiden2cop','seibucop','seibu_crtc','seibu_sound','r2crypt','sei25x','legionna','r2dx_v33']
    for p in paths:
        if p.is_file() and any(p.name.startswith(stem) for stem in chosen):
            dest=ROOT/'reference/mame'/p.name; shutil.copy2(p,dest)
            files.append({'source':str(p), 'path':str(dest.relative_to(ROOT)).replace('\\','/'), 'sha256':hashlib.sha256(p.read_bytes()).hexdigest()})
    for relative in ['src/devices/cpu/nec/nec.cpp','src/devices/cpu/nec/nec.h','src/devices/cpu/nec/necinstr.hxx','src/devices/cpu/nec/necpriv.ipp','src/devices/sound/okim6295.cpp','src/devices/sound/okim6295.h','src/devices/sound/ymopl.cpp','src/devices/sound/ymopl.h']:
        p=src/relative
        if p.exists():
            dest=ROOT/'reference/mame'/relative; dest.parent.mkdir(parents=True,exist_ok=True); shutil.copy2(p,dest)
            files.append({'source':str(p), 'path':str(dest.relative_to(ROOT)).replace('\\','/'), 'sha256':hashlib.sha256(p.read_bytes()).hexdigest()})
    mame=Path(r'D:\Arcade\AI\mameexe\mame.exe')
    version=run([str(mame),'-version'])
    try: source_revision=run(['git','describe','--tags','--always'],src)
    except Exception: source_revision='No Git metadata; source files individually SHA-256 pinned.'
    xml=run([str(mame),'-listxml','zeroteam'])
    (ROOT/'reference/mame/zeroteam.xml').write_text(xml+'\n',encoding='utf-8')
    machine=ET.fromstring(xml).find("machine[@name='zeroteam']")
    archive=Path(r'D:\Arcade\AI\MAME 0.289 ROMs (merged)\zeroteam.zip')
    shutil.copy2(archive,ROOT/'roms/source/zeroteam.zip')
    roms=[]
    with zipfile.ZipFile(archive) as z:
        entries=z.infolist()
        for rom in machine.findall('rom'):
            entry={**rom.attrib}
            if rom.get('status')=='nodump': entry['status']='nodump'; roms.append(entry); continue
            matches=[i for i in entries if f'{i.CRC:08x}'==rom.get('crc') and i.file_size==int(rom.get('size','0'))]
            if not matches: raise RuntimeError(f"Missing required ROM: {rom.attrib}")
            info=matches[0]; data=z.read(info)
            if hashlib.sha1(data).hexdigest()!=rom.get('sha1'): raise RuntimeError('SHA1 mismatch '+rom.get('name'))
            dest=ROOT/'roms/zeroteam'/rom.get('name'); dest.parent.mkdir(parents=True,exist_ok=True); dest.write_bytes(data)
            entry.update(archive_member=info.filename, staged_path=str(dest.relative_to(ROOT)).replace('\\','/'), verified=True)
            roms.append(entry)
    meta={'set':'zeroteam','description':machine.findtext('description'),'mame_version':version,'mame_executable':str(mame),'source_revision':source_revision,
          'source_files':files,'chips':[e.attrib for e in machine.findall('chip')], 'display':[e.attrib for e in machine.findall('display')],
          'input':machine.find('input').attrib, 'driver':machine.find('driver').attrib,'roms':roms,
          'archive_sha256':hashlib.sha256(archive.read_bytes()).hexdigest()}
    (ROOT/'reference/mame/manifest.json').write_text(json.dumps(meta,indent=2)+'\n')
    print(json.dumps({'mame':version,'set':meta['description'],'rom_files':len(roms),'rom_bytes':sum(int(r['size']) for r in roms),'chips':meta['chips'],'display':meta['display'],'failed_donors':[r['name'] for r in records if r['status']=='failed']},indent=2),flush=True)

if __name__=='__main__': main()
