"""One bounded, decisive preparation check; no FPGA compilation or game execution."""
from pathlib import Path
import hashlib, json, re, subprocess, xml.etree.ElementTree as ET, zlib

ROOT=Path(__file__).resolve().parents[1]

def git(args,cwd=ROOT):
    p=subprocess.run(['git',*args],cwd=cwd,capture_output=True,text=True)
    if p.returncode: raise RuntimeError(p.stderr)
    return p.stdout.strip()

def main():
    checks=[]
    def check(condition,message):
        if not condition: raise AssertionError(message)
        checks.append(message)
    manifest=json.loads((ROOT/'reference/mame/manifest.json').read_text())
    check(manifest['set']=='zeroteam' and manifest['mame_version'].startswith('0.289 '),'Target set and MAME version')
    dumped=[r for r in manifest['roms'] if r.get('status')!='nodump']
    check(len(dumped)==13,'All 13 target dumped ROM entries')
    for rom in dumped:
        data=(ROOT/rom['staged_path']).read_bytes()
        check(len(data)==int(rom['size']) and f'{zlib.crc32(data):08x}'==rom['crc'] and hashlib.sha1(data).hexdigest()==rom['sha1'],'ROM '+rom['name'])
    check(sum(r.get('status')=='nodump' for r in manifest['roms'])==4,'Four undumped PALs explicitly recorded')
    for source in manifest['source_files']:
        check(hashlib.sha256((ROOT/source['path']).read_bytes()).hexdigest()==source['sha256'],'MAME source '+source['path'])
    layout=json.loads((ROOT/'reference/rom_layout.json').read_text())
    for name,region in layout['regions'].items():
        data=(ROOT/'roms/regions'/(name+'.bin')).read_bytes()
        check(len(data)==region['size'] and hashlib.sha256(data).hexdigest()==region['sha256'],'ROM region '+name)
    # Independently spot-check every program lane, sprite word lane and sound split/copy.
    program=(ROOT/'roms/regions/maincpu.bin').read_bytes()
    for rom in [r for r in dumped if r['region']=='maincpu']:
        check(program[int(rom['offset'],16)::4]==(ROOT/rom['staged_path']).read_bytes(),'Program byte lane '+rom['offset'])
    sprites=(ROOT/'roms/regions/sprites.bin').read_bytes()
    for rom in [r for r in dumped if r['region']=='sprites']:
        data=(ROOT/rom['staged_path']).read_bytes(); lane=int(rom['offset'],16)
        check(sprites[lane:0x400000:4]==data[0::2] and sprites[lane+1:0x400000:4]==data[1::2],'Sprite word lane '+rom['offset'])
    check(sprites[0x400000:]==b'\xff'*0x400000,'Upper sprite region erased, not decrypted or populated')
    sound=(ROOT/'roms/regions/audiocpu.bin').read_bytes()
    raw=(ROOT/'roms/zeroteam/seibu__5.u1110.5b').read_bytes()
    check(sound[:0x8000]==raw[:0x8000] and sound[0x10000:0x18000]==raw[0x8000:] and sound[0x18000:]==raw[:0x8000],'Sound ROM_CONTINUE and ROM_COPY geometry')
    donors=json.loads((ROOT/'donors/manifest.json').read_text())
    check(all(d['status']=='staged' for d in donors),'All selected donor repositories staged')
    for donor in donors:
        path=ROOT/'donors'/donor['name']
        check(git(['rev-parse','HEAD'],path)==donor['commit'],'Pinned donor '+donor['name'])
        submodules=git(['submodule','status','--recursive'],path).splitlines()
        if donor['name']=='jtcores':
            check((path/'modules/jtframe/hdl').is_dir(),'Sparse JTFRAME HDL materialized')
            submodules=[x for x in submodules if len(x.split())>1 and x.split()[1].startswith('modules/jtframe/')]
        check(not any(x.startswith(('-', '+', 'U')) for x in submodules),'Selected donor submodules initialized '+donor['name'])
    sys_hashes=json.loads((ROOT/'reference/template/sys-sha256.json').read_text())
    check(all(hashlib.sha256((ROOT/p).read_bytes()).hexdigest()==digest for p,digest in sys_hashes.items()),'Template sys files preserved')
    template=json.loads((ROOT/'reference/research/template.json').read_text())
    check(not git(['diff','--name-only',template['commit'],'--','sys/']),'No sys source differs from original template commit')
    for suffix in ['qpf','qsf','sdc','sv']:
        check((ROOT/('ZeroTeam.'+suffix)).is_file(),'Project file ZeroTeam.'+suffix)
    qpf=(ROOT/'ZeroTeam.qpf').read_text(); qip=(ROOT/'files.qip').read_text()
    check('PROJECT_REVISION = "ZeroTeam"' in qpf and 'Template.' not in qip,'Renamed project revision and QIP')
    for name in re.findall(r'-name (?:SYSTEMVERILOG_FILE|VERILOG_FILE|VHDL_FILE|SDC_FILE)\s+([^\s]+)',qip):
        check((ROOT/name.strip('"')).is_file(),'Active QIP file '+name)
    check(git(['check-ignore','roms/source/zeroteam.zip'])=='roms/source/zeroteam.zip','ROM archive ignored by Git')
    for path in ['plan.md','progress.md','goal-prompt.md','docs/HARDWARE_NOTES.md','docs/DONOR_MAP.md','THIRD-PARTY.md']:
        check((ROOT/path).is_file() and (ROOT/path).stat().st_size>100,'Document '+path)
    check(not list((ROOT/'output_files').glob('*.rbf')) if (ROOT/'output_files').exists() else True,'No Zero Team RBF built during preparation')
    report={'status':'passed','date':'2026-10-04','checks':checks,'donors':len(donors),'dumped_roms':len(dumped),
            'undumped_pals':4,'dumped_bytes':sum(int(r['size']) for r in dumped),'gameplay_simulated':False,'project_rbf_built':False}
    (ROOT/'reference/research/preparation-check.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps({k:v for k,v in report.items() if k!='checks'},indent=2))
    print(f'{len(checks)} finite checks passed; preparation complete.')

if __name__=='__main__': main()
