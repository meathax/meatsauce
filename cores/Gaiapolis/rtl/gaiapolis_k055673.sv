// SPDX-License-Identifier: GPL-3.0-or-later
// Gaiapolis K055673 boundary, adapted from Violent Storm/JTCORES.
// BOTH titles select MAME RNG4. K55673 controls descriptor DMA/sorting;
// the donor drawer already extracts four planes. ROM is raw little-endian32.
// pixel={local_palette6,pen4}; OR the mixer palette base with local_palette.
// prio={0,0,raw_color[7:5]} is the game's (raw_color&0xe0) priority mask.
module gaiapolis_k055673 #(
    // Native CCU active origins, independent of the MAME bitmap crop.
    // Focused CCU reset-image measurement gives post-edge106/271.
    // HFIX samples the preceding hpos at that edge, hence HCOUNTER_PHASE=-1.
    // Final RGB pipeline alignment still requires a full-frame comparison.
    parameter integer HACTIVE_FIRST=106, VACTIVE_FIRST=271,
    parameter integer HCOUNTER_PHASE=-1,
    parameter integer BITMAP_LEFT=40, BITMAP_TOP=16,
    parameter integer SPRITE_DX=-61, SPRITE_DY=-22
)(
    input wire monster,
    output logic [1:0] sprite_mix,
    output wire cpu_rom_ready,
    output wire [18:0] sprite5_addr,
    output wire sprite5_cs,
    input wire [31:0] sprite5_data,
    input wire sprite5_ok,
    input rst,clk,pxl_cen,pxl2_cen,
    input [8:0] hpos,vpos,
    input lhbl,lvbl,hs,
    // Compact chip word address: board scatter and non-chip RAM stay outside.
    input obj_cs,obj_we,
    input [12:1] obj_addr,
    input [15:0] obj_din,
    input [1:0] obj_dsn,
    output [15:0] obj_dout,
    // OBJSET1 pairs; reg_addr is their original byte address.
    input reg_cs,reg_we,
    input [3:0] reg_addr,
    input [15:0] reg_din,
    input [1:0] reg_dsn,
    // Physical OBJSET2 words and their independent byte write masks.
    input objset2_cs,objset2_we,
    input [2:0] objset2_addr,
    input [15:0] objset2_din,
    input [1:0] objset2_dsn,
    output [22:2] rom_addr,
    output rom_cs,
    input [31:0] rom_data,
    input rom_ok,
    input objcha_n,
    input [2:0] rom_read_offset,
    output [1:0] shadow,
    output [2:0] shadow_prio,
    output [4:0] prio,
    output [9:0] pixel,
    input [7:0] shadow_priority1,shadow_priority2,shadow_priority3,
    output [7:0] shadow_priority_full,
    output [31:0] solid_order,shadow_order,
    output [7:0] shadow_ops_valid,
    output [15:0] shadow_ops_mode,
    output [255:0] shadow_ops_order,
    output shadow_ops_overflow,
    output line_overrun,
    output dma_irq_enabled,dma_busy,ln_done
);
    localparam [9:0] HOFFSET=10'(SPRITE_DX-BITMAP_LEFT+HACTIVE_FIRST+33+HCOUNTER_PHASE);
    // The legal donor scan raster duplicates vlatch[8], adding512.
    localparam [9:0] VOFFSET=10'(-SPRITE_DY-(VACTIVE_FIRST-BITMAP_TOP)-512);
    logic [7:0] objset1_regs[0:7];
    logic [15:0] objset2_regs[0:7];
    integer reg_i;
    always_ff @(posedge clk) begin
        if(rst) begin
            for(reg_i=0;reg_i<8;reg_i=reg_i+1) begin
                objset1_regs[reg_i]<=0;
                objset2_regs[reg_i]<=0;
            end
        end else begin
            if(reg_cs && reg_we) begin
                if(!reg_dsn[1]) objset1_regs[{reg_addr[2:1],1'b0}]<=reg_din[15:8];
                if(!reg_dsn[0]) objset1_regs[{reg_addr[2:1],1'b1}]<=reg_din[7:0];
            end
            if(objset2_cs && objset2_we) begin
                if(!objset2_dsn[1]) objset2_regs[objset2_addr][15:8]<=objset2_din[15:8];
                if(!objset2_dsn[0]) objset2_regs[objset2_addr][7:0]<=objset2_din[7:0];
            end
        end
    end
    wire [8:0] hdump=hpos+9'd32;
    wire [22:2] donor_rom_addr;
    wire donor_rom_cs;
    wire [15:0] donor_cpu_dout;
    // MAME k055673_rom_word_r: align(R6<<16|R7<<8|R4,4),
    // plus2 at offsets0..3, then offset&3. Preserve all22 physical word bits.
    // R6 bits7:6 select beyond the8MiB region: software-valid addresses use0..63.
    wire [23:0] read_raw={objset1_regs[6],objset1_regs[7],objset1_regs[4]};
    wire [19:0] read_base=read_raw[21:2];
    // Combine the small offset before the address carry chain. The two
    // original22bit additions otherwise cascade into the SDRAM word selector.
    wire [2:0] read_low=monster ?
        {1'b0,read_raw[1:0]}+{1'b0,!rom_read_offset[2],rom_read_offset[0]} :
        {1'b0,rom_read_offset[1:0]}+{1'b0,!rom_read_offset[2],1'b0};
    wire [19:0] read_high=read_base+{19'd0,read_low[2]};
    wire [21:0] read_word={read_high,read_low[1:0]};
    wire cpu_plane5=monster && !objcha_n && rom_read_offset[1];
    wire [20:0] plane5_byte=read_raw[21:1]+(rom_read_offset[2] ? 21'd0 : 21'd1);
    wire [18:0] render_sprite5_addr;
    wire render_sprite5_cs;
    assign sprite5_addr=cpu_plane5 ? plane5_byte[20:2] : render_sprite5_addr;
    assign sprite5_cs=cpu_plane5 || (objcha_n && render_sprite5_cs);
    assign cpu_rom_ready=cpu_plane5 ? sprite5_ok : rom_ok;
    assign rom_addr=!objcha_n ? read_word[21:1] : donor_rom_addr;
    assign rom_cs=(!objcha_n && !cpu_plane5) || (objcha_n && donor_rom_cs);
    assign obj_dout=cpu_plane5 ? {8'd0,sprite5_data[{plane5_byte[1:0],3'b0} +:8]} : !objcha_n ?
        (read_word[0] ? rom_data[31:16] : rom_data[15:0]) : donor_cpu_dout;
    wire [21:0] unused_rmrd;
    wire [7:0] unused_dump_ram,unused_dump_reg;
    wire unused_wrapper_io=&{1'b0,lhbl,read_raw[23:22],read_raw[1:0]};
    gaiapolis_obj #(
        .RAMW(12),.PACKED(0),.SHADOW(1),.K55673(1),
        .K55673_DESC_SORT(1),.EDGE_TRIGGER(0),.HOFFSET(HOFFSET),
        .HACTIVE_FIRST(HACTIVE_FIRST),.VACTIVE_FIRST(VACTIVE_FIRST),
        .HCOUNTER_PHASE(HCOUNTER_PHASE),.BITMAP_LEFT(BITMAP_LEFT),.BITMAP_TOP(BITMAP_TOP),
        .SPRITE_DX(SPRITE_DX),.SPRITE_DY(SPRITE_DY)
    ) u_obj(
        .monster(monster),
        .sprite_mix(sprite_mix),
        .sprite5_addr(render_sprite5_addr),.sprite5_cs(render_sprite5_cs),
        .sprite5_data(sprite5_data),.sprite5_ok(sprite5_ok && objcha_n),
        .rst(rst),.clk(clk),.ln_done(ln_done),.dma_enabled_o(dma_irq_enabled),
        .pxl_cen(pxl_cen),.pxl2_cen(pxl2_cen),.simson(1'b0),
        .hdump(hdump),.vdump(vpos),.voffset(VOFFSET),
        .screen_hflip(objset1_regs[5][0]),.hs(hs),.lvbl(lvbl),
        .objset1({objset1_regs[7],objset1_regs[6],objset1_regs[5],objset1_regs[4],
                  objset1_regs[3],objset1_regs[2],objset1_regs[1],objset1_regs[0]}),
        .objset2({objset2_regs[7],objset2_regs[6],objset2_regs[5],objset2_regs[4],
                  objset2_regs[3],objset2_regs[2],objset2_regs[1],objset2_regs[0]}),
        .shadow_priorities({shadow_priority3,shadow_priority2,shadow_priority1}),
        .shadow_priority_full(shadow_priority_full),
        .solid_order(solid_order),.shadow_order(shadow_order),
        .shadow_ops_valid(shadow_ops_valid),.shadow_ops_mode(shadow_ops_mode),
        .shadow_ops_order(shadow_ops_order),.shadow_ops_overflow(shadow_ops_overflow),.line_overrun(line_overrun),
        .ram_cs(obj_cs),.reg_cs(reg_cs),.mmr_we(reg_we),.mmr_addr(reg_addr),
        .mmr_din(reg_din),.mmr_dsn(reg_dsn),.ram_din(obj_din),
        .ram_we({2{obj_we}} & ~obj_dsn),.ram_addr(obj_addr),
        .cpu_din(donor_cpu_dout),.dma_bsy(dma_busy),
        .rom_addr(donor_rom_addr),.rom_data(rom_data),.rom_cs(donor_rom_cs),
        // A CPU readback response must not satisfy a pending render request.
        .rom_ok(rom_ok && objcha_n),.rmrd_addr_o(unused_rmrd),.objcha_n(objcha_n),
        .shd(shadow),.shd_prio(shadow_prio),.prio(prio),.pxl(pixel),
        .gfx_en(4'hf),.ioctl_ram(1'b0),.ioctl_addr(14'd0),
        .dump_ram(unused_dump_ram),.dump_reg(unused_dump_reg),.debug_bus(8'd0)
    );
endmodule
