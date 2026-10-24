"""Reproducible tooling-only patches for the pinned donor checkout."""
from pathlib import Path
import hashlib
import json
import os
import subprocess

ROOT = Path(__file__).resolve().parents[1]
DONOR = ROOT / 'donors/jtcores'
MAME_EXE = os.environ.get('MAME_EXE', 'D:/Arcade/AI/mameexe/mame.exe')


def patch_mister_clock_target():
    """Make JTFRAME's target-specific clock lookup accept lowercase CLI targets."""
    rel = 'modules/jtframe/src/jtframe/macros/macros.go'
    original = subprocess.check_output(
        ['git', '-C', str(DONOR), 'show', f'HEAD:{rel}']
    ).decode('utf-8').replace('\r\n', '\n')
    anchor = 'func make_clocks(target string) (mclk int) {\n'
    if original.count(anchor) != 1:
        raise RuntimeError('pinned JTFRAME make_clocks anchor changed')
    patched = original.replace(
        anchor, anchor + '\ttarget = strings.ToUpper(target)\n', 1
    )
    path = DONOR / rel
    current = path.read_text(encoding='utf-8').replace('\r\n', '\n')
    if current not in (original, patched):
        raise RuntimeError('JTFRAME macros.go has unexpected local changes')
    if current != patched:
        path.write_text(patched, encoding='utf-8', newline='\n')


patch_mister_clock_target()
path = DONOR / 'modules/jtframe/bin/jtsim-funcs'
original = subprocess.check_output(['git', '-C', str(DONOR), 'show',
                                    'HEAD:modules/jtframe/bin/jtsim-funcs'])
text = original.decode().replace('\r\n', '\n')
before = 'local corename=$(realpath `pwd` --relative-to=$CORES | cut -d/ -f1)'
after = 'local corename=$(realpath "$(pwd)" --relative-to="$CORES" | cut -d/ -f1)'
if before in text:
    text = text.replace(before, after)
elif after not in text:
    raise SystemExit('Unexpected donor corename function; refusing patch')
before = 'local setname=$(basename `pwd`)'
after = 'local setname=$(basename "$(pwd)")'
if before in text:
    text = text.replace(before, after)
elif after not in text:
    raise SystemExit('Unexpected donor setname function; refusing patch')
path.write_bytes(text.encode())
simulator = DONOR / 'modules/jtframe/bin/jtsim'
simtext = subprocess.check_output(['git', '-C', str(DONOR), 'show',
    'HEAD:modules/jtframe/bin/jtsim']).decode().replace('\r\n', '\n')
anchor = 'jtframe mem $SYSNAME --target "$TARGET" --local || exit $?'
assert simtext.count(anchor) == 1
simtext = simtext.replace(anchor, anchor + '\n    if [ -n "$MN_PRELOAD" ]; then python3 "$MN_PRELOAD" "$SETNAME" || exit $?; fi')
cleanup = 'rm -rf video.bin frame_*.jpg frame_*.png frame.raw frames'
assert simtext.count(cleanup) == 2
simtext = simtext.replace(cleanup, ': # capture cleanup moved after simulation lock admission')
anchor = 'trap release_simulation_lock EXIT'
assert simtext.count(anchor) == 1
simtext = simtext.replace(anchor, anchor + '\n' + cleanup)
simulator.write_bytes(simtext.encode())
testcpp = DONOR / 'modules/jtframe/verilator/test.cpp'
live_helper = ROOT / 'scripts/live_frame_rtl.hpp'
if not live_helper.is_file():
    raise SystemExit('live frame helper is missing')
(DONOR / 'modules/jtframe/verilator/live_frame_rtl.hpp').write_bytes(live_helper.read_bytes())
cpptext = subprocess.check_output(['git','-C',str(DONOR),'show',
    'HEAD:modules/jtframe/verilator/test.cpp']).decode().replace('\r\n','\n')
anchor = 'void start( bool download ) {'
assert cpptext.count(anchor) == 1
cpptext = cpptext.replace(anchor, anchor + '''
#ifdef _MNYMNY_DIRECT_PRELOAD
        if (!download) {
            full_download = false;
            done = true;
            download_finished = true;
            dut.ioctl_rom = 0;
            dut.ioctl_wr = 0;
            dut.ioctl_addr = 0;
            dut.ioctl_dout = 0;
#ifdef _JTFRAME_IOCTL_RD
            dut.ioctl_ram = 0;
#endif
            fprintf(stderr,"PRELOAD_BYPASS: no clocked ROM/header/PROM transfers.\\n");
            return;
        }
#endif
''')
capture_template = (ROOT/'scripts/frame_capture.inc.cpp').read_text()
assert capture_template.count('{{ORIGINAL_BODY}}') == 1
start = cpptext.index('void JTSim::video_dump() {')
end = cpptext.index('\n}\n', start) + 3
old_method = cpptext[start:end]
old_body = old_method[old_method.index('{')+1:old_method.rfind('}')]
cpptext = cpptext[:start] + capture_template.replace('{{ORIGINAL_BODY}}', old_body) + cpptext[end:]
final_anchor = 'JTSim::~JTSim() {\n'
reset_anchor = '    sim_inputs.restore_dipsw();\n    reset(0);'
assert cpptext.count(reset_anchor) == 1
cpptext = cpptext.replace(reset_anchor, '''    sim_inputs.restore_dipsw();
#ifdef _MNYMNY_RESET_EPOCH
    reset(1); // cold-reset experiment: no unreset clocks before initialization
#else
    reset(0);
#endif''')
assert cpptext.count(final_anchor) == 1
cpptext = cpptext.replace(final_anchor, final_anchor + '''#ifdef _MNYMNY_DIRECT_PRELOAD
    // Invoke SystemVerilog final blocks before destroying the harness.
    game.final();
#endif
''')
testcpp.write_bytes(cpptext.encode())
anchor = '-o sim --quiet-stats'
assert text.count(anchor) == 1
text = text.replace(anchor, anchor + ' --threads ${MN_VLT_THREADS:-4}')
path.write_bytes(text.encode())
# The working core was copied by native Windows Git; run its shell helpers in
# Linux with LF endings. HDL bytes are not changed by this tooling repair.
for script in (ROOT / 'cores/mnymny').rglob('*.sh'):
    script.write_bytes(script.read_bytes().replace(b'\r\n', b'\n'))
receipt = dict(path=str(path.relative_to(ROOT)),
               original_sha256=hashlib.sha256(original).hexdigest(),
               patched_sha256=hashlib.sha256(path.read_bytes()).hexdigest(),
               changes=['quote realpath pwd and CORES', 'quote basename pwd',
                        'Verilator --threads 4', 'optional direct ROM preload hook',
                        'capture cleanup only after simulation lock admission'])
receipt['changes'].append('optional C++ complete ROM/header/PROM bypass for prefilled models')
receipt['testcpp_patched_sha256'] = hashlib.sha256(testcpp.read_bytes()).hexdigest()
receipt['frame_capture_template_sha256'] = hashlib.sha256((ROOT/'scripts/frame_capture.inc.cpp').read_bytes()).hexdigest()
receipt['changes'].append('optional synchronous complete-frame PPM/journal observer; configurable multithreading')
receipt['changes'].append('direct-preload profile explicitly invokes model final callbacks')
receipt['changes'].append('optional cold-reset epoch profile asserts reset before the first driver clock')
(ROOT / 'docs/evidence/donor-tooling.json').write_text(json.dumps(receipt, indent=2))
xml = ROOT / 'docs/evidence/mame0289.xml'
with xml.open('wb') as output:
    subprocess.run([MAME_EXE, '-listxml',
                    'monymony*', 'jackrabt*'], stdout=output, check=True)
# JTFRAME defaults to this path. The pinned original remains in donor Git.
(DONOR / 'doc/mame.xml').write_bytes(xml.read_bytes())
print('Patched donor shell path handling; generated current MAME XML')
