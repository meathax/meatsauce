"""One-time Zero Team video geometry adaptation of the pinned donor engines."""
from pathlib import Path
import re
root=Path(__file__).resolve().parents[1]
path=root/'rtl/Raiden2/Raiden2_video_timing.sv'
s=path.read_text()
if '// Zero Team native raster' in s: raise SystemExit('Already adapted')
s='// Zero Team native raster: 96 MHz / 12, 512 x 282, active 320 x 256.\n'+s
s=s.replace("cediv == 4'd12", "cediv == 4'd11")
values={'H_TOTAL':512,'H_SYNC':38,'H_BP':0,'H_FP':192,'H_VIS_START':0,
        'V_SYNC':3,'V_BP':0,'V_VISIBLE':256,'V_FP':26}
for name,value in values.items():
    s,n=re.subn(rf'(localparam \[9:0\] {name}\s*=)[^;]+;',rf"\g<1> 10'd{value};",s)
    assert n==1,name
s=re.sub(r'wire \[9:0\] V_VIS_START\s*=[^;]+;',"wire [9:0] V_VIS_START = 10'd0;",s)
path.write_text(s)
for name in ['Raiden2_text_renderer','Raiden2_tile_layer','Raiden2_sprite_renderer']:
    p=root/f'rtl/Raiden2/{name}.sv'; s=p.read_text()
    s=s.replace("localparam [8:0] V_VISIBLE = 9'd240", "localparam [8:0] V_VISIBLE = 9'd256")
    s=s.replace("16'd239", "16'd255").replace("16'd238", "16'd254")
    s=s.replace("9'd239", "9'd255").replace("9'd238", "9'd254")
    p.write_text(s)
p=root/'rtl/Raiden2/raiden2_mixer.sv'; s=p.read_text()
s=s.replace('module raiden2_mixer (','module raiden2_mixer #(parameter ZERO_TEAM = 0) (')
s=s.replace('wire blend_now  = blend_tab[pen_q[rd_step_d2]];', 'wire blend_now = !ZERO_TEAM && blend_tab[pen_q[rd_step_d2]];')
s=s.replace("$readmemb(\"raiden2_blend.mem\"", "$readmemb(\"rtl/Raiden2/raiden2_blend.mem\"")
s=s.replace('if (blend_tab[pen_q[rd_step_d2]]) begin', 'if (!ZERO_TEAM && blend_tab[pen_q[rd_step_d2]]) begin')
# Zero Team order is BG,spr0,MG,spr1,FG,spr2,TEXT,spr3, no alpha blending.
old=s[s.index('\t\tpen_q[0] <='):s.index('\t\tde_q  <=')]
new='''        if (ZERO_TEAM) begin
            pen_q[0]<=bg_pen; vld_q[0]<=bg_opaque;
            pen_q[1]<=spr_pen; vld_q[1]<=spr_pri0;
            pen_q[2]<=mg_pen; vld_q[2]<=mg_opaque;
            pen_q[3]<=spr_pen; vld_q[3]<=spr_pri1;
            pen_q[4]<=fg_pen; vld_q[4]<=fg_opaque;
            pen_q[5]<=spr_pen; vld_q[5]<=spr_pri2;
            pen_q[6]<=text_pen; vld_q[6]<=text_opaque;
            pen_q[7]<=spr_pen; vld_q[7]<=spr_pri3;
        end else begin
''' + old + '        end\n'
s=s.replace(old,new)
p.write_text(s)
print('Adapted target raster, 256-line renderers and Zero Team priority mode.')
