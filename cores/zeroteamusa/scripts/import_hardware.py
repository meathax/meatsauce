"""Import the pinned Raiden II hardware while retaining upstream paths/notices.

No FPGA build is performed. The copied top is an adaptation starting point,
not a claim that the target map/cipher/audio is already implemented.
"""
from pathlib import Path
import hashlib, json, re, shutil

ROOT=Path(__file__).resolve().parents[1]
if (ROOT/'reference/research/hardware-import.json').exists():
    raise SystemExit('Hardware is already imported. Continue adapting active RTL; do not overwrite local changes.')
manifest=json.loads((ROOT/'donors/manifest.json').read_text())
donor=next(d for d in manifest if d['name']=='raiden2-rmonic')
source=ROOT/'donors'/donor['name']
copied=[]
for directory in ['ucore','Raiden2','common','sound','jtframe','pll']:
    for p in (source/'rtl'/directory).rglob('*'):
        if not p.is_file() or p.name.endswith('.upstream_e61f2e09'): continue
        relative=p.relative_to(source)
        dest=ROOT/relative; dest.parent.mkdir(parents=True,exist_ok=True)
        shutil.copy2(p,dest)
        copied.append({'path':relative.as_posix(),'upstream':relative.as_posix(),'sha256':hashlib.sha256(p.read_bytes()).hexdigest()})
    provenance=ROOT/'rtl'/directory/'PROVENANCE.md'
    provenance.write_text(f'# Source provenance\n\nUpstream: {donor["url"]}\n\nCommit: `{donor["commit"]}`\n\nOriginal path: `rtl/{directory}/`\n\nImported unchanged, retaining original per-file notices. Integration changes belong in a dated change entry below. The project license is GPL-3.0-or-later; upstream file notices remain authoritative.\n')
for name in ['sdram.sv','pll.v','pll.qip']:
    p=source/'rtl'/name
    if p.is_file():
        dest=ROOT/'rtl'/name; shutil.copy2(p,dest)
        copied.append({'path':dest.relative_to(ROOT).as_posix(),'upstream':p.relative_to(source).as_posix(),'sha256':hashlib.sha256(p.read_bytes()).hexdigest()})
top=source/'Raiden2.sv'
(ROOT/'ZeroTeam.sv').write_text('// Zero Team USA adaptation: pinned Seibu-family hardware import.\n// Target-specific maps, cipher and audio are implemented in following phases.\n'+top.read_text(encoding='utf-8').replace('Arcade-Raiden2','Arcade-ZeroTeam'))
assignments=[]
for project in [source/'Raiden2.qsf',source/'files.qip']:
    for line in project.read_text().splitlines():
        if line.lstrip().startswith('#'): continue
        match=re.match(r'set_global_assignment -name (SYSTEMVERILOG_FILE|VERILOG_FILE|VHDL_FILE|QIP_FILE|SEARCH_PATH|VERILOG_MACRO) (.+)',line)
        if not match: continue
        kind,value=match.groups()
        if kind=='VERILOG_MACRO' and value not in ['"SYNTHESIS=1"','"CE_HALF_PLUS2=1"','"READY_FIXED_HIGH=1"','"CE_STALL_ON=1"','"MISTER_FB=1"']: continue
        if value=='sys/sys.qip': continue
        if value=='Raiden2.sv': value='ZeroTeam.sv'
        entry=f'set_global_assignment -name {kind} {value}'
        if entry not in assignments: assignments.append(entry)
(ROOT/'files.qip').write_text('# Pinned Seibu donor source set; sys/ comes from the original template.\nset_global_assignment -name SDC_FILE ZeroTeam.sdc\n'+'\n'.join(assignments)+'\n')
(ROOT/'reference/research/hardware-import.json').write_text(json.dumps({'donor':donor,'copied_files':copied,'top_source':'Raiden2.sv','status':'imported; target adaptations pending'},indent=2)+'\n')
# Prepare the staged Verilog Z80 alternative; synthesis migration follows when
# the sound wrapper is converted. Do not silently substitute a host sound CPU.
tv80=ROOT/'donors/irem-m72/rtl/tv80'
if tv80.is_dir():
    dest=ROOT/'rtl/sound/tv80'; dest.mkdir(parents=True,exist_ok=True)
    for p in tv80.glob('*.v'): shutil.copy2(p,dest/p.name)
    jt=next(d for d in manifest if d['name']=='irem-m72')
    (dest/'PROVENANCE.md').write_text(f'# Verilog Z80 fallback\n\nUpstream: {jt["url"]}\n\nCommit: `{jt["commit"]}`\n\nOriginal path: `rtl/tv80/`\n\nImported unchanged; retain file headers. Not yet selected by the hardware sound wrapper.\n')
print(f'Imported {len(copied)} donor hardware/assets; target-specific behavior remains pending.')
