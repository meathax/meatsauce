"""Verify the MeatCore Credits host boundary with Icarus; never invokes Quartus."""
from pathlib import Path
import json
import os
import re
import subprocess
import sim

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'sim/obj_dir/credits'
BIN = sim.MSYS / 'ucrt64/bin'


def extract(pattern, text):
    match = re.search(pattern, text, re.S)
    if not match:
        raise AssertionError(f'Missing host binding: {pattern}')
    return match.group(0)


def menu_rows(conf, mask):
    """Visible OSD rows in order, as Main_MiSTer lists them for a status_menumask."""
    rows = []
    for entry in re.findall(r'"([^"]*)"', conf):
        for item in filter(None, entry.split(';')):
            hidden = False
            while len(item) > 1 and item[0] in 'HhDd' and item[1].isdigit():
                bit = int(item[1])
                hidden |= item[0] in 'Hh' and bool(mask >> bit & 1) == (item[0] == 'H')
                item = item[2:]
            if not hidden and item[0] in 'OTR' or item == 'DIP' or item.startswith('-'):
                rows.append(item)
    return rows


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    wrapper = (ROOT / 'CrystalSystem.sv').read_text()
    conf = extract(r'localparam CONF_STR = \{.*?\n\};', wrapper)
    assert conf.count('"R[120],Credits;"') == 1
    assert wrapper.count('status[120]') == 1 and 'wire [127:0] status;' in wrapper
    # Every option, trigger and action owns distinct status bits; 120 is the overlay's alone.
    used = []
    for kind, field in re.findall(r'([OTR])(\[\d+(?::\d+)?\]|\w+),', conf):
        bits = [int(b) for b in field.strip('[]').split(':')] if field.startswith('[') else [int(field, 36)]
        span = list(range(min(bits), max(bits) + 1))
        if kind != 'O':
            assert len(span) == 1
        used.append((kind, span))
    for kind, span in used:
        if 120 in span:
            assert (kind, span) == ('R', [120]), f'Occupied status bit 120: {kind}{span}'
    options = [b for k, s in used if k == 'O' for b in s]
    assert len(options) == len(set(options)) and not set(options) & {0, 120}
    # The Credits row is never hidden or disabled, so the highlighted row the HPS
    # selects is the same entry in every menumask state, and OK pulses bit 120.
    for mask in range(4):
        rows = menu_rows(conf, mask)
        assert rows.count('R[120],Credits') == 1, rows
        assert rows[rows.index('R[120],Credits') - 1] == 'DIP'
        assert rows[rows.index('R[120],Credits') + 1] == 'T[0],Reset'
    assert re.search(r'"R\[120\],Credits;"', conf) and not re.search(r'"[HhDd]\d+R\[120\]', conf)
    hps = extract(r'hps_io #\(.*?\n\);', wrapper)
    header = (ROOT / 'sys/hps_io.sv').read_text()
    for index in range(6):
        assert f'.joystick_{index}(joystick_{index})' in hps
        assert re.search(rf'output reg \[31:0\] joystick_{index}\b', header)
    for port in ('buttons', 'ps2_key', 'ps2_mouse'):
        assert f'.{port}({port})' in hps
    dismiss = extract(r'wire credits_dismiss = .*?;', wrapper)
    overlay = extract(r'credits_overlay #\(.*?\n\);', wrapper)
    assert wrapper.count('credits_overlay #(') == 1
    assert all(p in overlay for p in ['.WIDTH(320)', '.HEIGHT(240)', '.SCALE_LOG2(0)', '.SCROLL_FRAMES(4)',
                                      '.clk_video(clk_sys)', '.ce_pixel(native_ce)', '.reset(memory_reset)'])
    hold = (ROOT / 'rtl/video/cs_video_hold.sv').read_text()
    assert 'HVIS = 320, VVIS = 240' in hold
    video = extract(r'arcade_video #\(.*?\n\);', wrapper)
    for port, signal in [('RGB_in', 'credits_rgb'), ('HSync', 'credits_hs'), ('VSync', 'credits_vs'),
                         ('HBlank', 'credits_hb'), ('VBlank', 'credits_vb'), ('ce_pix', 'native_ce')]:
        assert f'.{port}({signal})' in video
    rotate = extract(r'cs_screen_rotate rotate \(.*?\n\);', wrapper)
    for port, signal in [('frame_start', 'credits_frame'), ('display_enable', 'credits_de'),
                         ('pixel_x', 'credits_x2'), ('pixel_y', 'credits_y2'), ('rgb', 'credits_rgb')]:
        assert f'.{port}({signal})' in rotate
    assert wrapper.index(overlay) < wrapper.index(video) < wrapper.index(rotate)
    files = (ROOT / 'files.qip').read_text()
    assert files.count('QIP_FILE credits/credits.qip') == 1
    assert files.count('PRE_FLOW_SCRIPT_FILE "quartus_sh:credits_preflow.tcl"') == 1
    qsf = (ROOT / 'CrystalSystem.qsf').read_text()
    assert qsf.index('source rtl/mister/sys_project.tcl') < qsf.index('source files.qip')
    hook = (ROOT / 'credits_preflow.tcl').read_text()
    assert hook.index('sys build_id.tcl') < hook.index('credits preflow.tcl')
    assert 'set ::env(CREDITS_COLUMNS) 48' in hook
    manifest = json.loads((ROOT / 'credits/generated/manifest.json').read_text())
    assert manifest['visible_columns'] == 48 and (48 * 6 + 16) <= 320
    print('PASS host bindings: native 320x240, visible Credits row on bit 120, six HPS ports, '
          'aligned scaler/rotation taps, QIP/preflow')

    # Instantiate the actual host source rather than duplicating its port wiring.
    bench = (ROOT / 'sim/credits/credits_overlay_tb.sv').read_text()
    original = extract(r'credits_overlay #\(.*?\);', bench)
    aliases = '''
    wire clk_sys = clk, native_ce = ce, OSD_STATUS = osd_status, memory_reset = reset;
    wire [127:0] status = {7'd0, trigger, 120'd0};
    wire [31:0] joystick_0 = joysticks[31:0] | {31'd0, dismiss};
    wire [31:0] joystick_1 = joysticks[63:32], joystick_2 = joysticks[95:64];
    wire [31:0] joystick_3 = joysticks[127:96], joystick_4 = joysticks[159:128];
    wire [31:0] joystick_5 = joysticks[191:160];
    wire [1:0] buttons = mister_buttons;
    wire [24:0] ps2_mouse = {22'd0, mouse_buttons};
    wire [23:0] native_rgb = {r, g, bl};
    wire native_hs = hs, native_vs = vs, native_hblank = hb, native_vblank = vb;
    wire [7:0] credits_r, credits_g, credits_b;
    wire credits_hs, credits_vs, credits_hb, credits_vb, credits_de, credits_active;
    assign {ro, go, bo} = {credits_r, credits_g, credits_b};
    assign {hso, vso, hbo, vbo, deo, active} =
           {credits_hs, credits_vs, credits_hb, credits_vb, credits_de, credits_active};
    '''
    host_instance = re.sub(r'\) credits \(', ') dut (', overlay)
    bench = bench.replace(original, aliases + dismiss + '\n' + host_instance)
    # The portable bench uses two-frame scrolling; the host uses four frames.
    advance = 'blank_frame();\n        if (dut.phase != dut.START_PHASE+1)'
    assert advance in bench
    bench = bench.replace(advance,
        'blank_frame(); raster(0,0); blank_frame(); raster(0,0); blank_frame();\n'
        '        if (dut.phase != dut.START_PHASE+1)')
    bench = bench.replace('dut.frame_timer = 1;', 'dut.frame_timer = 3;')
    (OUT / 'host_tb.sv').write_text(bench)
    env = os.environ.copy()
    env['PATH'] = str(BIN) + os.pathsep + env.get('PATH', '')
    binary = OUT / 'host.vvp'
    subprocess.run([str(BIN / 'iverilog.exe'), '-g2012', '-s', 'overlay_tb',
                    '-I', str(ROOT / 'credits/generated'), '-o', str(binary),
                    str(OUT / 'host_tb.sv'), str(ROOT / 'credits/rtl/credits_overlay.sv'),
                    str(ROOT / 'credits/generated/credits_rom.sv')], check=True, env=env)
    (OUT / 'build').mkdir(exist_ok=True)
    subprocess.run([str(BIN / 'vvp.exe'), str(binary)], cwd=OUT, check=True, env=env)
    colors = set()
    captures = list((OUT / 'build').glob('frame_*.ppm'))
    assert captures
    for capture in captures:
        pixels = capture.read_bytes().split(b'\n', 3)[3]
        assert len(pixels) == 320 * 240 * 3
        colors.update(pixels[index:index+3] for index in range(0, len(pixels), 3))
    assert bytes.fromhex('e9b949') in colors, 'Gold tier missing from native captures'
    assert bytes.fromhex('d97b79') in colors, 'Meatlovers tier missing from native captures'
    print('PASS native captures: complete 320x240 frames and both tier palettes')

    # Exercise the full hook with Quartus project queries stubbed, without a build.
    stub = '''
    set quartus(args) {preflow CrystalSystem CrystalSystem}
    proc project_exists {args} {return 1}
    proc project_open {args} {}
    proc project_close {} {}
    proc is_project_open {} {return 1}
    proc get_global_assignment {args} {
        if {[lindex $args end] eq "DEVICE"} {return 5CSEBA6U23I7}
        return output_files
    }
    proc post_message {args} {puts $args}
    '''
    stub += 'source {' + (ROOT / 'credits_preflow.tcl').as_posix() + '}\n'
    (OUT / 'hook_tb.tcl').write_text(stub)
    before = {path: path.read_bytes() for path in (ROOT / 'credits/generated').iterdir() if path.is_file()}
    subprocess.run([str(sim.MSYS / 'mingw64/bin/tclsh.exe'), str(OUT / 'hook_tb.tcl')], cwd=OUT, check=True, env=env)
    assert (OUT / 'build_id.v').read_text().startswith('`define BUILD_DATE')
    assert 'CrystalSystem.sof' in (OUT / 'jtag.cdf').read_text()
    assert all(path.read_bytes() == content for path, content in before.items())
    print('PASS chained preflow: build ID, CDF and byte-identical regenerated ROM/MIF')


if __name__ == '__main__':
    main()
