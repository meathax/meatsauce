"""Reversibly patch the stock MiSTer platform OSD compositor, with a source backup."""
import argparse
import hashlib
from pathlib import Path
import re

MARKER = '// MEATCORES_MAIN_OSD_THEME'
DECLARATIONS = '''// MEATCORES_MAIN_OSD_THEME: bitmap belongs to the platform menu, not credits.
reg [7:0] meat_x;
reg [6:0] meat_y;
reg meat_tall, meat_info_a, meat_info_b;
wire [5:0] meat_art_y = meat_tall ? meat_y[6:1] : (6'd16 + {1'b0,meat_y[5:1]});
wire [1:0] meat_index;
reg [23:0] meat_rgb;
meat_osd_rom meat_background (.clk(clk_video), .ce(ce_pix),
    .x(meat_x[7:1]), .y(meat_art_y), .index(meat_index));
always @(posedge clk_video) if (ce_pix) meat_info_b <= meat_info_a;
always @* begin
    case (meat_index)
        2'd0: meat_rgb = 24'h230a11;
        2'd1: meat_rgb = 24'h2b0c14;
        2'd2: meat_rgb = 24'h380f19;
        2'd3: meat_rgb = 24'h4c1723;
    endcase
end

'''
CAPTURE = '''
        // Match the OSD bitmap's logical coordinates before menu rotation/scaling.
        // ROM and text bitmap both have the same two-enabled-edge read pipeline.
        meat_x <= rot[0] ? (osd_vcnt[7:0] ^ {8{rot[1]}}) : osd_hcnt[7:0];
        meat_y <= rot[0] ? (osd_hcnt2[6:0] ^ {7{~rot[1]}}) : osd_vcnt[6:0];
        meat_tall <= rot[0] ? (osd_w > 64) : (osd_h > 64);
        meat_info_a <= info;
'''


def transform(source):
    if MARKER in source:
        return source
    anchor = 'reg [23:0] rdout;'
    declaration_anchor = 'reg  [2:0] osd_de;'
    capture_anchor = 'osd_de[2:1] <= osd_de[1:0];'
    pattern = r'ordout1\s*<=\s*\{\{osd_pixel,\s*osd_pixel,\s*OSD_COLOR\[2\].*?\};[^\n]*'
    found = re.findall(pattern,source,flags=re.S)
    if source.count(anchor) != 1 or source.count(declaration_anchor) != 1 or source.count(capture_anchor) != 1 or len(found) != 1:
        raise ValueError('This OSD differs from the verified stock MiSTer implementation. '
                         'No files changed; port the compositor patch using OSD_THEME.md.')
    original = found[0]
    replacement = 'if (meat_info_b) ' + original + '\n' + \
        "    else ordout1 <= osd_pixel ? 24'hf5eee8 : meat_rgb; // opaque menu; bright foreground"
    source = source.replace(original,replacement)
    source = source.replace(capture_anchor,capture_anchor+CAPTURE)
    source = source.replace(declaration_anchor,DECLARATIONS+declaration_anchor)
    source = source.replace('parameter  OSD_COLOR    =  3\'d4;',
                            "parameter  OSD_COLOR    =  3'd4; // deep-red menu artwork below; info uses stock tint")
    return source


def install(core):
    core = core.resolve()
    source = core/'sys/osd.v'
    if not source.is_file():
        raise ValueError('Expected a stock sys/osd.v in the specified core')
    # Never follow a shared sys link outside the target core.
    source.resolve().relative_to(core)
    text = source.read_text(encoding='utf-8')
    patched = transform(text)
    if patched == text:
        print('Main OSD theme already installed.')
        return
    backup = source.with_name('osd.v.meatcores-original')
    if backup.exists():
        raise ValueError('Existing OSD backup found; restore or inspect it before applying a new patch')
    backup.write_bytes(source.read_bytes())
    source.write_text(patched,encoding='utf-8')
    print(f'Installed main OSD theme in {source}; original SHA256 '
          f'{hashlib.sha256(backup.read_bytes()).hexdigest()}; backup {backup.name}')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--core',type=Path,default=Path.cwd())
    args = parser.parse_args()
    try:
        install(args.core)
    except (OSError,ValueError) as error:
        parser.exit(1,f'MeatCores OSD theme: {error}\n')
