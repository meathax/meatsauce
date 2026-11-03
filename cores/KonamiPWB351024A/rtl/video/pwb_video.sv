// SPDX-License-Identifier: GPL-3.0-or-later
module pwb_video (
    input logic clk, reset, pxl_cen, pxl2_cen, video_enable,
    input logic game_mainevt, cpu_cs, cpu_we, pal_we, cpu_rnw,
    input logic [13:0] cpu_addr,
    input logic [8:0] pal_addr,
    input logic [7:0] pal_data,
    input logic [7:0] cpu_dout,
    output wire [7:0] cpu_din, pal_dout,
    input logic rmrd,
    output wire cpu_ok, irq_n,
    output wire [16:0] f_addr, a_addr, b_addr,
    output wire [17:0] o_addr,
    output wire f_cs,a_cs,b_cs,o_cs,
    input logic [31:0] f_data,a_data,b_data,o_data,
    input logic a_ok,o_ok,
    output wire [7:0] red,green,blue,
    output wire ce_pix,hs,vs,lhbl,lvbl,
    output wire [8:0] hdump,vdump,
    output wire [8:0] beam_h,beam_v
);
    wire [8:0] h,v,vr,vr1;
    wire raw_hs,raw_vs,raw_hb,raw_vb,flip;
    wire [12:0] pf,pa,pb,obj_code;
    wire [7:0] cf,ca,cb,fp,obj_pal;
    wire [11:0] ap,bp,op;
    wire fb,ab,bb,ob,shadow;
    wire [18:0] obj_rom_addr;
    wire [7:0] tile_dout,obj_dout;
    wire tile_ok,obj_romrd;
    wire ctrl_sel=(cpu_addr>=14'h3800 && cpu_addr<14'h3808);
    wire obj_sel=ctrl_sel || cpu_addr>=14'h3c00;
    wire tile_cs=cpu_cs && (!obj_sel || (rmrd && cpu_rnw));
    wire obj_cs=cpu_cs && obj_sel && !(rmrd && cpu_rnw);
    wire gfx_we=cpu_we;
    wire [13:0] gfx_addr=cpu_addr;
    wire [10:0] obj_addr=ctrl_sel ? {8'd0,cpu_addr[2:0]} : {1'b1,cpu_addr[9:0]};
    assign cpu_din=(rmrd || !obj_sel)?tile_dout:obj_dout;
    assign cpu_ok=(rmrd && cpu_cs && cpu_rnw)?tile_ok:((obj_cs && obj_romrd && cpu_rnw)?o_ok:1'b1);
    function automatic [16:0] tile_code(input [12:0] pre,input [7:0] colour);
        tile_code={1'b0,game_mainevt?1'b0:colour[5],colour[4:2],colour[0],pre[10:0]};
    endfunction
    function automatic [7:0] colour_gate(input [7:0] colour);
        colour_gate={colour[5],1'b0,colour[7:6],3'b000,game_mainevt & colour[1]};
    endfunction
    wire [8:0] nh=(h>=105)?h-9'd105:h+9'd279;
    wire [8:0] nv=(v>=256)?v-9'd256:v+9'd8;
    assign beam_h=nh;assign beam_v=nv;
    wire crop_h=game_mainevt ? (nh>=16 && nh<304) : (nh>=24 && nh<312);
    wire crop_v=nv>=16 && nv<240;
    assign f_addr=tile_code(pf,cf); assign a_addr=tile_code(pa,ca); assign b_addr=tile_code(pb,cb);
    assign o_addr=obj_rom_addr[17:0];
    pwb_scroll u_scroll (
        .game_mainevt(game_mainevt),
        .rst(reset),.clk(clk),.pxl_cen(pxl_cen),.pxl2_cen(pxl2_cen),
        .lhbl(raw_hb),.lvbl(raw_vb),.hs(raw_hs),.vs(raw_vs),
        .hdump(h),.vdump(v),.vrender(vr),.vrender1(vr1),
        .gfx_cs(tile_cs),.cpu_we(gfx_we),.cpu_rnw(cpu_rnw),.cpu_addr(gfx_addr),.cpu_dout(cpu_dout),
        .tile_dout(tile_dout),.cpu_rom_dtack(tile_ok),.rst8(),.rmrd(rmrd),
        .irq_n(irq_n),.firq_n(),.nmi_n(),.flip(flip),.e(),.q(),
        .lyra_addr(pa),.lyrb_addr(pb),.lyrf_addr(pf),
        .lyrf_cs(f_cs),.lyra_cs(a_cs),.lyrb_cs(b_cs),
        .lyrf_data(f_data),.lyra_data(a_data),.lyrb_data(b_data),
        .lyrf_col(cf),.lyra_col(ca),.lyrb_col(cb),.lyrf_extra(),.lyra_extra(),.lyrb_extra(),
        .lyrf_cg(colour_gate(cf)),.lyra_cg(colour_gate(ca)),.lyrb_cg(colour_gate(cb)),
        .lyra_ok(a_ok),.lyrf_blnk_n(fb),.lyra_blnk_n(ab),.lyrb_blnk_n(bb),
        .lyrf_pxl(fp),.lyra_pxl(ap),.lyrb_pxl(bp),
        .ioctl_addr(15'd0),.ioctl_ram(1'b0),.ioctl_din(),.mmr_dump(),
        .gfx_en(4'hf),.debug_bus(8'd0),.st_dout());
    pwb_sprite_obj #(.DMA_CEN(1)) u_obj (
        .rst(reset),.clk(clk),.pxl_cen(pxl_cen),
        .cs(obj_cs),.cpu_we(gfx_we),.cpu_dout(cpu_dout),.cpu_addr(obj_addr),.cpu_din(obj_dout),
        .rom_addr(obj_rom_addr),.rom_data(o_data),.rom_cs(o_cs),.rom_ok(o_ok),.romrd(obj_romrd),
        // Object line buffers consume the line generated one scanline ahead,
        // as in the pinned jtaliens_video donor, not the displayed scanline.
        .hdump(h),.vdump(vr),.hs(raw_hs),.vs(raw_vs),.lvbl(raw_vb),.lhbl(raw_hb),.irq_n(),.nmi_n(),
        // Main Event does not use shadows; Devastators PROM behavior remains unqualified.
        .code(obj_code),.code_eff({1'b0,obj_code}),.pal(obj_pal),.pal_eff(game_mainevt ? {1'b0,obj_pal[6:0]} : obj_pal),
        .pxl(op),.shadow(shadow),.blank_n(ob),.ioctl_addr(11'd0),.ioctl_ram(1'b0),
        .ioctl_din(),.dump_reg(),.gfx_en(4'hf),.debug_bus(8'd0),.st_dout());
    pwb_colmix u_mix (
        .clk(clk),.reset(reset),.pxl_cen(pxl_cen),.video_enable(video_enable),.game_mainevt(game_mainevt),
        .lhbl(crop_h),.lvbl(crop_v),.hs(raw_hs),.vs(raw_vs),.hdump(nh),.vdump(nv),
        .cpu_we(pal_we),.cpu_addr(pal_addr),.cpu_dout(pal_data),.cpu_din(pal_dout),
        // MAME/PCB layout planes 0..3 have weights 8,4,2,1. The donor
        // unpacker assigns little-endian byte planes weights 1,2,4,8.
        .f_pxl(fp),.a_pxl(ap),.b_pxl(bp),.o_pxl({op[11:4],op[0],op[1],op[2],op[3]}),.f_blank_n(fb),.b_blank_n(bb),.o_blank_n(ob),.shadow(shadow),
        .red(red),.green(green),.blue(blue),.out_cen(ce_pix),.out_hs(hs),.out_vs(vs),
        .out_lhbl(lhbl),.out_lvbl(lvbl),.out_hdump(hdump),.out_vdump(vdump),.palette_index());
endmodule
