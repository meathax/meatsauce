// SPDX-License-Identifier: GPL-3.0-or-later
// Mad Motor graphics glue around the pinned BAC06/MXC06 donor engines.
// All ports share clk. chip_cen and ce_pix are enables, never clocks.
module madmotor_video (
    input tri0 bandit, palette_ext, sprite_dma,
    input tri0 [15:0] priority_word,
    output wire sprite_dma_busy,
    output logic [23:0] rgb24,
    input logic clk, reset, chip_cen, ce_pix,
    input logic cpu_we,
    input logic [2:0] cpu_ctrl_cs,
    input logic cpu_obj_cs, cpu_pal_cs,
    input logic [12:1] cpu_addr,
    input logic [15:0] cpu_data,
    input logic [1:0] cpu_be,
    output wire [15:0] cpu_pal_data,
    output wire [15:0] cpu_obj_data,
    output wire [12:0] vram_addr [3],
    output wire [2:0] vram_cs,
    input logic [15:0] vram_data [3],
    input logic [2:0] vram_ok,
    output wire [16:0] tile_addr [3],
    output wire [2:0] tile_cs,
    input logic [31:0] tile_data [3],
    input logic [2:0] tile_ok,
    output wire [17:0] sprite_addr,
    output wire sprite_cs,
    input logic [31:0] sprite_data,
    input logic sprite_ok,
    output logic [3:0] red, green, blue,
    output logic hs, vs, hblank, vblank, pixel_valid,
    output logic [8:0] pixel_x, pixel_y,
    output wire [7:0] plane_pixel [4],
    output wire [8:0] raw_x, raw_y
`ifdef VERILATOR
    ,output wire [31:0] debug_video_planes,
    output wire [9:0] debug_video_palette_index
`endif
);
    wire [8:0] vdump, vrender, hdump;
    wire lhbl, lvbl, raw_hs, raw_vs, flip, vload, hinit;
    wire [1:0] dsn = ~cpu_be;
    assign raw_x=hdump;
    assign raw_y=vdump;
    genvar g;
    generate for(g=0;g<3;g=g+1) begin: playfield
        madmotor_bac06 #(.MASTER(g==0),.WIDE(g==2)) bac06 (
            .bandit(bandit), .rst(reset), .clk(clk), .chip_cen(chip_cen), .clk_cpu(clk),
            .pxl2_cen(chip_cen), .pxl_cen(ce_pix),
            .mode_cs(cpu_ctrl_cs[g]), .cpu_dout(cpu_data), .cpu_din(),
            .cpu_addr(cpu_addr), .cpu_rnw(!cpu_we), .cpu_dsn(dsn),
            .flip(flip), .vdump(vdump), .vrender(vrender), .hdump(hdump),
            .LHBL(lhbl), .LVBL(lvbl), .HS(raw_hs), .VS(raw_vs),
            .vload(vload), .hinit(hinit),
            .ram_cs(vram_cs[g]), .ram_addr(vram_addr[g]), .ram_data(vram_data[g]), .ram_ok(vram_ok[g]),
            .rom_cs(tile_cs[g]), .rom_addr(tile_addr[g]), .rom_data(tile_data[g]), .rom_ok(tile_ok[g]),
            .pxl(plane_pixel[g]), .st_addr(8'd0), .st_dout()
        );
    end endgenerate
    wire [9:0] obj_scan_addr;
    wire [15:0] obj_scan_data;
    wire [15:0] sprite_live_data;
    wire [9:0] sprite_copy_read_addr;
    wire [9:0] sprite_copy_write_addr;
    wire [1:0] sprite_copy_bank;
    wire [1:0] sprite_scan_bank;
    wire sprite_live_we = cpu_we & cpu_obj_cs;
    wire sprite_copy_we;
    logic [9:0] sprite_copy_addr;
    logic sprite_copy_busy, sprite_copy_phase, sprite_copy_ready;
    logic sprite_copy_dirty, sprite_list_valid, sprite_scan_bank_q;
    assign sprite_dma_busy=bandit && sprite_copy_busy;
    wire sprite_list_copy_line = bandit ? sprite_dma : ce_pix && (hdump == 0) && (vdump == 9'd255);
    wire sprite_list_publish_line = bandit ? 1'b1 : ce_pix && (hdump == 0) && (vdump == 0);

    // Snapshot the completed CPU list late in VBlank. The previous complete
    // list remains visible while the inactive list is copied. Any concurrent
    // CPU write restarts the copy, so a partially mixed list is never published.
    madmotor_dual_ram16 #(.AW(10)) sprite_ram (
        .clk0(clk), .data0(cpu_data), .addr0(cpu_addr[10:1]),
        .we0({2{sprite_live_we}} & cpu_be), .q0(cpu_obj_data),
        .clk1(clk), .data1(16'd0), .addr1(sprite_copy_read_addr), .we1(2'b00), .q1(sprite_live_data)
    );
    assign sprite_copy_read_addr = sprite_copy_addr;
    assign sprite_copy_write_addr = sprite_copy_addr;
    assign sprite_copy_bank = {2{!sprite_scan_bank_q}};
    assign sprite_scan_bank = {2{sprite_scan_bank_q}};
    assign sprite_copy_we = sprite_copy_busy && sprite_copy_phase && !sprite_live_we;

    wire [15:0] sprite_list_a, sprite_list_b;
    madmotor_dual_ram16 #(.AW(10)) sprite_list_a_ram (
        .clk0(clk), .data0(sprite_live_data), .addr0(sprite_copy_write_addr),
        .we0({2{sprite_copy_we && !sprite_copy_bank[0]}}), .q0(),
        .clk1(clk), .data1(16'd0), .addr1(obj_scan_addr),
        .we1(2'b00), .q1(sprite_list_a)
    );
    madmotor_dual_ram16 #(.AW(10)) sprite_list_b_ram (
        .clk0(clk), .data0(sprite_live_data), .addr0(sprite_copy_write_addr),
        .we0({2{sprite_copy_we && sprite_copy_bank[0]}}), .q0(),
        .clk1(clk), .data1(16'd0), .addr1(obj_scan_addr),
        .we1(2'b00), .q1(sprite_list_b)
    );
    assign obj_scan_data = !sprite_list_valid ? 16'd0 :
                           sprite_scan_bank[0] ? sprite_list_b : sprite_list_a;

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            sprite_copy_addr <= 0;
            sprite_copy_busy <= 0;
            sprite_copy_phase <= 0;
            sprite_copy_ready <= 0;
            sprite_copy_dirty <= 1;
            sprite_list_valid <= 0;
            sprite_scan_bank_q <= 0;
        end else begin
            if (sprite_live_we) begin
                // During a copy the write is included by restarting from word 0.
                sprite_copy_dirty <= sprite_copy_busy ? 0 : 1;
                sprite_copy_ready <= 0;
                if (sprite_copy_busy) begin
                    sprite_copy_addr <= 0;
                    sprite_copy_phase <= 0;
                end
            end else if (sprite_list_copy_line && (sprite_copy_dirty || bandit) &&
                         !sprite_copy_busy && !sprite_copy_ready) begin
                sprite_copy_busy <= 1;
                sprite_copy_addr <= 0;
                sprite_copy_phase <= 0;
                sprite_copy_dirty <= 0;
            end else if (sprite_copy_busy) begin
                if (!sprite_copy_phase) begin
                    sprite_copy_phase <= 1;
                end else begin
                    sprite_copy_phase <= 0;
                    if (&sprite_copy_addr) begin
                        sprite_copy_busy <= 0;
                        sprite_copy_ready <= 1;
                    end else begin
                        sprite_copy_addr <= sprite_copy_addr + 1'b1;
                    end
                end
            end

            if (sprite_list_publish_line && sprite_copy_ready && !sprite_copy_dirty) begin
                sprite_scan_bank_q <= !sprite_scan_bank_q;
                sprite_list_valid <= 1;
                sprite_copy_ready <= 0;
                sprite_copy_dirty <= 0;
            end
        end
    end
    madmotor_mxc06_draw sprites (
        .rst(reset), .clk(clk), .chip_cen(chip_cen), .pxl_cen(ce_pix),
        .HS(raw_hs), .LHBL(lhbl), .LVBL(lvbl), .flip(flip),
        .hdump(hdump), .vrender(vrender), .tbl_addr(obj_scan_addr), .tbl_dout(obj_scan_data),
        .rom_cs(sprite_cs), .rom_addr(sprite_addr), .rom_data(sprite_data), .rom_ok(sprite_ok),
        .pxl(plane_pixel[3])
    );
    wire [15:0] palette_pixel,palette_cpu;
    assign cpu_pal_data=palette_ext?{8'd0,palette_blue_cpu}:palette_cpu;
    // Whole-byte donor RAMs preserve OLD_DATA collisions and the original
    // palette capture edge while allowing Quartus17 to infer physical M10Ks.
    genvar byte_lane;
    generate for(byte_lane=0;byte_lane<2;byte_lane=byte_lane+1) begin: palette
        madmotor_dual_ram_cen #(.DW(8),.AW(10)) bank(
            .clk0(clk),.cen0(1'b1),.addr0(cpu_addr[10:1]),.data0(cpu_data[byte_lane*8+:8]),
            .we0(cpu_we&&cpu_pal_cs&&!palette_ext&&cpu_be[byte_lane]),.q0(palette_cpu[byte_lane*8+:8]),
            .clk1(clk),.cen1(pix_qqq),.addr1(palette_index),.data1(8'd0),.we1(1'b0),
            .q1(palette_pixel[byte_lane*8+:8]));
    end endgenerate
    wire [7:0] palette_blue, palette_blue_cpu;
    madmotor_dual_ram_cen #(.DW(8),.AW(10)) blue_bank(
        .clk0(clk),.cen0(1'b1),.addr0(cpu_addr[10:1]),.data0(cpu_data[7:0]),
        .we0(cpu_we&&cpu_pal_cs&&palette_ext&&cpu_be[0]),.q0(palette_blue_cpu),
        .clk1(clk),.cen1(pix_qqq),.addr1(palette_index),.data1(8'd0),.we1(1'b0),.q1(palette_blue));
    logic [9:0] palette_index;
`ifdef VERILATOR
    assign debug_video_planes={plane_pixel[3],plane_pixel[2],plane_pixel[1],plane_pixel[0]};
    assign debug_video_palette_index=palette_index;
`endif
    always_comb begin
        palette_index={2'b11,plane_pixel[2]};
        if(plane_pixel[1][3:0]!=0) palette_index={2'b10,plane_pixel[1]};
        if(plane_pixel[3][3:0]!=0) palette_index={2'b01,plane_pixel[3]};
        if(plane_pixel[0][3:0]!=0) palette_index={2'b00,plane_pixel[0]};
        if(bandit) begin
            if(priority_word==16'd7) begin
                palette_index={2'b10,plane_pixel[1]};
                if(plane_pixel[3][3:0]!=0) palette_index={2'b01,plane_pixel[3]};
                if(plane_pixel[2][3:0]!=0) palette_index={2'b11,plane_pixel[2]};
                if(plane_pixel[0][3:0]!=0) palette_index={2'b00,plane_pixel[0]};
            end else if(priority_word!=0 && plane_pixel[3][3:0]!=0)
                palette_index={2'b01,plane_pixel[3]};
        end
    end
    // Sprite RAM read -> erase/read retirement -> palette capture takes three
    // fabric edges after the raw pixel edge. Emit RGB and timing together.
    logic pix_q, pix_qq, pix_qqq;
    always_comb begin
        red=0;green=0;blue=0;rgb24=0;
        if(!hblank&&!vblank) begin
            red=palette_pixel[3:0];green=palette_pixel[7:4];blue=palette_pixel[11:8];
            rgb24=bandit ? {palette_pixel[7:0],palette_pixel[15:8],palette_blue} :
                         {red,red,green,green,blue,blue};
        end
    end
    always_ff @(posedge clk) begin
        if(reset) begin
            pix_q<=0; pix_qq<=0; pix_qqq<=0; pixel_valid<=0;
            hs<=0; vs<=0; hblank<=1; vblank<=1;
            pixel_x<=0; pixel_y<=0;
        end else begin
            pix_q<=ce_pix; pix_qq<=pix_q; pix_qqq<=pix_qq; pixel_valid<=pix_qqq;
            if(pix_qqq) begin
                pixel_x<=hdump; pixel_y<=vdump;
                hs<=raw_hs; vs<=raw_vs; hblank<=!lhbl; vblank<=!lvbl;
            end
        end
    end
endmodule
