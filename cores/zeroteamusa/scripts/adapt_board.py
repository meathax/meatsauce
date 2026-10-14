"""Apply the initial Zero Team board-map adaptation once; preserve donor engines."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
main_path = ROOT / 'rtl/Raiden2/Raiden2_main_top.sv'
text = main_path.read_text(encoding='utf-8')
if 'Zero Team USA board adaptation' in text:
    raise SystemExit('Already adapted; edit active RTL directly.')
text = '// Zero Team USA board adaptation: see PROVENANCE.md.\n' + text
text = text.replace('input  wire  [7:0] p2_input,', 'input  wire  [7:0] p2_input,\n\tinput  wire  [7:0] p3_input,\n\tinput  wire  [7:0] p4_input,')
text = text.replace("p3p4_data_lat   <= 16'hFFFF;", "p3p4_data_lat   <= {p4_input, p3_input};")
# Source staging addresses follow zeroteam_mem; renderer DMA offsets stay intact.
text = text.replace("cpu_addr[11:1] - 11'h400", 'cpu_addr[11:1]')
text = text.replace("cop_dma_fill_addr[10:0] - 11'h400", 'cop_dma_fill_addr[10:0]')
text = text.replace("cop_dma_src_byte[11:1] - 11'h400", 'cop_dma_src_byte[11:1]')
text = text.replace("23'h06000", "23'h07800").replace("23'h06800", "23'h08000")
text = text.replace("16'h6000", "16'h7800").replace("16'h6800", "16'h8000")
# Replace the five fill-region declarations atomically, without cascading literals.
ranges = {'bg': ('05C00', '06000'), 'fg': ('06000', '06400'),
          'mg': ('06400', '06800'), 'txt': ('06800', '07000'),
          'pal': ('07000', '07800')}
for layer, (lo, hi) in ranges.items():
    text, count = re.subn(rf"wire {layer}_fill\s*=.*?;", f"wire {layer}_fill = cop_dma_fill_we & (cop_dma_fill_addr >= 23'h{lo}) & (cop_dma_fill_addr < 23'h{hi});", text)
    assert count == 1, layer
start = text.index('\tcase (cop_src_top13)')
end = text.index('\tendcase', start) + len('\tendcase')
text = text[:start] + '''\tcase (cop_src_top13)
        13'h017: cop_src_mux = bg_stage_b; // B800-BFFF
        13'h018: cop_src_mux = fg_stage_b; // C000-C7FF
        13'h019: cop_src_mux = mg_stage_b; // C800-CFFF
        13'h01A, 13'h01B: cop_src_mux = txt_stage_b; // D000-DFFF
        13'h01C, 13'h01D: cop_src_mux = pal_stage_b; // E000-EFFF
        13'h01E, 13'h01F: cop_src_mux = spr_DOUT; // F000-FFFF
        default: cop_src_mux = ram_rdata;
    endcase''' + text[end:]
main_path.write_text(text, encoding='utf-8')

path = ROOT / 'rtl/Raiden2/raiden2_addr_main.sv'
text = path.read_text(encoding='utf-8')
start = text.index("\t\tend else if (A < 20'h0C000)")
end = text.index("\t\tend else if (A < 20'h40000)", start)
text = text[:start] + '''        end else if (A < 20'h00800) begin
            // Unmapped I/O holes return open bus, never alias RAM.
        end else if (A < 20'h0B800) begin
            ram_memrq = 1'b1;
        end else if (A < 20'h0C000) begin
            bg_memrq = 1'b1;
        end else if (A < 20'h0C800) begin
            fg_memrq = 1'b1;
        end else if (A < 20'h0D000) begin
            mg_memrq = 1'b1;
        end else if (A < 20'h0E000) begin
            text_memrq = 1'b1;
        end else if (A < 20'h0F000) begin
            pal_memrq = 1'b1;
        end else if (A < 20'h10000) begin
            sprite_memrq = 1'b1;
        end else if (A < 20'h20000) begin
            ram_memrq = 1'b1;
''' + text[end:]
# Zero Team has no program/tile bank write handlers at 470/6CC/6CA.
text = text.replace("cbank_memrq = 1'b1;", "cbank_memrq = 1'b0;")
text = text.replace("bankw_memrq = 1'b1;", "bankw_memrq = 1'b0;")
text = text.replace("tbank_memrq = 1'b1;", "tbank_memrq = 1'b0;")
path.write_text('// Zero Team USA address map; original donor decode retained outside target differences.\n' + text, encoding='utf-8')
print('Adapted target RAM/source map and four-player input ports.')
