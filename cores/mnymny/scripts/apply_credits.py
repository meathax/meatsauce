"""Install the portable credits panel into an isolated JTFRAME build snapshot."""
import argparse
import shutil
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT/'cores/mnymny'
parser = argparse.ArgumentParser()
parser.add_argument('--snapshot', required=True, type=Path)
args = parser.parse_args()
snapshot = args.snapshot.resolve()
assert snapshot.is_dir() and (snapshot/'modules/jtframe').is_dir()
destination = snapshot/'cores/mnymny/credits'
if not destination.exists():
    shutil.copytree(SOURCE/'credits', destination)
    shutil.copy2(SOURCE/'credits.txt', destination.parent/'credits.txt')
else:
    assert (destination/'rtl/credits_overlay.sv').is_file()
preflow = destination/'host_preflow.tcl'
preflow.write_text('source [file join [file dirname [info script]] preflow.tcl]\n'
                   'source [file join [file dirname [info script]] .. .. .. modules jtframe target mister hdl sys build_id.tcl]\n')
host = snapshot/'modules/jtframe/target/mister/hdl/jtframe_mister.sv'
source = host.read_text()
marker = '// MEATCORE_CREDITS_INSERTION'
if marker not in source:
    anchor = 'localparam VIDEO_DW = COLORW!=5 ? 3*COLORW : 24;'
    assert source.count(anchor)==1
    block = '''// MEATCORE_CREDITS_INSERTION
wire [7:0] meat_r, meat_g, meat_b;
wire meat_hs, meat_vs, meat_hb, meat_vb, meat_de, meat_active;
wire [1:0] meat_rotation = (direct_video || !rotate[0]) ?
    (framebuf_flip ? 2'd2 : 2'd0) :
    ((rotate[1] ^ (status[40:39]==3)) ? 2'd3 : 2'd1);
credits_overlay #(.WIDTH(VIDEO_WIDTH), .HEIGHT(VIDEO_HEIGHT)) u_meat_credits (
    .clk_video(clk_sys), .reset(rst), .ce_pixel(pxl_cen),
    .menu_trigger(status[62]),
    .dismiss((|joyusb_1) | (|joyusb_2) | (|joystick3) |
             (|joystick4) | (|buttons) | (|ps2_mouse[2:0]) |
             OSD_STATUS),
    .rotation(meat_rotation),
    .r_in(base_r), .g_in(base_g), .b_in(base_b),
    .hs_in(base_hs), .vs_in(base_vs),
    .hblank_in(~base_lhbl), .vblank_in(~base_lvbl),
    .r_out(meat_r), .g_out(meat_g), .b_out(meat_b),
    .hs_out(meat_hs), .vs_out(meat_vs),
    .hblank_out(meat_hb), .vblank_out(meat_vb),
    .de_out(meat_de), .active(meat_active)
);
'''
    # Insert after base RGB declaration to avoid implicit net declarations.
    anchor = 'assign {base_r,base_g,base_b} = base_rgb;'
    assert source.count(anchor)==1
    source = source.replace(anchor,anchor+'\n'+block)
    source = source.replace('.RGB_in     ( game_rgb      ),',
                            '.RGB_in     ( {meat_r,meat_g,meat_b} ),')
    source = source.replace('.HBlank     ( ~base_lhbl    ),', '.HBlank     ( meat_hb      ),')
    source = source.replace('.VBlank     ( ~base_lvbl    ),', '.VBlank     ( meat_vb      ),')
    source = source.replace('.HSync      ( hsize_hs      ),', '.HSync      ( meat_hs      ),')
    source = source.replace('.VSync      ( hsize_vs      ),', '.VSync      ( meat_vs      ),')
    host.write_text(source)
print('Credits source installed in snapshot:', snapshot)
