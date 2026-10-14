"""Vendor selected pristine references and verify the preparation scope once."""
from pathlib import Path
import hashlib
import json
import re
import shutil
import subprocess
import zlib

ROOT = Path(__file__).resolve().parents[1]
E = ROOT/'docs/evidence'

def git(*args):
    p=subprocess.run(['git','-C',str(ROOT),*args],capture_output=True,text=True)
    if p.returncode:
        raise RuntimeError(p.stderr)
    return p.stdout.strip()

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def main():
    readme='''# Nintendo 8080 for MiSTer — Sheriff first

Preparation project for Sheriff/Bandido, Space Fever, SF-HiSplitter, Space Launcher, HeliFire, Computer Othello and Block Fever. The first full bring-up target is Nintendo's `sheriff` parent ROM in MAME 0.289.

**Status: template and donors staged; game RTL not implemented.** The current `Nintendo8080.sv` is the template demonstration, not a working arcade core. No project RBF has been assembled or tested on MiSTer.

- [Implementation plan](plan.md)
- [Progress and evidence](progress.md)
- [MAME bugs and known limitations](mamebug.md)
- [Donor map and integration contracts](donormap.md)
- [Pasteable goal prompt](goal_prompt.md)
- [Hardware notes](docs/HARDWARE_NOTES.md)
- [Preparation verification](docs/evidence/preparation_verification.json)

The Quartus project is `Nintendo8080.qpf`. It derives from [MiSTer-devel/Template_MiSTer](https://github.com/MiSTer-devel/Template_MiSTer), revision `3ea1134cf05d62c2b1db30362277a823d739ced2`, with `sys/` unchanged. Use Quartus 17.0.2 for development map/fit/STA checks. ROMs and the complete pinned donor bank are local and ignored by Git; selected pristine vendor modules retain their notices and provenance.

The plan requires real ROM execution through attract and gameplay in simulation before the final authorized RBF build/hardware phase. It includes ongoing timing/resource gates; successful synthesis alone is not completion. Complete SN76477/M58741P implementations and a qualified 8085 remain explicit work items.

This preparation was AI-assisted. Template files retain their original license. Vendor files retain their own licenses; see [donormap.md](donormap.md) and each `rtl/vendor/*/PROVENANCE.md` before integration. A binary release must retain the applicable source/synthesis notices and accurately disclose supported features and limitations.
'''
    (ROOT/'Readme.md').write_text(readme,encoding='utf-8')
    donors=json.loads((E/'donors.json').read_text())['donors']
    by_name={d['repo'].split('/')[-1]:d for d in donors}
    # Copy accepted/reference files with their original license material; no RTL edits.
    selections=[
        ('Interact_MiSTer','rtl/vm80a.v','vm80a/vm80a.v'),
        ('jtcores','modules/jtframe/hdl/cpu/t48','t48'),
        ('t48','COPYING','t48/COPYING.upstream'),
        ('Hiscores_MiSTer','hiscore.v','hiscore/hiscore.v'),
        ('Hiscores_MiSTer','LICENSE','hiscore/LICENSE'),
        ('MiSTer-CRT-Adjust','rtl/crt_adjust.sv','crt_adjust/crt_adjust.sv'),
        ('MiSTer-CRT-Adjust','rtl/crt_vsize.sv','crt_adjust/crt_vsize.sv'),
        ('MiSTer-CRT-Adjust','LICENSE','crt_adjust/LICENSE'),
    ]
    discrete=['resistor_capacitor_low_pass_filter.sv','resistor_capacitor_high_pass_filter.sv','resistive_two_way_mixer.sv','rate_of_change_limiter.sv','astable_555_vco.sv']
    selections += [('Arcade-DonkeyKong_MiSTer','rtl/mister-discrete/'+p,'discrete/'+p) for p in discrete]
    vendor=[]
    for name,src_rel,dst_rel in selections:
        item=by_name[name]
        src=ROOT/item['path']/src_rel
        dst=ROOT/'rtl/vendor'/dst_rel
        if not src.exists():
            raise RuntimeError('Selected donor file missing: '+str(src))
        if src.is_dir():
            files=[p for p in src.rglob('*') if p.is_file()]
            for original in files:
                out=dst/original.relative_to(src)
                out.parent.mkdir(parents=True,exist_ok=True)
                shutil.copy2(original,out)
                vendor.append({'source':original.relative_to(ROOT).as_posix(),'path':out.relative_to(ROOT).as_posix(),'repo':item['repo'],'commit':item['commit'],'sha256':digest(out)})
        else:
            dst.parent.mkdir(parents=True,exist_ok=True)
            shutil.copy2(src,dst)
            vendor.append({'source':src.relative_to(ROOT).as_posix(),'path':dst.relative_to(ROOT).as_posix(),'repo':item['repo'],'commit':item['commit'],'sha256':digest(dst)})
    for directory in (ROOT/'rtl/vendor').iterdir():
        if directory.is_dir():
            rows=[v for v in vendor if v['path'].startswith(directory.relative_to(ROOT).as_posix()+'/')]
            text='# Pristine donor provenance\n\nNot qualified or connected to the project yet. Preserve original file notices; no local RTL changes.\n\n'
            for row in rows:
                text+=f"- `{Path(row['path']).name}`: https://github.com/{row['repo']}, commit `{row['commit']}`, source `{row['source']}`, SHA256 `{row['sha256']}`.\n"
            (directory/'PROVENANCE.md').write_text(text,encoding='utf-8')
    bank=ROOT/'donors/provenance'
    bank.mkdir(exist_ok=True)
    for d in donors:
        (bank/(d['repo'].split('/')[-1]+'.md')).write_text(f"# Staged donor\n\nSource: {d['url']}\n\nRevision: `{d['commit']}`\n\nLocal source: `{d['path']}`\n\nQualification pending; retain per-file licenses. Selected paths and sparse checkout boundaries are recorded in docs/evidence/donors.json.\n",encoding='utf-8')
    sources=[]
    for p in (E/'mame').rglob('*'):
        if p.is_file():sources.append({'path':p.relative_to(ROOT).as_posix(),'sha256':digest(p)})
    manifest={'date':'2026-10-09','donors':donors,'vendor_files':vendor,'mame_sources':sources,'template':json.loads((E/'template.json').read_text())}
    (E/'preparation_manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
    failures=[]
    for d in donors:
        p=subprocess.run(['git','-C',str(ROOT/d['path']),'rev-parse','HEAD'],capture_output=True,text=True)
        if p.returncode or p.stdout.strip()!=d['commit']: failures.append('Donor revision mismatch: '+d['repo'])
    family=json.loads((E/'family_rom_manifest.json').read_text())
    chips=0
    for game in family:
        for chip in game['chips']:
            data=(ROOT/'roms'/game['set']/chip['name']).read_bytes()
            if len(data)!=chip['size'] or f'{zlib.crc32(data)&0xffffffff:08x}'!=chip['crc32'] or hashlib.sha1(data).hexdigest()!=chip['sha1']:failures.append('ROM mismatch: '+chip['name'])
            chips+=1
    template=manifest['template']['commit']
    p=subprocess.run(['git','-C',str(ROOT),'diff','--exit-code',template,'--','sys'],capture_output=True,text=True)
    sys_unchanged=p.returncode==0
    if not sys_unchanged:failures.append('sys/ changed')
    if 'GENERATE_RBF_FILE OFF' not in (ROOT/'Nintendo8080.qsf').read_text():failures.append('RBF generation is not disabled')
    for filename in ['plan.md','progress.md','mamebug.md','mamebugs.md','donormap.md','goal_prompt.md','AGENTS.md','Nintendo8080.qpf','Nintendo8080.qsf','Nintendo8080.sv','Nintendo8080.sdc']:
        if not (ROOT/filename).exists():failures.append('Missing file: '+filename)
    qip=(ROOT/'files.qip').read_text()
    if 'Template.sv' in qip or 'Template.sdc' in qip:failures.append('Stale template path')
    # Check links in maintained docs, not arbitrary third-party README content.
    documents=[ROOT/p for p in ['plan.md','progress.md','donormap.md','mamebug.md','mamebugs.md','goal_prompt.md','docs/ROADMAP.md']]
    for doc in documents:
        for link in re.findall(r'\]\(([^)]+)\)',doc.read_text(encoding='utf-8')):
            if re.match(r'https?://|#',link):continue
            if not (doc.parent/link.split('#')[0]).exists():failures.append('Broken link in '+doc.name+': '+link)
    for v in vendor:
        if digest(ROOT/v['path'])!=digest(ROOT/v['source']):failures.append('Modified donor: '+v['path'])
    for set_name in ['sheriff','spacefev','highsplt','spacelnc','helifire','cothello','blockfvr']:
        p=subprocess.run(['git','-C',str(ROOT),'check-ignore',str(ROOT/'roms'/set_name)],capture_output=True,text=True)
        if p.returncode:failures.append('ROM path not ignored: '+set_name)
    report={'date':'2026-10-09','scope':'preparation integrity, not core functional qualification','passed':not failures,'donor_repositories':len(donors),'parent_sets':len(family),'verified_rom_chips':chips,'pristine_vendor_files':len(vendor),'sys_unchanged':sys_unchanged,'rbf_generation':'OFF','assembly_run':False,'simulation_run':False,'quartus_fit_run':False,'failures':failures}
    (E/'preparation_verification.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report))
    if failures:raise SystemExit(1)

if __name__=='__main__':main()
