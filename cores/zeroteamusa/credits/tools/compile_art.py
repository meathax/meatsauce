"""Pack the generated OSD artwork as a tiny 128x64, 2-bit internal ROM."""
import argparse
import json
from pathlib import Path
from PIL import Image

PALETTE = [(35,10,17),(43,12,20),(56,15,25),(76,23,35)]


def compile_art(source, root):
    original = Image.open(source).convert('RGB')
    if abs(original.width/original.height - 2) > 0.01:
        raise ValueError('OSD artwork must have aspect ratio 2:1; do not stretch another ratio')
    small = original.resize((128,64),Image.Resampling.LANCZOS)
    luminance = list(small.convert('L').getdata())
    ordered = sorted(luminance)
    thresholds = [ordered[int((len(ordered)-1)*p)] for p in (0.40,0.70,0.90)]
    indices = [sum(value > threshold for threshold in thresholds) for value in luminance]
    image = Image.new('P',(128,64))
    image.putpalette([component for color in PALETTE for component in color]+[0]*(768-12))
    image.putdata(indices)
    assets = root/'osd/assets'
    generated = root/'generated'
    assets.mkdir(parents=True,exist_ok=True)
    generated.mkdir(parents=True,exist_ok=True)
    image.save(assets/'meatcores_128x64.png',optimize=True)
    assignments = '\n'.join(f"        pixels[{i}] = 2'd{value};" for i,value in enumerate(indices))
    (generated/'meat_osd_rom.sv').write_text(f'''// Generated build-time artwork, 128x64, 2 bits/pixel, 16384 bits.
// Menu background only. Text remains in the existing MiSTer OSD bitmap.
module meat_osd_rom(input wire clk, input wire ce,
    input wire [6:0] x, input wire [5:0] y, output reg [1:0] index);
    (* romstyle = "M10K" *) reg [1:0] pixels [0:8191];
    initial begin
{assignments}
    end
    always @(posedge clk) if (ce) index <= pixels[{{y,x}}];
endmodule
''',encoding='ascii')
    metadata = {'logical_menu_size':[256,128], 'rom_size':[128,64],
                'bits_per_pixel':2, 'rom_bits_per_osd':16384,
                'palette':PALETTE,'indices':indices,
                'low_resolution':'center crop to 256x64, no aspect stretch',
                'generation':'Built-in ImageGen; opaque dark burgundy marbling and large MEATCORES watermark positioned clear of the left menu sidebar.'}
    (generated/'meat_osd_manifest.json').write_text(json.dumps(metadata)+'\n',encoding='utf-8')
    print('Compiled OSD artwork: 128x64, 2-bit, 16384 bits per OSD instance; runtime assets: none.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source',type=Path)
    parser.add_argument('--credits-root',type=Path,default=Path(__file__).resolve().parents[1])
    args = parser.parse_args()
    compile_art(args.source,args.credits_root)
