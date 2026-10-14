"""Lint the production emu and framework modules; black-box Intel primitives only."""
from pathlib import Path
import re,subprocess
root=Path(__file__).resolve().parents[1]
sys=['hps_io.sv','arcade_video.v','video_mixer.sv','video_freak.sv','video_freezer.sv',
     'gamma_corr.sv','scandoubler.v','hq2x.sv','math.sv','sync_fix.sv']
paths=re.findall(r'-name (?:SYSTEMVERILOG_FILE|VERILOG_FILE) ([^\n]+)',(root/'files.qip').read_text())
for line in (root/'rtl/ZeroTeam_audio.qip').read_text().splitlines():
    if re.search(r'-name (?:SYSTEMVERILOG_FILE|VERILOG_FILE) ',line):
        m=re.search(r'"([^"]+)"',line)
        paths.append('rtl/'+m[1])
paths += ['sys/'+s for s in sys if (root/'sys'/s).exists()]
paths.append('rtl/pll/pll_0002.v')
for path in (root/'sys').glob('*'):
    if path.suffix in ('.v','.sv') and re.search(r'\bmodule\s+sync_fix\b',path.read_text()):
        name=path.relative_to(root).as_posix()
        if name not in paths:paths.append(name)
out=root/'sim/results';out.mkdir(parents=True,exist_ok=True)
(out/'build_id.v').write_text('`define BUILD_DATE "simulation"\n')
# Declare only the Intel black boxes using their existing instantiation ports.
# No target RTL is substituted. This validates wiring, not primitive behavior.
stubs=[]
for primitive,source in [('altera_pll','rtl/pll/pll_0002.v'),('altddio_out','rtl/sdram.sv')]:
    text=(root/source).read_text()
    m=re.search(primitive+r'\s*#\s*\((.*?)\)\s+\w+\s*\((.*?)\);',text,re.S)
    assert m,primitive
    params=re.findall(r'\.(\w+)\s*\(',m[1]);ports=re.findall(r'\.(\w+)\s*\(',m[2])
    outputs={'outclk','locked','fboutclk','dataout'}
    stub='module '+primitive+' #( '+','.join('parameter '+p+'=1' for p in params)+' ) (\n'
    stub+=',\n'.join(('output wire ' if p in outputs else 'input wire ')+p for p in ports)+'\n);\nendmodule\n'
    stubs.append(stub)
(out/'intel_lint_boxes.v').write_text('\n'.join(stubs))
paths.append('sim/results/intel_lint_boxes.v')
paths += ['credits/rtl/credits_overlay.sv','credits/generated/credits_rom.sv','credits/generated/meat_osd_rom.sv']
scratch=Path('/mnt/r/Verilator/ZeroTeam/platform-lint')
if not Path('/mnt/r/Verilator').is_dir():scratch=root/'sim/build/platform-lint'
scratch.mkdir(parents=True,exist_ok=True)
cmd=['verilator','--lint-only','--top-module','emu','--no-timing','--bbox-unsup',
     # The pinned Quartus framework uses procedural net outputs and mixed
     # assignment styles accepted by Quartus but rejected by modern Verilator.
     '--Mdir',str(scratch),'-Wno-fatal','-Wno-PROCASSWIRE','-Wno-BLKANDNBLK',
     '-DMISTER_FB','-DCE_HALF_PLUS2','-DREADY_FIXED_HIGH','-DCE_STALL_ON',
     '-I.','-Isim/results','-Icredits/generated','-Irtl/ucore','-Irtl/sound/jtopl','-Irtl/sound/jt6295']+paths
run=subprocess.run(cmd,cwd=root,capture_output=True,text=True)
(out/'platform-lint.log').write_text(run.stdout+run.stderr)
if run.returncode:
    print('\n'.join(line for line in run.stderr.splitlines() if '%Error' in line))
    raise SystemExit(run.returncode)
print('Production emu source graph lint passed. Intel hardware primitives are black boxes.')
