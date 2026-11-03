// ESD16 SDRAM subsystem: jtframe_sdram64 (donor: TUMBLE rtl/jtframe/sdram, 64-bit bursts, 4 banks) at 1x clk_sys.
//
// Bank / byte layout (byte offsets inside each 8 MB bank; stream order is the MRA order):
//   bank 0 : maincpu 0x000000..0x07FFFF (512 KB), audiocpu 0x080000..0x0BFFFF (256 KB), oki 0x0C0000..0x0FFFFF (256 KB)
//   bank 1 : spr  6 MB  (MRA stream 0x0C0000..0x6BFFFF; three 2 MB plane groups)
//   bank 2 : bgs  4 MB  (MRA stream 0x6C0000..0xABFFFF; oki 0xAC0000..0xAFFFFF)
//   bank 3 : second copy of spr (written with bank 1 during download) for the second sprite engine
// Words are stored exactly as hps_io WIDE delivers them: SDRAM word = {odd byte, even byte} of the MRA stream,
// so the stream must equal the MAME region byte image (the MRA maps are written for that).
// 68000 reads swap the bytes ({even, odd} = {word[7:0], word[15:8]}) in esd16_top.
//
// Readers: 68000 program (16 bit, stalls DTACK on miss), Z80 program (8 bit, WAIT), OKI samples (8 bit) share
// bank 0 through esd16_bankport. The video block ROM channel is served by esd16_vrom (bank 1 / bank 2).
module esd16_sdram (
    input             clk,
    input             clk_cap,        // DQ capture clock (clk_sys frequency, phase-shifted PLL output)
    input             rst,
    output            init,           // SDRAM power-up sequence running
    // HPS download (ioctl_index[7:0]==0 only)
    input             ioctl_download,
    input      [15:0] ioctl_index,
    input             ioctl_wr,
    input      [26:0] ioctl_addr,
    input      [15:0] ioctl_dout,
    output            ioctl_wait,
    output            dl_busy,        // download or post-download flush in progress
    input             rfsh,           // once per video line
    // 68000 program ROM (word address a[18:1])
    input             cpu_en,
    input      [18:1] cpu_addr,
    output     [15:0] cpu_data,
    output            cpu_ok,
    // Z80 program ROM (byte address)
    input      [17:0] zrom_addr,
    output      [7:0] zrom_data,
    output            zrom_ok,
    // OKI sample ROM (byte address)
    input      [17:0] orom_addr,
    output      [7:0] orom_data,
    output            orom_ok,
    // video block ROM channels: tile layers ('bgs', bank 2) and sprites ('spr', bank 1), independent
    input             bgrom_req,
    input      [20:0] bgrom_addr,
    output            bgrom_ready,
    output            bgrom_valid,
    output     [31:0] bgrom_data,
    input             sprom_req,
    input      [20:0] sprom_addr,
    output            sprom_ready,
    output            sprom_valid,
    output     [31:0] sprom_data,
    input             sprom2_req,
    input      [20:0] sprom2_addr,
    output            sprom2_ready,
    output            sprom2_valid,
    output     [31:0] sprom2_data,
    // SDRAM pins
    inout      [15:0] sdram_dq,
    output     [12:0] sdram_a,
    output            sdram_dqml,
    output            sdram_dqmh,
    output     [1:0]  sdram_ba,
    output            sdram_nwe,
    output            sdram_ncas,
    output            sdram_nras,
    output            sdram_ncs,
    output            sdram_cke
);
    // ------------------------------------------------------------------ download -> programming port
    wire        dl_rom = ioctl_download && (ioctl_index[7:0] == 8'd0);
    reg         pend, prog_wr;
    reg  [7:0]  flush;                       // keeps prog_en up after the last word so it can finish
    reg         start_pending, prog_active;
    wire        bp0_active, bp1_active, bp2_active, bp3_active;
    wire        core_ports_idle = !(|bp0_active) && !(|bp1_active) && !(|bp2_active) && !(|bp3_active);
    reg         dup;                     // bank-1 (spr) word still to be copied into bank 3
    wire        prog_en = prog_active;
    assign dl_busy = dl_rom | start_pending | prog_active | (flush != 8'd0);
    assign ioctl_wait = pend | (dl_rom && !prog_active);

    wire [23:0] a = ioctl_addr[23:0];
    wire        in_b0a = (a <  24'h0C0000);
    wire        in_b1  = (a >= 24'h0C0000) && (a < 24'h6C0000);
    wire        in_b2  = (a >= 24'h6C0000) && (a < 24'hAC0000);
    wire [23:0] off    = in_b0a ? a :
                         in_b1  ? a - 24'h0C0000 :
                         in_b2  ? a - 24'h6C0000 :
                                  a - 24'hA00000;           // oki -> bank 0 @ 0x0C0000
    wire [1:0]  bnk    = in_b1 ? 2'd1 : (in_b2 ? 2'd2 : 2'd0);
    reg  [21:0] prog_addr;
    reg  [1:0]  prog_ba;
    reg  [15:0] prog_din;
    wire        prog_ack_raw;
    wire        prog_ack = prog_active && prog_ack_raw;
    always @(posedge clk) begin
        if (rst) begin
            flush <= 8'd0;
            start_pending <= 1'b0;
            prog_active <= 1'b0;
            pend <= 1'b0;
            prog_wr <= 1'b0;
            dup <= 1'b0;
        end else begin
            if (dl_rom) begin
                flush <= 8'd255;
                if (!prog_active) start_pending <= 1'b1;
            end else if (flush != 8'd0 && !pend) begin
                flush <= flush - 8'd1;
            end

            // Block new bankport transactions from the first download cycle,
            // but leave an already accepted physical read live until its last beat.
            if (start_pending && core_ports_idle && !prog_active) begin
                start_pending <= 1'b0;
                prog_active <= 1'b1;
            end

            if (prog_active && !dl_rom && flush == 8'd0 && !pend)
                prog_active <= 1'b0;

            // Capture the first host word even if its pulse coincides with the
            // download edge. Hold its payload until programmer ownership is safe.
            if (dl_rom && ioctl_wr && !pend) begin
                prog_addr <= off[22:1];
                prog_ba   <= bnk;
                prog_din  <= ioctl_dout;
                pend      <= 1'b1;
                dup       <= (bnk == 2'd1);
            end
            if (prog_active && pend && !prog_wr)
                prog_wr <= 1'b1;
            if (prog_ack) begin
                prog_wr <= 1'b0;
                // A sprite word is written twice: bank 1, then the same address in bank 3.
                if (dup) begin
                    dup     <= 1'b0;
                    prog_ba <= 2'd3;
                end else
                    pend    <= 1'b0;
            end
        end
    end

    // ------------------------------------------------------------------ readers on bank 0
    wire        c_req, z_req, o_req;
    wire [15:0] c_blk;
    wire [14:0] z_blk, o_blk;
    wire [63:0] b0_blk;
    wire [2:0]  b0_done;
    // Invalidate cache tags and pause VROM responses as soon as host download
    // starts. esd16_vrom keeps its accepted FIFO entries while inv is high.
    // Registered: the one-clock delay is covered by stop_new (no new bankport launches) and by prog_en ownership
    // waiting for idle ports; it removes the hps_io ioctl_index decode from the VROM cache control cone.
    reg         inv;
    always @(posedge clk) inv <= rst | dl_busy;

    esd16_blkcache #(.BAW(16), .DW(16), .SLOTS(8)) u_cpu (
        .clk(clk), .inv(inv), .en(cpu_en), .a({cpu_addr, 1'b0}), .data(cpu_data), .ok(cpu_ok),
        .req(c_req), .req_blk(c_blk), .done(b0_done[0]), .blk(b0_blk));
    esd16_blkcache #(.BAW(15), .DW(8)) u_z80 (
        .clk(clk), .inv(inv), .en(1'b1), .a(zrom_addr), .data(zrom_data), .ok(zrom_ok),
        .req(z_req), .req_blk(z_blk), .done(b0_done[1]), .blk(b0_blk));
    esd16_blkcache #(.BAW(15), .DW(8)) u_oki (
        .clk(clk), .inv(inv), .en(1'b1), .a(orom_addr), .data(orom_data), .ok(orom_ok),
        .req(o_req), .req_blk(o_blk), .done(b0_done[2]), .blk(b0_blk));

    wire [21:0] c_w = {4'b0000, c_blk, 2'b00};                          // word address, base 0
    wire [21:0] z_w = 22'h040000 + {5'd0, z_blk, 2'b00};               // base 0x080000 bytes
    wire [21:0] o_w = 22'h060000 + {5'd0, o_blk, 2'b00};               // base 0x0C0000 bytes

    wire        b0_rd, b1_rd, b2_rd, b3_rd;
    wire [21:0] b0_addr, b1_addr, b2_addr, b3_addr;
    wire [3:0]  sd_ack, sd_dst;
    wire [15:0] sd_dout;

    esd16_bankport #(.N(3)) u_bp0 (
        .clk(clk), .rst(rst | prog_en), .stop_new(dl_busy), .active(bp0_active),
        .req({o_req, z_req, c_req}), .waddr({o_w, z_w, c_w}),
        .done(b0_done), .blk(b0_blk), .sd_rd(b0_rd), .sd_addr(b0_addr),
        .sd_ack(sd_ack[0]), .sd_dst(sd_dst[0]), .sd_dout(sd_dout));

    // ------------------------------------------------------------------ video ROM channel on banks 1 and 2
    wire        spr_req, bgs_req;
    wire [21:0] spr_w, bgs_w;
    wire [63:0] spr_blk, bgs_blk;
    wire [0:0]  spr_done_v, bgs_done_v;
    // One adapter per engine so tile and sprite bursts proceed concurrently in their own banks.
    esd16_vrom u_vrom_bg (
        .clk(clk), .rst(rst), .inv(inv), .rom_req(bgrom_req), .rom_sel(1'b0), .rom_addr(bgrom_addr),
        .rom_ready(bgrom_ready), .rom_valid(bgrom_valid), .rom_data(bgrom_data),
        .spr_req(), .spr_waddr(), .spr_done(1'b0), .spr_blk(64'd0),
        .bgs_req(bgs_req), .bgs_waddr(bgs_w), .bgs_done(bgs_done_v[0]), .bgs_blk(bgs_blk));
    esd16_vrom u_vrom_sp (
        .clk(clk), .rst(rst), .inv(inv), .rom_req(sprom_req), .rom_sel(1'b1), .rom_addr(sprom_addr),
        .rom_ready(sprom_ready), .rom_valid(sprom_valid), .rom_data(sprom_data),
        .spr_req(spr_req), .spr_waddr(spr_w), .spr_done(spr_done_v[0]), .spr_blk(spr_blk),
        .bgs_req(), .bgs_waddr(), .bgs_done(1'b0), .bgs_blk(64'd0));
    wire        spr2_req;
    wire [21:0] spr2_w;
    wire [63:0] spr2_blk;
    wire [0:0]  spr2_done_v;
    esd16_vrom u_vrom_sp2 (
        .clk(clk), .rst(rst), .inv(inv), .rom_req(sprom2_req), .rom_sel(1'b1), .rom_addr(sprom2_addr),
        .rom_ready(sprom2_ready), .rom_valid(sprom2_valid), .rom_data(sprom2_data),
        .spr_req(spr2_req), .spr_waddr(spr2_w), .spr_done(spr2_done_v[0]), .spr_blk(spr2_blk),
        .bgs_req(), .bgs_waddr(), .bgs_done(1'b0), .bgs_blk(64'd0));
    esd16_bankport #(.N(1), .EARLY_DONE(1)) u_bp3 (
        .clk(clk), .rst(rst | prog_en), .stop_new(dl_busy), .active(bp3_active), .req(spr2_req), .waddr(spr2_w),
        .done(spr2_done_v), .blk(spr2_blk), .sd_rd(b3_rd), .sd_addr(b3_addr),
        .sd_ack(sd_ack[3]), .sd_dst(sd_dst[3]), .sd_dout(sd_dout));
    esd16_bankport #(.N(1), .EARLY_DONE(1)) u_bp1 (
        .clk(clk), .rst(rst | prog_en), .stop_new(dl_busy), .active(bp1_active), .req(spr_req), .waddr(spr_w),
        .done(spr_done_v), .blk(spr_blk), .sd_rd(b1_rd), .sd_addr(b1_addr),
        .sd_ack(sd_ack[1]), .sd_dst(sd_dst[1]), .sd_dout(sd_dout));
    esd16_bankport #(.N(1), .EARLY_DONE(1)) u_bp2 (
        .clk(clk), .rst(rst | prog_en), .stop_new(dl_busy), .active(bp2_active), .req(bgs_req), .waddr(bgs_w),
        .done(bgs_done_v), .blk(bgs_blk), .sd_rd(b2_rd), .sd_addr(b2_addr),
        .sd_ack(sd_ack[2]), .sd_dst(sd_dst[2]), .sd_dout(sd_dout));

    // ------------------------------------------------------------------ controller
    // HF=1: the clock is above 50 MHz so every tRCD/tRP/tRAS is >=2 cycles (15.6 ns clock);
    // SHIFTED=0 expects SDRAM_CLK delayed by roughly half a period (see rtl/pll/pll_0002.v).
    jtframe_sdram64 #(
        .AW(22), .HF(1), .SHIFTED(0), .CAS_LATENCY(3), .CAP_STAGES(2),
        .BA0_LEN(64), .BA1_LEN(64), .BA2_LEN(64), .BA3_LEN(64), .PROG_LEN(64),
        .BA0_WEN(0), .BA1_WEN(0), .BA2_WEN(0), .BA3_WEN(0),
        .MISTER(1), .RFSHCNT(9)
    ) u_sdram (
        .rst(rst), .clk(clk), .clk_cap(clk_cap), .init(init),
        .ba0_addr(b0_addr), .ba1_addr(b1_addr), .ba2_addr(b2_addr), .ba3_addr(b3_addr),
        .rd({b3_rd, b2_rd, b1_rd, b0_rd}), .wr(4'd0),
        .ba0_din(16'd0), .ba0_dsn(2'b11), .ba1_din(16'd0), .ba1_dsn(2'b11),
        .ba2_din(16'd0), .ba2_dsn(2'b11), .ba3_din(16'd0), .ba3_dsn(2'b11),
        .prog_en(prog_en), .prog_addr(prog_addr), .prog_rd(1'b0), .prog_wr(prog_wr),
        .prog_din(prog_din), .prog_dsn(2'b00), .prog_ba(prog_ba),
        .prog_dst(), .prog_dok(), .prog_rdy(), .prog_ack(prog_ack_raw),
        .rfsh(rfsh),
        .ack(sd_ack), .dst(sd_dst), .dok(), .rdy(), .dout(sd_dout),
        .sdram_dq(sdram_dq),
`ifdef VERILATOR
        .sdram_din(),
`endif
        .sdram_a(sdram_a), .sdram_dqml(sdram_dqml), .sdram_dqmh(sdram_dqmh), .sdram_ba(sdram_ba),
        .sdram_nwe(sdram_nwe), .sdram_ncas(sdram_ncas), .sdram_nras(sdram_nras), .sdram_ncs(sdram_ncs),
        .sdram_cke(sdram_cke)
    );
endmodule
