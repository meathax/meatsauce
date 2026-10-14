"""Render one captured MAME scene with real RTL in an isolated component test."""
from pathlib import Path
import argparse, hashlib, json, re, shutil, struct, subprocess, sys
root = Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('name')
p.add_argument('--capture', required=True)
p.add_argument('--flip', action='store_true', help='Exercise the production global flip input')
p.add_argument('--early-line-select', action='store_true', help='Diagnostic copied-RTL variant only')
p.add_argument('--early-line-start', action='store_true', help='Detect actual counter wrap before the next pixel enable')
p.add_argument('--blank-line-start', action='store_true', help='Prepare incoming row and first pixel during final blanking pixel')
p.add_argument('--preload-first-pixel', action='store_true', help='Prepare inactive row pixel zero without moving prefetch timing')
a = p.parse_args()
assert sys.platform.startswith('linux'), 'Run explicitly in Ubuntu WSL'
assert re.fullmatch(r'[A-Za-z0-9_-]+', a.name)
capture = Path(a.capture).resolve()
work = root/'sim/results/video-scenes'/a.name
assert not work.exists(), 'Retain old evidence; use another name'
out = work/'sim/results'
out.mkdir(parents=True)
sha = lambda q: hashlib.sha256(Path(q).read_bytes()).hexdigest()
sources = [f'rtl/Raiden2/{n}.sv' for n in ['Raiden2_video_timing', 'Raiden2_text_renderer',
          'Raiden2_tile_layer', 'Raiden2_sprite_renderer', 'spram_dp', 'tile_rom_arbiter', 'raiden2_mixer']]
sources += ['rtl/Raiden2/crypt/zeroteam_sprite_decrypt.sv', 'rtl/ZeroTeam_video.sv']
support = [f'rtl/Raiden2/crypt/{n}.hex' for n in ['rotate_zt', 'x5_zt', 'x11_zt']]
support += ['rtl/Raiden2/raiden2_blend.mem']
support += ['sim/zero_video_top.sv', 'sim/video_main.cpp']
before = {s: sha(root/s) for s in sources+support}
for s in sources+support:
    target = work/s
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(root/s, target)
assert {s: sha(work/s) for s in before} == before
assert {s: sha(root/s) for s in before} == before, 'Source changed during copying'
(work/'roms').symlink_to(root/'roms', target_is_directory=True)
aliases = {'bg': ['bg_src'], 'mg': ['mg_src'], 'fg': ['fg_src'],
           'text': ['tx_src', 'text_src'], 'sprite': ['sprite_buffer', 'spr_src', 'sprite_src'],
           'palette': ['pal_src', 'palette_src']}
fixture = {}
for layer, names in aliases.items():
    candidates = [capture/(n+'.bin') for n in names]
    candidates += [q for n in names for q in capture.glob('*'+n+'.bin')]
    found = next((q for q in candidates if q.is_file()), None)
    assert found is not None, f'Missing {layer} source in {capture}'
    data = found.read_bytes()
    assert len(data)%2 == 0 and len(data)<=4096
    words = [int.from_bytes(data[i:i+2], 'little') for i in range(0, len(data), 2)]
    words += [0]*(2048-len(words))
    (out/f'video-fixture-{layer}.mem').write_text(''.join(f'{n:04x}\n' for n in words))
    fixture[layer] = {'source': found.as_posix(), 'bytes': len(data), 'sha256': sha(found)}
# Read the scene's actual controls; attract scrolls are not gameplay scrolls.
crtc_source = capture/'reg_crtc.bin'
crtc_bytes = crtc_source.read_bytes()
assert len(crtc_bytes) == 64, 'Expected captured 32-word target CRTC'
crtc = struct.unpack('<32H', crtc_bytes)
scrolls = {layer: list(crtc[word:word+2])
           for layer,word in [('bg',16),('mg',18),('fg',20)]}
layer_enable = (~crtc[14]) & 31
fixture['crtc'] = {'source': crtc_source.as_posix(), 'bytes': len(crtc_bytes),
                   'sha256': sha(crtc_source)}
top = work/'sim/zero_video_top.sv'
text = top.read_text()
for layer,values in scrolls.items():
    for axis,value in zip(('x','y'),values):
        pin = f'{layer}_{axis}'
        old = f'.{pin}(16\'d0)'
        assert text.count(old)==1
        text = text.replace(old, f'.{pin}(16\'d{value})')
assert text.count(".layer_enable(5'b11111)") == 1
text = text.replace(".layer_enable(5'b11111)", f".layer_enable(5'd{layer_enable})")
if a.flip:
    assert text.count('.flip_screen(flip)') == 1
    text = text.replace('.flip_screen(flip)', ".flip_screen(1'b1)")
top.write_text(text)
variant = {}
if a.early_line_select:
    tile = work/'rtl/Raiden2/Raiden2_tile_layer.sv'
    text, count = re.subn(r'(active_buf_r\s*<=\s*)active_buf\s*;',
                         r'\1active_buf ^ gated_new_line;', tile.read_text())
    assert count == 1, 'Unexpected tile read-bank selector'
    tile.write_text(text)
    variant = {'scope': 'Diagnostic copied RTL only; worktree RTL untouched',
               'change': 'Select the incoming tile row on its new_line clock',
               'patched_tile_sha256': sha(tile)}
if a.early_line_start:
    video = work/'rtl/ZeroTeam_video.sv'
    text = video.read_text()
    replacements = {'else if(ce_pixel)h_prev<=hpos;': 'else h_prev<=hpos;',
                    'wire new_line=ce_pixel && hpos==0 && h_prev!=0;':
                    'wire new_line=!reset && hpos==0 && h_prev!=0;'}
    for old, new in replacements.items():
        assert text.count(old)==1, 'Unexpected video line-start detector'
        text = text.replace(old,new)
    video.write_text(text)
    variant['early_line_start'] = {'scope': 'Diagnostic copied RTL only',
                                  'patched_video_sha256': sha(video)}
if a.blank_line_start:
    assert not a.early_line_start, 'Choose one line-start strategy'
    video = work/'rtl/ZeroTeam_video.sv'
    text = video.read_text()
    replacements = {
        'else if(ce_pixel)h_prev<=hpos;': 'else h_prev<=hpos;',
        'wire new_line=ce_pixel && hpos==0 && h_prev!=0;':
        'wire new_line=!reset && hpos==511 && h_prev!=511;',
        'wire [8:0] logical_y=vpos[8:0]-v_start;':
        'wire [9:0] incoming_vpos=(vpos==281)?10\'d0:(vpos+10\'d1);\n    wire [8:0] logical_y=incoming_vpos[8:0]-v_start;',
        'wire [8:0] prefetch_y=(vpos==281)?9\'d255:((logical_y==255)?9\'d300:logical_y);':
        'wire [8:0] prefetch_y=(incoming_vpos==281)?9\'d255:((logical_y==255)?9\'d300:logical_y);',
        'wire [9:0] next_x=flip_screen?(read_x-10\'d1):(read_x+10\'d1);':
        'wire [9:0] next_x=hblank ? (flip_screen?10\'d319:10\'d0) : (flip_screen?(read_x-10\'d1):(read_x+10\'d1));'}
    for old,new in replacements.items():
        assert text.count(old)==1, 'Unexpected video blanking boundary wiring'
        text = text.replace(old,new)
    video.write_text(text)
    variant['blank_line_start'] = {'scope':'Diagnostic copied RTL only',
                                  'patched_video_sha256':sha(video)}
if a.preload_first_pixel:
    assert not (a.early_line_select or a.early_line_start or a.blank_line_start)
    tile = work/'rtl/Raiden2/Raiden2_tile_layer.sv'
    text,count = re.subn(r'(active_buf_r\s*<=\s*)active_buf\s*;',
                        lambda m: m.group(1)+"active_buf ^ (!de || hpos==(flip_screen ? 10'd319 : 10'd0));",
                        tile.read_text())
    assert count==1
    tile.write_text(text)
    video = work/'rtl/ZeroTeam_video.sv'
    text = video.read_text()
    old = 'wire [9:0] next_x=flip_screen?(read_x-10\'d1):(read_x+10\'d1);'
    assert text.count(old)==1
    text = text.replace(old,'wire [9:0] next_x=hblank ? (flip_screen?10\'d319:10\'d0) : (flip_screen?(read_x-10\'d1):(read_x+10\'d1));')
    video.write_text(text)
    variant['preload_first_pixel'] = {'scope':'Diagnostic copied RTL only',
                                     'patched_tile_sha256':sha(tile),'patched_video_sha256':sha(video)}
meta = {'scope': 'Component renderer only; observed MAME RAM fixture, no live CPU/gameplay proof',
        'flip_screen': a.flip,
        'source_sha256': before, 'fixture': fixture,
        'fixture_top_sha256': sha(top), 'scrolls': scrolls, 'layer_enable': layer_enable,
        'rom_regions': {q.name: sha(q) for q in (root/'roms/regions').glob('*.bin')},
        'diagnostic_variant': variant}
(out/'scene-source-stamp.json').write_text(json.dumps(meta, indent=2)+'\n')
(work/'sim/build/video').mkdir(parents=True)
cmd = ['verilator','--cc','--exe','--build','-j','4','--top-module','zero_video_top',
       '--Mdir','sim/build/video','--no-timing','-Wno-fatal','-Wno-TIMESCALEMOD','-Wno-PINMISSING',
       *sources,'sim/zero_video_top.sv',str(work/'sim/video_main.cpp'),'-CFLAGS','-std=c++17 -O2']
print(f'Isolated captured-scene renderer: {work}', flush=True)
with (out/'scene-build.log').open('w') as log:
    result = subprocess.run(cmd, cwd=work, stdout=log, stderr=subprocess.STDOUT)
if result.returncode:
    print('\n'.join((out/'scene-build.log').read_text().splitlines()[-30:]))
    raise SystemExit(result.returncode)
model = work/'sim/build/video/Vzero_video_top'
meta['model_binary_sha256'] = sha(model)
(out/'scene-source-stamp.json').write_text(json.dumps(meta, indent=2)+'\n')
raise SystemExit(subprocess.call([str(model)], cwd=work))
