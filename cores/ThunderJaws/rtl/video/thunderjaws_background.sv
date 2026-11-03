// SPDX-License-Identifier: GPL-3.0-or-later
// Target layer wiring around pinned Batman tile/alpha engines.
// Palette indices only; MO priority/stain and RGB/palette pipeline are separate.
// PF1 X is already fine-coupled by VAD; PF2 gets MAME's separate +4 here.
module thunderjaws_background (
    input wire clk_sys,reset,ce_pixel,
    input wire flip_screen,
    input wire [8:0] hpos,vpos,next_line,
    input wire [8:0] pf1_xscroll,pf1_yscroll,pf2_xscroll,pf2_yscroll,
    input wire [2:0] alpha_bank,
    output wire [14:0] pf1_code_address,pf1_attr_address,pf2_code_address,pf2_attr_address,alpha_address,
    input wire [15:0] pf1_code_data,pf1_attr_data,pf2_code_data,pf2_attr_data,alpha_data,
    output wire pf1_rom_fetch,pf2_rom_fetch,
    output wire [17:0] pf1_rom_address,pf2_rom_address,
    input wire [31:0] pf1_rom_data,pf2_rom_data,
    input wire pf1_rom_valid,pf2_rom_valid,
    output wire pf1_rom_late,pf2_rom_late,
    output wire pf1_vram_fetch,pf2_vram_fetch,alpha_vram_fetch,
    output wire [14:0] alpha_rom_address,
    input wire [15:0] alpha_rom_data,
    output wire [9:0] pf1_pixel,pf2_pixel,
    output wire [8:0] alpha_pixel,
    output wire [12:0] background_pixel,
    output wire [9:0] composed_palette
);
    wire [3:0] p1_pen,p1_color,p2_pen,p2_color;
    wire [1:0] p1_priority,p2_priority,alpha_pen;
    wire [5:0] alpha_color;
    wire alpha_opaque;
    thunderjaws_pf #(.ATTR_HIGH_BYTE(0),.ROM_INVERT(0),.XOFF(0)) pf1(
        .clk(clk_sys),.reset(reset),.flip_screen(flip_screen),.ce_7m(ce_pixel),.px(hpos),.line(vpos),.line_next(next_line),
        .xscroll(pf1_xscroll),.yscroll(pf1_yscroll),.base_code(15'h1000),.base_attr(15'h2000),
        .code_a(pf1_code_address),.attr_a(pf1_attr_address),.code_q(pf1_code_data),.attr_q(pf1_attr_data),
        .rom_fetch(pf1_rom_fetch),.rom_addr(pf1_rom_address),.rom_group(pf1_rom_data),
        .rom_valid(pf1_rom_valid),.rom_late(pf1_rom_late),.pen(p1_pen),.colour(p1_color),.pri(p1_priority));
    thunderjaws_pf #(.ATTR_HIGH_BYTE(1),.ROM_INVERT(0),.XOFF(4)) pf2(
        .clk(clk_sys),.reset(reset),.flip_screen(flip_screen),.ce_7m(ce_pixel),.px(hpos),.line(vpos),.line_next(next_line),
        .xscroll(pf2_xscroll),.yscroll(pf2_yscroll),.base_code(15'h0000),.base_attr(15'h2000),
        .code_a(pf2_code_address),.attr_a(pf2_attr_address),.code_q(pf2_code_data),.attr_q(pf2_attr_data),
        .rom_fetch(pf2_rom_fetch),.rom_addr(pf2_rom_address),.rom_group(pf2_rom_data),
        .rom_valid(pf2_rom_valid),.rom_late(pf2_rom_late),.pen(p2_pen),.colour(p2_color),.pri(p2_priority));
    thunderjaws_alpha alpha(.clk(clk_sys),.reset(reset),.flip_screen(flip_screen),.ce_7m(ce_pixel),
        .px(hpos),.line(vpos),.line_next(next_line),.albk(alpha_bank),.base_alpha(15'h4000),
        .vram_a(alpha_address),.vram_q(alpha_data),.rom_a(alpha_rom_address),.rom_q(alpha_rom_data),
        .apix(alpha_pen),.alc(alpha_color),.albg(alpha_opaque),.vram_fetch(alpha_vram_fetch));
    assign pf1_vram_fetch=pf1_rom_fetch;
    assign pf2_vram_fetch=pf2_rom_fetch;
    assign pf1_pixel={p1_priority,p1_color,p1_pen};
    assign pf2_pixel={p2_priority,p2_color,p2_pen};
    assign alpha_pixel={alpha_opaque,alpha_color,alpha_pen};
    wire select_pf2=|p2_pen;
    wire [9:0] selected_palette=select_pf2 ? {2'b10,p2_color,p2_pen} : {2'b11,p1_color,p1_pen};
    assign background_pixel={select_pf2,select_pf2 ? p2_priority : p1_priority,selected_palette};
    assign composed_palette=(alpha_opaque || |alpha_pen) ? {2'b00,alpha_color,alpha_pen} : selected_palette;
endmodule
