//------------------------------------------------------------------------------
// ND-1 machine + SDRAM image for MiSTer: everything below the MiSTer framework.
// Also the Verilator top of sim/tb_nd1_top.cpp (ioctl download, SDRAM model).
//
//   ncv1_mem  (rtl/mem, donor target/pocket) : ROM image in SDRAM, 4 core ports
//   ncv1_core (rtl/nd1, donor rtl)           : the machine
//
// Reset: the machine is held while the PLL is unlocked, SDRAM initialises, an
// ioctl transfer is active or the loader still has bytes queued (registered
// twice, as the donor does).
// Inputs: MAME namcond1 ports, active low (P1_P2: R L D U B1 B2 B3 START per
// player; DSW: 8 freeze, 9 test, 12 coin1, 13 coin2, 14 service, 15 service1).
//------------------------------------------------------------------------------
`default_nettype none

module nd1_top #(
    parameter HEXDIR = "rtl/nd1/data"
) (
    input  wire         clk_sys,        // 96 MHz
    input  wire         clk_sdram,      // 96 MHz, phase-shifted (pin clock)
    input  wire         pll_locked,
    input  wire         reset_in,

    input  wire         ioctl_download,
    input  wire         ioctl_upload,
    input  wire         ioctl_wr,
    input  wire  [24:0] ioctl_addr,
    input  wire   [7:0] ioctl_dout,
    output wire   [7:0] ioctl_din,
    output wire         ioctl_wait,
    input  wire   [7:0] ioctl_index,

    input  wire  [31:0] joy0,           // MiSTer: 0 R, 1 L, 2 D, 3 U, 4 B1, 5 B2, 6 B3, 7 Start1, 8 Start2, 9 Coin, 10 Service
    input  wire  [31:0] joy1,
    input  wire         test_sw,
    input  wire         freeze_sw,
    input  wire   [1:0] reverb_mode,    // 0 off, 1 light, 2 medium, 3 heavy
    input  wire         screen_flip,    // 180-degree native raster flip

    output wire         cen_pix,
    output wire         hsync, vsync, hblank, vblank, de,
    output wire  [23:0] rgb,
    output logic [15:0] snd_l,
    output logic [15:0] snd_r,

    inout  wire  [15:0] SDRAM_DQ,
    output wire  [12:0] SDRAM_A,
    output wire   [1:0] SDRAM_BA,
    output wire         SDRAM_DQML, SDRAM_DQMH,
    output wire         SDRAM_nCS, SDRAM_nWE, SDRAM_nRAS, SDRAM_nCAS,
    output wire         SDRAM_CKE, SDRAM_CLK
);
    // ---------------------------------------------------------------- reset
    logic [2:0] lock_s;
    always_ff @(posedge clk_sys) lock_s <= {lock_s[1:0], pll_locked};
    wire mem_init = ~lock_s[2];

    // ---------------------------------------------------------------- memory
    wire rom_dl = ioctl_download && ioctl_index == 8'd0;
    wire nv_dl  = ioctl_download && ioctl_index == 8'd4;
    wire mem_ready, dl_busy;
    wire prog_req, prog_ack, sub_req, sub_ack, pat_req, pat_ack, pcm_req, pcm_ack;
    wire [19:1] prog_addr; wire [18:1] sub_addr; wire [20:0] pat_addr; wire [23:0] pcm_addr;
    wire  [6:0] pat_len; wire pat_wr; wire [5:0] pat_idx;
    wire [15:0] prog_q, sub_q; wire [31:0] pat_q; wire [7:0] pcm_q;
    wire  [1:0] dqm;
    assign {SDRAM_DQMH, SDRAM_DQML} = dqm;
    assign SDRAM_nCS = 1'b0;

    ncv1_mem u_mem (
        .clk(clk_sys), .clk_sdram(clk_sdram), .init(mem_init), .ready(mem_ready),
        .rd_late(1'b1), .burst_slow(1'b0),
        .dl_we(rom_dl & ioctl_wr), .dl_addr(ioctl_addr), .dl_data(ioctl_dout), .dl_busy(dl_busy),
        .prog_addr(prog_addr), .prog_req(prog_req), .prog_ack(prog_ack), .prog_q(prog_q),
        .sub_addr(sub_addr), .sub_req(sub_req), .sub_ack(sub_ack), .sub_q(sub_q),
        .pat_addr(pat_addr), .pat_req(pat_req), .pat_ack(pat_ack), .pat_q(pat_q),
        .pat_len(pat_len), .pat_wr(pat_wr), .pat_idx(pat_idx),
        .pcm_addr(pcm_addr), .pcm_req(pcm_req), .pcm_ack(pcm_ack), .pcm_q(pcm_q),
        .dram_dq(SDRAM_DQ), .dram_a(SDRAM_A), .dram_ba(SDRAM_BA), .dram_dqm(dqm),
        .dram_clk(SDRAM_CLK), .dram_cke(SDRAM_CKE), .dram_ras_n(SDRAM_nRAS), .dram_cas_n(SDRAM_nCAS), .dram_we_n(SDRAM_nWE)
    );

    // ---------------------------------------------------------------- core reset
    wire core_reset_c = reset_in | mem_init | ~mem_ready | dl_busy | ioctl_download;
    logic core_reset_q = 1'b1, core_reset = 1'b1;
    always_ff @(posedge clk_sys) begin core_reset_q <= core_reset_c; core_reset <= core_reset_q; end

    // ---------------------------------------------------------------- inputs
    wire [15:0] p1p2 = ~{joy1[7] | joy0[8], joy1[6], joy1[5], joy1[4], joy1[3], joy1[2], joy1[1], joy1[0],
                         joy0[7],           joy0[6], joy0[5], joy0[4], joy0[3], joy0[2], joy0[1], joy0[0]};
    wire [15:0] dsw  = ~{joy0[10] | joy1[10], 1'b0, joy1[9], joy0[9], 2'b00, test_sw, freeze_sw, 8'h00};

    // ---------------------------------------------------------------- EEPROM (ioctl index 4)
    wire [7:0] eep_rd_q, hs_din;
    assign ioctl_din = ioctl_addr[11] ? hs_din : eep_rd_q;     // 0-2047 EEPROM, 2048-3071 score table

    // ---------------------------------------------------------------- high-score save (rtl/nd1_hiscore.sv)
    wire [15:1] hs_addr; wire hs_req, hs_ack; wire [1:0] hs_we; wire [15:0] hs_wdata, hs_q;
    nd1_hiscore u_hiscore (
        .clk(clk_sys), .reset(core_reset),
        .ioctl_download(ioctl_download), .ioctl_upload(ioctl_upload), .ioctl_wr(ioctl_wr),
        .ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout), .ioctl_index(ioctl_index),
        .hs_din(hs_din), .ioctl_wait(ioctl_wait),
        .vblank(vblank),
        .ram_addr(hs_addr), .ram_req(hs_req), .ram_we(hs_we), .ram_wdata(hs_wdata), .ram_q(hs_q), .ram_ack(hs_ack)
    );

    // ---------------------------------------------------------------- machine
    wire [15:0] ga_snd_l, ga_snd_r;
    wire        ga_snd_valid;
    ncv1_core #(.HEXDIR(HEXDIR)) u_core (
        .clk(clk_sys), .reset(core_reset), .pix_sync(1'b0),
        .prog_addr(prog_addr), .prog_req(prog_req), .prog_ack(prog_ack), .prog_q(prog_q),
        .sub_addr(sub_addr), .sub_req(sub_req), .sub_ack(sub_ack), .sub_q(sub_q),
        .pat_addr(pat_addr), .pat_req(pat_req), .pat_ack(pat_ack), .pat_q(pat_q),
        .pat_len(pat_len), .pat_wr(pat_wr), .pat_idx(pat_idx),
        .pcm_addr(pcm_addr), .pcm_req(pcm_req), .pcm_ack(pcm_ack), .pcm_q(pcm_q),
        .eep_ld_we(nv_dl & ioctl_wr & ioctl_addr[24:11] == 14'd0), .eep_ld_addr(ioctl_addr[10:0]), .eep_ld_data(ioctl_dout),
        .eep_rd_addr(ioctl_addr[10:0]), .eep_rd_q(eep_rd_q), .eep_dirty(),
        .hs_addr(hs_addr), .hs_req(hs_req), .hs_we(hs_we), .hs_wdata(hs_wdata), .hs_q(hs_q), .hs_ack(hs_ack),
        .dsw(dsw), .p1p2(p1p2), .screen_flip(screen_flip),
        .cen_pix(cen_pix), .hsync(hsync), .vsync(vsync), .hblank(hblank), .vblank(vblank), .de(de), .rgb(rgb),
        .snd_l(ga_snd_l), .snd_r(ga_snd_r), .snd_valid(ga_snd_valid),
        .dbg_68k_halted(), .dbg_68k_addr(), .dbg_h8_run(), .dbg_h8_pc(), .dbg_h8_istart(), .dbg_h8_irq(),
        .dbg_video_unsupported(), .dbg_video_unsup_src(), .dbg_gfxbank(), .dbg_c352_overrun()
    );

    // ---------------------------------------------------------------- audio
    // Donor path (target/pocket/core_top.sv): a 48 kHz tick (96 MHz / 2000) takes the mean
    // of the one or two C352 samples since the last tick into the cabinet reverb
    // (nc_reverb, mode 0 = off); its output is held on the next tick.
    logic [10:0] rv_div = 11'd0;
    wire         rv_tick = (rv_div == 11'd1999);
    logic signed [16:0] acc_l = 17'sd0, acc_r = 17'sd0;
    logic               acc_any = 1'b0, acc_two = 1'b0;
    logic signed [15:0] rv_in_l = 16'sd0, rv_in_r = 16'sd0;
    logic               rv_ce = 1'b0;
    wire  signed [16:0] snd_l17 = {ga_snd_l[15], ga_snd_l}, snd_r17 = {ga_snd_r[15], ga_snd_r};
    wire  signed [16:0] half_l = acc_l >>> 1, half_r = acc_r >>> 1;
    always_ff @(posedge clk_sys) begin
        rv_div <= rv_tick ? 11'd0 : rv_div + 11'd1;
        rv_ce  <= rv_tick;
        if (rv_tick) begin
            if (acc_any) begin
                rv_in_l <= acc_two ? half_l[15:0] : acc_l[15:0];
                rv_in_r <= acc_two ? half_r[15:0] : acc_r[15:0];
            end
            acc_any <= ga_snd_valid; acc_two <= 1'b0;
            if (ga_snd_valid) begin acc_l <= snd_l17; acc_r <= snd_r17; end
        end else if (ga_snd_valid) begin
            acc_any <= 1'b1; acc_two <= acc_any;
            acc_l <= acc_any ? acc_l + snd_l17 : snd_l17;
            acc_r <= acc_any ? acc_r + snd_r17 : snd_r17;
        end
    end
    wire signed [15:0] rv_l, rv_r;
    nc_reverb u_reverb (
        .clk(clk_sys), .reset(mem_init), .ce(rv_ce), .mode(reverb_mode),
        .in_l(rv_in_l), .in_r(rv_in_r), .out_l(rv_l), .out_r(rv_r));
    always_ff @(posedge clk_sys) if (rv_tick) begin snd_l <= rv_l; snd_r <= rv_r; end

    wire _unused = &{1'b0, joy0[31:11], joy1[31:11], joy1[8], ioctl_addr[24:11]};
endmodule
