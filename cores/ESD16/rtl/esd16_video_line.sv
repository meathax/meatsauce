// ESD16 (SWAT Police) line-based video renderer, synthesizable replacement for esd16_video.sv.
// Target: Cyclone V / Quartus 17.0.0.2, clk_sys 98 MHz, pixel enable = integer counter clk/PXDIV (14).
// Raster HTOTAL x 260 (448 x 260 at 7 MHz: visible 320 x 240 at x 0..319, y 0..239), 15.625 kHz / 60.096 Hz.
// Sprite rules (verified against MAME decospr, swatpolc is_bootleg set): code is NOT masked with ~multi,
// y[11] adds a 'wing' tile at x-16 with code-(multi+1), y[12] flash entries are skipped on odd frames,
// colour = x[11:9] (8 colours), entries drawn 0..255 (last wins), x[15] sprites are hidden where a layer 1
// pixel is still visible, unless an earlier sprite was already drawn there (MAME pri_callback on the
// running priority bitmap).
//   hsync x 344..383 (40 px), vsync lines 248..250 (chosen, no PCB evidence).
//
// Architecture: while line V is displayed, line V+1 is built by two engines running in parallel
// (esd16_vl_builder), each with its own ROM channel and SDRAM bank:
//   tile engine   : layer 0 (21 tiles, opaque) -> layer 1 (21 tiles, pen 0 transparent) into the BG buffer
//                   {l1, index}; layer 0 covers every visible pixel.
//   sprite lanes  : two engines scan the 256 entries and take alternate sprite tile rows. Each lane writes its
//                   own buffer {valid, order, index} (order = {entry, wing}, later wins) plus a 'np' bit set by
//                   any non-priority sprite pixel. The second lane reads a copy of the sprite ROM in SDRAM
//                   bank 3, so both lanes fetch concurrently. Sprite buffers are cleared as they are shown.
// Output merge reproduces the sequential draw order exactly:
//   last sprite = lane with the larger order tag; shown  <=>  any valid && (!l1 || npA || npB)
// The palette lookup happens at the output.
//
// Layer-size bit 0/1 selects 16x16 (set) or 8x8 (clear) independently for each tile layer.
//
// ROM channels (bg_rom_* for 'bgs', sp_rom_* for 'spr'): pipelined request / valid, in-order data, variable
//   latency. A request is presented with rom_req/rom_addr (registered) and accepted on the edge where
//   rom_req && rom_ready. Read data comes back in request order, one rom_valid clock per request, at least
//   one clock after its accept edge. Up to 6 requests are outstanding at once (a job).
//   rom_addr is a 32-bit-WORD address, data little endian (rom_data[7:0] = byte 4*rom_addr).
//   'bgs' 4 MB (16384 tiles x 256 byte); 'spr' 3 MB flat byte image as in sim/video/spr.hex
//   (plane bytes at +0x000000, +0x100000, +0x200000).
// RAM ports are BRAM style: data valid for sampling two clock edges after the address is presented
// (address registered here, memory registers once more).
module esd16_video_line #(
    parameter integer PXDIV  = 14,     // clk_sys cycles per pixel (integer, even, >= 4)
    parameter integer HTOTAL = 448     // pixels per line including blanking
) (
    input              clk,
    input              rst,
    input              cbank0,            // layer 0 colour bank (palette +256)
    input              frame_odd,         // MAME frame number parity (flash sprites hidden on odd frames)
    input        [1:0] layer_16x16,       // ESD16 layersize bits 0/1
    input              flip_screen,       // MAME swatpolc global flip, latched at line start
    input       [10:0] scroll0x,          // effective scroll (raw+94 / raw+96 etc.), mod 1024
    input       [10:0] scroll0y,
    input       [10:0] scroll1x,
    input       [10:0] scroll1y,

    output      [12:0] vram0_addr,        // 8x8: {tile_y[5:0],tile_x[6:0]}; 16x16: {1'b0,tile_y[5:0],tile_x[5:0]}
    input       [15:0] vram0_q,
    output      [12:0] vram1_addr,
    input       [15:0] vram1_q,
    output       [9:0] sram_addr,         // {sprite[7:0], word[1:0]}  (sprite lane 0)
    input       [15:0] sram_q,
    output       [9:0] sram2_addr,        // second read port of the same sprite RAM (sprite lane 1)
    input       [15:0] sram2_q,
    output reg  [10:0] pal_addr,
    input       [15:0] pal_q,             // xRGB_555

    output             bg_rom_req,
    output      [20:0] bg_rom_addr,
    input              bg_rom_ready,
    input              bg_rom_valid,
    input       [31:0] bg_rom_data,
    output             sp_rom_req,
    output      [20:0] sp_rom_addr,
    input              sp_rom_ready,
    input              sp_rom_valid,
    input       [31:0] sp_rom_data,
    output             sp2_rom_req,       // sprite lane 1, 'spr' copy in SDRAM bank 3
    output      [20:0] sp2_rom_addr,
    input              sp2_rom_ready,
    input              sp2_rom_valid,
    input       [31:0] sp2_rom_data,

    output reg   [7:0] r, g, b,
    output reg         ce_pix,
    output reg         hsync, vsync, hblank, vblank,

    output reg         line_overrun,      // sticky: a line build did not finish in one line time
    output reg  [13:0] build_clks_max     // longest line build (slower engine) in clk_sys cycles
);

    localparam [8:0] HLAST = 9'(HTOTAL - 1);  // last x
    localparam [8:0] VLAST = 9'd259;

    // ------------------------------------------------------------------ raster
    reg [4:0] px_div;
    reg [8:0] hcnt, vcnt;
    wire      tick = (px_div == 5'(PXDIV - 1));
    reg       line_start;

    always @(posedge clk) begin
        line_start <= 1'b0;
        if (rst) begin
            px_div <= 5'd0; hcnt <= 9'd0; vcnt <= VLAST; line_start <= 1'b1;  // build line 0 first
        end else begin
            px_div <= tick ? 5'd0 : px_div + 5'd1;
            if (tick) begin
                if (hcnt == HLAST) begin
                    hcnt <= 9'd0;
                    vcnt <= (vcnt == VLAST) ? 9'd0 : vcnt + 9'd1;
                    line_start <= 1'b1;
                end else
                    hcnt <= hcnt + 9'd1;
            end
        end
    end

    // ------------------------------------------------------------------ build control
    wire        build_this = (vcnt < 9'd239) || (vcnt == VLAST);   // line vcnt+1 is a visible line
    wire        start = line_start && build_this && !rst;
    wire  [7:0] start_line = (vcnt == VLAST) ? 8'd0 : vcnt[7:0] + 8'd1;
    wire        start_buf  = (vcnt == VLAST) ? 1'b0 : ~vcnt[0];
    wire        bg_busy, spa_busy, spb_busy;
    wire        sp_busy = spa_busy || spb_busy;
    wire [13:0] bg_clks, spa_clks, spb_clks;
    wire [13:0] sp_clks = (spa_clks > spb_clks) ? spa_clks : spb_clks;
    reg         bg_busy_d, sp_busy_d;

    always @(posedge clk) begin
        bg_busy_d <= bg_busy;
        sp_busy_d <= sp_busy;
        if (rst) begin
            line_overrun <= 1'b0; build_clks_max <= 14'd0;
        end else begin
            if (line_start && (bg_busy || sp_busy)) line_overrun <= 1'b1;
            if (bg_busy_d && !bg_busy && bg_clks > build_clks_max) build_clks_max <= bg_clks;
            if (sp_busy_d && !sp_busy && sp_clks > build_clks_max) build_clks_max <= sp_clks;
        end
    end

    wire        bg_we, bg_wbuf, bg_wl1;
    wire  [8:0] bg_waddr;
    wire [10:0] bg_wdata;
    wire  [1:0] sp_we, sp_wbuf, sp_wpri;
    wire  [8:0] sp_waddr [0:1];
    wire [10:0] sp_wdata [0:1];
    wire  [8:0] sp_word  [0:1];

    esd16_vl_builder #(.SPR(0)) u_bg (
        .clk(clk), .rst(rst), .start(start), .start_line(start_line), .start_buf(start_buf),
        .busy(bg_busy), .busy_clks(bg_clks),
        .cbank0(cbank0), .frame_odd(frame_odd), .layer_16x16(layer_16x16), .flip_screen(flip_screen),
        .scroll0x(scroll0x), .scroll0y(scroll0y), .scroll1x(scroll1x), .scroll1y(scroll1y),
        .vram0_addr(vram0_addr), .vram0_q(vram0_q), .vram1_addr(vram1_addr), .vram1_q(vram1_q),
        .sram_addr(), .sram_q(16'd0),
        .rom_req(bg_rom_req), .rom_addr(bg_rom_addr), .rom_ready(bg_rom_ready),
        .rom_valid(bg_rom_valid), .rom_data(bg_rom_data),
        .wr_en(bg_we), .wr_buf(bg_wbuf), .wr_addr(bg_waddr), .wr_data(bg_wdata), .wr_flag(bg_wl1), .wr_order());

    esd16_vl_builder #(.SPR(1), .NLANES(2), .LANE(0)) u_spa (
        .clk(clk), .rst(rst), .start(start), .start_line(start_line), .start_buf(start_buf),
        .busy(spa_busy), .busy_clks(spa_clks),
        .cbank0(1'b0), .frame_odd(frame_odd), .layer_16x16(2'b11), .flip_screen(flip_screen),
        .scroll0x(11'd0), .scroll0y(11'd0), .scroll1x(11'd0), .scroll1y(11'd0),
        .vram0_addr(), .vram0_q(16'd0), .vram1_addr(), .vram1_q(16'd0),
        .sram_addr(sram_addr), .sram_q(sram_q),
        .rom_req(sp_rom_req), .rom_addr(sp_rom_addr), .rom_ready(sp_rom_ready),
        .rom_valid(sp_rom_valid), .rom_data(sp_rom_data),
        .wr_en(sp_we[0]), .wr_buf(sp_wbuf[0]), .wr_addr(sp_waddr[0]), .wr_data(sp_wdata[0]), .wr_flag(sp_wpri[0]),
        .wr_order(sp_word[0]));

    esd16_vl_builder #(.SPR(1), .NLANES(2), .LANE(1)) u_spb (
        .clk(clk), .rst(rst), .start(start), .start_line(start_line), .start_buf(start_buf),
        .busy(spb_busy), .busy_clks(spb_clks),
        .cbank0(1'b0), .frame_odd(frame_odd), .layer_16x16(2'b11), .flip_screen(flip_screen),
        .scroll0x(11'd0), .scroll0y(11'd0), .scroll1x(11'd0), .scroll1y(11'd0),
        .vram0_addr(), .vram0_q(16'd0), .vram1_addr(), .vram1_q(16'd0),
        .sram_addr(sram2_addr), .sram_q(sram2_q),
        .rom_req(sp2_rom_req), .rom_addr(sp2_rom_addr), .rom_ready(sp2_rom_ready),
        .rom_valid(sp2_rom_valid), .rom_data(sp2_rom_data),
        .wr_en(sp_we[1]), .wr_buf(sp_wbuf[1]), .wr_addr(sp_waddr[1]), .wr_data(sp_wdata[1]), .wr_flag(sp_wpri[1]),
        .wr_order(sp_word[1]));

    // ------------------------------------------------------------------ line buffers
    // Display buffer for line vcnt is vcnt[0]; the engines write the other one.
    wire        dbuf = vcnt[0];
    // Sprite pixel consumed: clear it on the tick that ends its pixel period (its reads are already done).
    wire        clr  = tick && (hcnt < 9'd320);
    reg  [11:0] bgb0 [0:511];
    reg  [11:0] bgb1 [0:511];
    reg         rd_sel_d;
    reg  [11:0] bg_q0, bg_q1;

    always @(posedge clk) begin
        if (bg_we && !bg_wbuf) bgb0[bg_waddr] <= {bg_wl1, bg_wdata};
        bg_q0 <= bgb0[hcnt];
    end
    always @(posedge clk) begin
        if (bg_we && bg_wbuf) bgb1[bg_waddr] <= {bg_wl1, bg_wdata};
        bg_q1 <= bgb1[hcnt];
    end

    // Sprite lane buffers: {valid, order[8:0], index[10:0]} and the non-priority bit, per lane and buffer.
    // Engine writes take the port; on an overrun into the displayed buffer the clear is skipped.
    // Sprite buffers must start empty (they are cleared only as they are displayed); this is the
    // M10K power-up content in Quartus and keeps simulation free of X on the first frame.
    wire [20:0] sp_q  [0:1];
    wire        np_q  [0:1];
    genvar gl;
    generate
        for (gl = 0; gl < 2; gl = gl + 1) begin : g_lane
            reg  [20:0] spb0 [0:511];
            reg  [20:0] spb1 [0:511];
            reg         npb0 [0:511];
            reg         npb1 [0:511];
            reg  [20:0] q0, q1;
            reg         n0, n1;
            integer ii;
            initial for (ii = 0; ii < 512; ii = ii + 1) begin
                spb0[ii] = 21'd0; spb1[ii] = 21'd0; npb0[ii] = 1'b0; npb1[ii] = 1'b0;
            end
            wire w0 = sp_we[gl] && !sp_wbuf[gl];
            wire w1 = sp_we[gl] &&  sp_wbuf[gl];
            wire c0 = clr && !dbuf && !w0;
            wire c1 = clr &&  dbuf && !w1;
            // One write port per buffer: the engine write, or the clear of the pixel just shown.
            wire [20:0] wd   = {1'b1, sp_word[gl], sp_wdata[gl]};
            wire  [8:0] wa0  = w0 ? sp_waddr[gl] : hcnt;
            wire  [8:0] wa1  = w1 ? sp_waddr[gl] : hcnt;
            wire        we0  = w0 || c0;
            wire        we1  = w1 || c1;
            wire [20:0] wd0  = w0 ? wd : 21'd0;
            wire [20:0] wd1  = w1 ? wd : 21'd0;
            wire        nwe0 = (w0 && !sp_wpri[gl]) || c0;   // set by a non-priority pixel, cleared when shown
            wire        nwe1 = (w1 && !sp_wpri[gl]) || c1;
            always @(posedge clk) begin
                if (we0) spb0[wa0] <= wd0;
                q0 <= spb0[hcnt];
            end
            always @(posedge clk) begin
                if (we1) spb1[wa1] <= wd1;
                q1 <= spb1[hcnt];
            end
            always @(posedge clk) begin
                if (nwe0) npb0[wa0] <= w0;
                n0 <= npb0[hcnt];
            end
            always @(posedge clk) begin
                if (nwe1) npb1[wa1] <= w1;
                n1 <= npb1[hcnt];
            end
            assign sp_q[gl] = rd_sel_d ? q1 : q0;
            assign np_q[gl] = rd_sel_d ? n1 : n0;
        end
    endgenerate

    // ------------------------------------------------------------------ output pipeline
    // Pixel hcnt is read, merged and looked up in the palette during the PXDIV clocks before the tick
    // that latches it (read 1, merge 1, palette 2 clocks).
    reg [23:0] rgb_c;
    function automatic [7:0] x5to8(input [4:0] v);
        x5to8 = {v, v[4:2]};
    endfunction
    wire [11:0] bgq = rd_sel_d ? bg_q1 : bg_q0;
    wire        va = sp_q[0][20], vb = sp_q[1][20];
    wire        use_b = vb && (!va || (sp_q[1][19:11] > sp_q[0][19:11]));
    wire [10:0] spi = use_b ? sp_q[1][10:0] : sp_q[0][10:0];
    wire        sp_show = (va || vb) && (!bgq[11] || np_q[0] || np_q[1]);
    always @(posedge clk) begin
        rd_sel_d <= dbuf;
        pal_addr <= sp_show ? spi : bgq[10:0];
        rgb_c    <= {x5to8(pal_q[14:10]), x5to8(pal_q[9:5]), x5to8(pal_q[4:0])};
        ce_pix   <= 1'b0;
        if (tick) begin
            ce_pix <= 1'b1;
            hblank <= (hcnt >= 9'd320);
            vblank <= (vcnt >= 9'd240);
            hsync  <= (hcnt >= 9'd344) && (hcnt < 9'd384);
            vsync  <= (vcnt >= 9'd248) && (vcnt < 9'd251);
            if (hcnt >= 9'd320 || vcnt >= 9'd240) {r, g, b} <= 24'd0;
            else                                  {r, g, b} <= rgb_c;
        end
    end

endmodule
