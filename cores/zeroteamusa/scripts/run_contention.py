"""Graphics deadline bench: real video + ROM bridge + SDRAM controller under a
worst-case CPU load, on captured MAME scenes. Run in Ubuntu WSL.

For each capture: render with ideal 3-clock memory (reference contract) and
with the real memory path under CPU stress, then require the stressed frame to
equal the ideal frame and report sprite line cost against the 6144-clock line.
"""
from pathlib import Path
import argparse, json, struct, subprocess, sys
root = Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('captures', nargs='+')
p.add_argument('--map', type=int, default=1, help='SDRAM address map the RTL uses (0=row low, 1=column low)')
p.add_argument('--stress', type=int, default=2)
p.add_argument('--frames', type=int, default=3)
p.add_argument('--tag', default='run')
p.add_argument('--no-build', action='store_true')
p.add_argument('--build-dir', default='/mnt/r/Verilator/ZeroTeam/contention')
p.add_argument('--skip-ideal', action='store_true')
a = p.parse_args()
assert sys.platform.startswith('linux'), 'Run in Ubuntu WSL'
build = Path(a.build_dir)
scene = root/'build/contention/scene'
scene.mkdir(parents=True, exist_ok=True)
outdir = root/'build/contention'/a.tag
outdir.mkdir(parents=True, exist_ok=True)
srcs = ['rtl/Raiden2/Raiden2_video_timing.sv','rtl/Raiden2/Raiden2_text_renderer.sv',
        'rtl/Raiden2/Raiden2_tile_layer.sv','rtl/Raiden2/Raiden2_sprite_renderer.sv',
        'rtl/Raiden2/spram_dp.sv','rtl/Raiden2/tile_rom_arbiter.sv','rtl/Raiden2/raiden2_mixer.sv',
        'rtl/Raiden2/crypt/zeroteam_sprite_decrypt.sv','rtl/ZeroTeam_video.sv',
        'rtl/ZeroTeam_rom_bridge.sv','rtl/sdram.sv','sim/zero_contention_top.sv']
exe = build/'Vzero_contention_top'
if not a.no_build:
    cmd = ['verilator','--cc','--exe','--build','-j','8','--top-module','zero_contention_top',
           '--Mdir',str(build),'--no-timing','-DSIMULATION','-Wno-fatal','-Wno-TIMESCALEMOD',
           '-Wno-PINMISSING','-Wno-PINCONNECTEMPTY',*srcs,str(root/'sim/contention_main.cpp'),
           '-CFLAGS','-std=c++17 -O2']
    r = subprocess.run(cmd, cwd=root, capture_output=True, text=True)
    (outdir/'build.log').write_text(r.stdout+r.stderr)
    if r.returncode:
        print((r.stdout+r.stderr)[-3000:]); sys.exit(1)

def ppm(path):
    d = Path(path).read_bytes()
    assert d.startswith(b'P6\n320 256\n255\n')
    return d[15:]

aliases = {'bg':['bg_src'],'mg':['mg_src'],'fg':['fg_src'],'text':['tx_src','text_src'],
           'sprite':['sprite_buffer','spr_src','sprite_src'],'palette':['pal_src','palette_src']}
summary = []
fail = False
for cap in a.captures:
    cap = Path(cap).resolve()
    for layer, names in aliases.items():
        f = next(q for q in [cap/(n+'.bin') for n in names] if q.is_file())
        data = f.read_bytes()
        words = list(struct.unpack('<%dH' % (len(data)//2), data)) + [0]*(2048-len(data)//2)
        (scene/f'{layer}.mem').write_text(''.join(f'{w:04x}\n' for w in words))
    crtc = struct.unpack('<32H', (cap/'reg_crtc.bin').read_bytes())
    sc = [crtc[16],crtc[17],crtc[18],crtc[19],crtc[20],crtc[21]]
    layers = (~crtc[14]) & 31
    base = ['--layers',str(layers),'--scroll',*map(str,sc),'--frames',str(a.frames)]
    name = cap.name
    res = {'capture': name}
    runs = [('stress', ['--map',str(a.map),'--stress',str(a.stress)])]
    if not a.skip_ideal: runs.insert(0, ('ideal', ['--ideal']))
    for label, extra in runs:
        o = outdir/f'{name}-{label}'
        r = subprocess.run([str(exe),*base,*extra,'--out',str(o)], cwd=root, capture_output=True, text=True)
        line = [l for l in r.stdout.splitlines() if l.startswith('{')]
        if r.returncode or not line:
            print(name, label, 'FAILED rc', r.returncode, r.stdout[-800:], r.stderr[-800:]); fail = True; continue
        res[label] = json.loads(line[-1])
    if 'ideal' in res and 'stress' in res:
        i, s = ppm(outdir/f'{name}-ideal.ppm'), ppm(outdir/f'{name}-stress.ppm')
        diff = sum(1 for k in range(0, len(i), 3) if i[k:k+3] != s[k:k+3])
        res['stress_vs_ideal_pixels'] = diff
        try:
            from PIL import Image
            ref = Image.open(cap/'reference.png').convert('RGB').tobytes()
            res['ideal_vs_mame_pixels'] = sum(1 for k in range(0, len(i), 3) if i[k:k+3] != ref[k:k+3])
            res['stress_vs_mame_pixels'] = sum(1 for k in range(0, len(s), 3) if s[k:k+3] != ref[k:k+3])
        except Exception as e:
            res['mame_compare_error'] = str(e)
        if diff or res['stress'].get('sprite_overrun_lines') or res['stress'].get('tile_overruns') \
           or res['stress'].get('sdram_violations'):
            fail = True
    summary.append(res)
    s = res.get('stress', {})
    print(f"{name}: spr_max={s.get('sprite_max_line_cycles')} spr_over={s.get('sprite_overrun_lines')} "
          f"tile_over={s.get('tile_overruns')} viol={s.get('sdram_violations')} cpu/f={s.get('cpu_fetches_per_frame')} "
          f"cpu_lat={s.get('cpu_max_latency')} oki_lat={s.get('oki_max_latency')} oki_late={s.get('oki_late_bytes')}/{s.get('oki_windows')} "
          f"stress!=ideal={res.get('stress_vs_ideal_pixels')} ideal!=mame={res.get('ideal_vs_mame_pixels')} "
          f"stress!=mame={res.get('stress_vs_mame_pixels')}", flush=True)
(outdir/'summary.json').write_text(json.dumps(summary, indent=1))
sys.exit(1 if fail else 0)
