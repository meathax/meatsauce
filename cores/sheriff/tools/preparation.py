"""Reproducible local preparation helpers for Nintendo 8080 MiSTer."""
from pathlib import Path
import concurrent.futures
import hashlib
import json
import re
import shutil
import subprocess
import sys
import urllib.request
import zipfile
import zlib

ROOT = Path(__file__).resolve().parents[1]
SOURCE = Path('D:/Arcade/AI/mame289')
ROM_SOURCE = Path('D:/Arcade/AI/MAME 0.289 ROMs (merged)')
EVIDENCE = ROOT / 'docs/evidence'

def run(args, cwd=None, timeout=55):
    p = subprocess.run(args, cwd=cwd, capture_output=True, text=True, encoding='utf-8', errors='replace', timeout=timeout)
    if p.returncode:
        raise RuntimeError(f'{args[0]} exit {p.returncode}: {p.stderr[-1800:]}')
    return p.stdout.strip()

def get(url):
    request = urllib.request.Request(url, headers={'User-Agent': 'Nintendo8080-MiSTer-preparation'})
    with urllib.request.urlopen(request, timeout=35) as response:
        return response.read()

def clone(repo):
    dest = ROOT / 'donors' / repo.split('/')[-1]
    pinned = None
    recorded = EVIDENCE/'donors.json'
    if recorded.exists():
        pinned = next((d['commit'] for d in json.loads(recorded.read_text()).get('donors', []) if d['repo']==repo),None)
    if not (dest / '.git').exists():
        run(['git', 'clone', '--depth', '1', 'https://github.com/'+repo+'.git', str(dest)])
    if pinned and run(['git','rev-parse','HEAD'],dest) != pinned:
        if run(['git','status','--porcelain'],dest):
            raise RuntimeError('Preserve local donor edits before restoring pin: '+repo)
        run(['git','fetch','--depth','1','origin',pinned],dest)
        run(['git','checkout','--detach',pinned],dest)
    commit = run(['git', 'rev-parse', 'HEAD'], dest)
    files = run(['git', 'ls-files'], dest).splitlines()
    useful = [p for p in files if re.search(r'8080|vm80|t48|8035|76477|sound|hiscore|crt_adjust|pause|rotate|README|LICENSE|COPYING', p, re.I)]
    return {'repo': repo, 'url': 'https://github.com/'+repo, 'path': dest.relative_to(ROOT).as_posix(), 'commit': commit, 'selected_files': useful}

def stage():
    EVIDENCE.mkdir(parents=True, exist_ok=True)
    (ROOT/'donors').mkdir(exist_ok=True)
    repos = ['MiSTer-devel/Arcade-SpaceInvaders_MiSTer', 'MiSTer-devel/Arcade-DonkeyKong_MiSTer', 'MiSTer-devel/Interact_MiSTer', 'devsaurus/t48', 'JimmyStones/Hiscores_MiSTer', 'obsidian-dot-dev/openFPGA-SpaceInvaders', 'Je0Dev/8085plus', 'rmonic79/MiSTer-CRT-Adjust', 'malisaber/8085-Core', 'jotego/jtcores']
    manifest, failures = [], []
    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
        tasks = {pool.submit(clone, repo): repo for repo in repos}
        for task in concurrent.futures.as_completed(tasks):
            try:
                manifest.append(task.result())
            except Exception as error:
                failures.append({'repo': tasks[task], 'error': str(error)})
    (EVIDENCE/'donors.json').write_text(json.dumps({'donors': manifest, 'failures': failures}, indent=2)+'\n')
    for item in manifest:
        print(json.dumps({'repo': item['repo'], 'commit':item['commit'], 'files': item['selected_files'][:35]}))
    print(json.dumps({'failures': failures}))

def research():
    EVIDENCE.mkdir(parents=True, exist_ok=True)
    endpoints = {
        'github_sn76477': 'https://api.github.com/search/repositories?q=sn76477',
        'github_nintendo8080': 'https://api.github.com/search/repositories?q=nintendo+8080',
        'github_sheriff_fpga': 'https://api.github.com/search/repositories?q=sheriff+fpga',
        'gehstock_tree': 'https://api.github.com/repos/Gehstock/Mist_FPGA/git/trees/master?recursive=1',
        'jtcores_tree': 'https://api.github.com/repos/jotego/jtcores/git/trees/master?recursive=1',
        'mame_n8080_history': 'https://api.github.com/repos/mamedev/mame/commits?path=src/mame/nintendo/n8080.cpp&per_page=60',
        'mame_n8080_sound_history': 'https://api.github.com/repos/mamedev/mame/commits?path=src/mame/nintendo/n8080_a.cpp&per_page=60',
        'mame_cothello_history': 'https://api.github.com/repos/mamedev/mame/commits?path=src/mame/nintendo/cothello.cpp&per_page=35',
    }
    def fetch(pair):
        name, url = pair
        try:
            data = get(url)
            (EVIDENCE/(name+'.json')).write_bytes(data)
            parsed = json.loads(data)
            if isinstance(parsed, list):
                selected = [{'sha':p['sha'], 'date':p['commit']['committer']['date'], 'message':p['commit']['message'][:1100]} for p in parsed]
            elif 'tree' in parsed:
                selected = [p['path'] for p in parsed['tree'] if re.search(r'nintendo.*8080|sheriff|space.?fever|helifire|sn76477|i8080|vm80|jt48|t48|crt_adjust',p['path'], re.I)][:80]
            else:
                selected = [{'repo':p['full_name'], 'description':p['description']} for p in parsed.get('items', [])][:25]
            return {'name':name, 'selected':selected}
        except Exception as error:
            return {'name':name, 'error':str(error)}
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        for item in pool.map(fetch, endpoints.items()):
            print(json.dumps(item))

def roms():
    target = ROOT / 'roms'
    target.mkdir(exist_ok=True)
    driver = (SOURCE/'src/mame/nintendo/n8080.cpp').read_text()
    block = re.search(r'ROM_START\( sheriff \)(.*?)ROM_END',driver,re.S).group(1)
    chips = re.findall(r'ROM_LOAD\(\s*"([^"]+)"\s*,\s*(0x[0-9a-f]+)\s*,\s*(0x[0-9a-f]+)\s*,\s*CRC\(([0-9a-f]+)\)\s*SHA1\(([0-9a-f]+)\)', block)
    archive = ROM_SOURCE/'sheriff.zip'
    shutil.copy2(archive,target/'sheriff.zip')
    records=[]
    with zipfile.ZipFile(archive) as z:
        for name, offset, size, crc, sha in chips:
            data=z.read(name)
            actual_crc=f'{zlib.crc32(data)&0xffffffff:08x}'
            actual_sha=hashlib.sha1(data).hexdigest()
            if len(data)!=int(size,16) or actual_crc!=crc or actual_sha!=sha:
                raise RuntimeError('Sheriff ROM mismatch: '+name)
            out=target/'sheriff'/name
            out.parent.mkdir(exist_ok=True)
            out.write_bytes(data)
            records.append({'name':name,'offset':int(offset,16),'size':len(data),'crc32':actual_crc,'sha1':actual_sha})
    # Only parent chips are extracted. Clone contents of the merged archive remain in the local ZIP.
    inventory=[]
    for name in ['cothello','helifire','highsplt','spacefev','spacelnc']:
        file=ROM_SOURCE/(name+'.zip')
        inventory.append({'set':name,'available':file.exists(),'archive_size':file.stat().st_size if file.exists() else None})
    report={'set':'sheriff','parent':True,'chips':records,'other_parent_archives':inventory,'archive_sha256':hashlib.sha256(archive.read_bytes()).hexdigest()}
    (EVIDENCE/'rom_manifest.json').write_text(json.dumps(report,indent=2)+'\n')
    # Local sources have no Git identity. Hash the exact reference used, and retain the files.
    refs=[]
    for rel in ['src/mame/nintendo/n8080.cpp','src/mame/nintendo/n8080_a.cpp','src/mame/nintendo/n8080_a.h','src/mame/nintendo/cothello.cpp','src/devices/sound/sn76477.cpp','src/devices/cpu/mcs48/mcs48.cpp','src/devices/cpu/i8085/i8085.cpp']:
        data=(SOURCE/rel).read_bytes()
        out=EVIDENCE/'mame'/rel
        out.parent.mkdir(parents=True,exist_ok=True)
        out.write_bytes(data)
        refs.append({'source':str(SOURCE/rel),'staged':out.relative_to(ROOT).as_posix(),'sha256':hashlib.sha256(data).hexdigest()})
    (EVIDENCE/'mame_sources.json').write_text(json.dumps(refs,indent=2)+'\n')
    print(json.dumps(report))

def family():
    """Stage only the seven requested parent sets; verify every dumped ROM."""
    EVIDENCE.mkdir(parents=True, exist_ok=True)
    target = ROOT/'roms'
    target.mkdir(exist_ok=True)
    family_manifest = []
    for name, driver_name in [('sheriff','n8080'),('spacefev','n8080'),('highsplt','n8080'),('spacelnc','n8080'),('helifire','n8080'),('cothello','cothello'),('blockfvr','blockfvr')]:
        driver_file = SOURCE/f'src/mame/nintendo/{driver_name}.cpp'
        text = driver_file.read_text()
        block = re.search(r'ROM_START\(\s*'+name+r'\s*\)(.*?)ROM_END',text,re.S).group(1)
        archive = ROM_SOURCE/(name+'.zip')
        shutil.copy2(archive,target/archive.name)
        records = []
        region = None
        with zipfile.ZipFile(archive) as z:
            for line in block.splitlines():
                rm = re.search(r'ROM_REGION\(\s*(0x[0-9a-f]+)\s*,\s*"([^"]+)"\s*,\s*([^\)]+)',line)
                if rm:
                    region = rm.group(2)
                chip = re.search(r'ROM_LOAD\(\s*"([^"]+)"\s*,\s*(0x[0-9a-f]+)\s*,\s*(0x[0-9a-f]+)\s*,\s*CRC\(([0-9a-f]+)\)\s*SHA1\(([0-9a-f]+)\)',line)
                if not chip:
                    continue
                filename,offset,size,crc,sha = chip.groups()
                data=z.read(filename)
                if len(data)!=int(size,16) or f'{zlib.crc32(data)&0xffffffff:08x}'!=crc or hashlib.sha1(data).hexdigest()!=sha:
                    raise RuntimeError(f'{name} ROM mismatch: {filename}')
                out=target/name/filename
                out.parent.mkdir(parents=True,exist_ok=True)
                out.write_bytes(data)
                records.append({'name':filename,'region':region,'offset':int(offset,16),'size':len(data),'crc32':crc,'sha1':sha})
        family_manifest.append({'set':name,'driver':driver_name+'.cpp','parent':True,'chips':records,'archive_sha256':hashlib.sha256(archive.read_bytes()).hexdigest(),'dump_warnings':[s.strip() for s in block.splitlines() if 'BAD_DUMP' in s or 'NO_DUMP' in s]})
        print(json.dumps({'set':name,'chips':len(records),'bytes':sum(c['size'] for c in records),'dump_warnings':family_manifest[-1]['dump_warnings']}))
        destination = EVIDENCE/'mame'/f'src/mame/nintendo/{driver_name}.cpp'
        destination.parent.mkdir(parents=True,exist_ok=True)
        shutil.copy2(driver_file,destination)
    (EVIDENCE/'family_rom_manifest.json').write_text(json.dumps(family_manifest,indent=2)+'\n')

def extras():
    data=json.loads((EVIDENCE/'donors.json').read_text())
    for repo in ['rmonic79/MiSTer-CRT-Adjust','malisaber/8085-Core']:
        item=clone(repo)
        data['donors']=[d for d in data['donors'] if d['repo']!=repo]+[item]
        directory=ROOT/item['path']
        print(json.dumps({'donor':item,'license_files':[p.name for p in directory.iterdir() if p.is_file() and re.search(r'license|copying',p.name,re.I)],'readme':next((p.read_text(errors='replace')[:2500] for p in directory.iterdir() if p.is_file() and p.name.lower().startswith('readme')),'')}))
    (EVIDENCE/'donors.json').write_text(json.dumps(data,indent=2)+'\n')

def bootstrap():
    """Name the template project, retain sys unchanged, disable RBF generation."""
    template_commit=run(['git','rev-parse','HEAD'],ROOT)
    for suffix in ['qpf','qsf','sdc','srf','sv']:
        original=ROOT/('Template.'+suffix)
        if original.exists():
            original.rename(ROOT/('Nintendo8080.'+suffix))
    qpf=ROOT/'Nintendo8080.qpf'
    qpf.write_text(qpf.read_text().replace('"Template"','"Nintendo8080"'))
    qsf=ROOT/'Nintendo8080.qsf'
    qsf.write_text(qsf.read_text().replace('GENERATE_RBF_FILE ON','GENERATE_RBF_FILE OFF'))
    qip=ROOT/'files.qip'
    qip.write_text(qip.read_text().replace('Template.sv','Nintendo8080.sv').replace('Template.sdc','Nintendo8080.sdc'))
    sv=ROOT/'Nintendo8080.sv'
    sv.write_text(sv.read_text().replace('Template;','Nintendo8080;'))
    old=ROOT/'docs/template-q13'
    old.mkdir(parents=True,exist_ok=True)
    for original in ROOT.glob('Template_Q13.*'):
        original.rename(old/original.name)
    for folder in ['rtl/vendor','sim','releases','docs']:
        (ROOT/folder).mkdir(parents=True,exist_ok=True)
    with (ROOT/'.gitignore').open('a') as f:
        f.write('\n# Nintendo 8080 local assets and preparation\n/roms/\n/donors/\n/mister.env\n/_checks/\n/verification/\n**/__pycache__/\n*.rbf\n*.sof\n')
    env=ROOT/'mister.env'
    if not env.exists():
        env.write_text('QUARTUS_BIN=D:/q17/quartus/bin64\nMAME_EXE=D:/Arcade/AI/mame289/mame.exe\nMAME_SRC=D:/Arcade/AI/mame289/src/mame/nintendo/n8080.cpp\nMAME_ROMPATH=D:/Arcade/AI/aCORES/sherrif/roms\n')
    summary={'source':'https://github.com/MiSTer-devel/Template_MiSTer','commit':template_commit,'project':'Nintendo8080.qpf','game_rtl_status':'template demonstration only; board RTL not implemented','rbf_generated':False}
    (EVIDENCE/'template.json').write_text(json.dumps(summary,indent=2)+'\n')
    run(['git','switch','-c','codex/nintendo8080-preparation'],ROOT)
    run(['git','remote','rename','origin','template-upstream'],ROOT)
    print(json.dumps(summary))

if __name__ == '__main__':
    {'stage':stage,'research':research,'roms':roms,'family':family,'extras':extras,'bootstrap':bootstrap}[sys.argv[1]]()
