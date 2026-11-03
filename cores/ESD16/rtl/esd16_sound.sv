// ESD16 (SWAT Police, MAME esd16.cpp) sound subsystem.
// Z80 @ 4 MHz (16 MHz/4), YM3812 @ 4 MHz (16 MHz/4), OKI MSM6295 @ 1 MHz (16 MHz/16, PIN7 high).
// Sound CPU map (esd16.cpp sound_map / sound_io_map):
//   0000-7FFF ROM, 8000-BFFF banked ROM (16 banks of 16 KB), F800-FFFF RAM
//   I/O: 00/01 YM3812, 02 OKI M6295, 03 latch read (clears pending), 04 nop, 05 bank select, 06 nop
// Main CPU writes the sound command latch at 0xC0000D; the pending flag drives Z80 INT.
// NMI pulse at 32*60 Hz (esd16.cpp set_periodic_int).
`timescale 1ns/1ps
module esd16_sound (
    input              clk,          // master clock (clk_sys)
    input              rst,
    input              cen_z80,      // 4 MHz CE (clk_sys/16)
    input              cen_ym,       // 4 MHz CE (clk_sys/16)
    input              cen_oki,      // 1 MHz CE (clk_sys/64)
    input              nmi_tick,     // one-clk pulse at 32*60 Hz
    input              cmd_wr,       // main-CPU write strobe to 0xC0000D
    input        [7:0] cmd_data,
    // Sound ROM (Z80 program, 256 KB) and sample ROM (OKI, 256 KB)
    output      [17:0] zrom_addr,
    input        [7:0] zrom_data,
    input              zrom_ok,      // program ROM data valid (SDRAM cache hit); tie 1 for a combinational ROM
    output      [17:0] orom_addr,
    input        [7:0] orom_data,
    input              orom_ok,      // sample ROM data valid; tie 1 for a combinational ROM
    output signed [15:0] snd
);
    // ---------------- Z80 -----------------
    wire        mreq_n, iorq_n, rd_n, wr_n, rfsh_n, m1_n, halt_n, busak_n;
    wire [15:0] A;
    wire  [7:0] z_do;
    reg   [7:0] z_di;
    wire  [7:0] ym_dout, oki_dout;
    reg         z_int_n, z_nmi_n;
    wire        z_wait;

    T80s u_z80 (
        .RESET_n(~rst), .CLK(clk), .CEN(cen_z80), .WAIT_n(~z_wait),
        .INT_n(z_int_n), .NMI_n(z_nmi_n), .BUSRQ_n(1'b1),
        .M1_n(m1_n), .MREQ_n(mreq_n), .IORQ_n(iorq_n), .RD_n(rd_n), .WR_n(wr_n),
        .RFSH_n(rfsh_n), .HALT_n(halt_n), .BUSAK_n(busak_n),
        .OUT0(1'b0), .A(A), .DI(z_di), .DO(z_do)
    );

    // ---------------- sound command latch -------------
    reg       pending;
    reg [7:0] latch;
    always @(posedge clk) begin
        if (rst) pending <= 1'b0;
        else if (cmd_wr) begin
            latch   <= cmd_data;
            pending <= 1'b1;
        end else if (cen_z80 && !iorq_n && !rd_n && A[7:0] == 8'h03)
            pending <= 1'b0;                       // read clears pending
    end
    always @(posedge clk) z_int_n <= ~pending;     // level INT while data pending

    // NMI: low pulse of one CEN period at each tick (edge-triggered in Z80)
    reg nmi_req;
    always @(posedge clk) begin
        if (rst) nmi_req <= 1'b0;
        else if (nmi_tick) nmi_req <= 1'b1;
        else if (cen_z80) nmi_req <= 1'b0;
    end
    always @(posedge clk) z_nmi_n <= ~(nmi_req);

    // ---------------- memories -----------------
    (* ramstyle = "M10K" *) reg [7:0] zram [0:2047];                       // F800-FFFF
    reg [3:0] zbank;
    wire      z_rom_sel  = (A[15] == 1'b0);
    wire      z_bank_sel = (A[15:14] == 2'b10);
    wire      z_ram_sel  = (A[15:11] == 5'b11111);
    assign zrom_addr = z_bank_sel ? {zbank, A[13:0]} : {2'b00, A[15:0]};

    reg [7:0] ram_q;
    // Wait states while the program ROM byte is not available yet (SDRAM cache miss)
    assign z_wait = !mreq_n && !rd_n && (z_rom_sel || z_bank_sel) && !zrom_ok;

    wire io_sel = !iorq_n && m1_n;
    wire ym_sel = io_sel && (A[7:1] == 7'h00);
    wire oki_sel = io_sel && (A[7:0] == 8'h02);
    wire latch_sel = io_sel && (A[7:0] == 8'h03);
    wire bank_sel = io_sel && (A[7:0] == 8'h05) && !wr_n;

    always @* begin
        z_di = 8'hff;
        if (!mreq_n && !rd_n) begin
            if (z_rom_sel || z_bank_sel) z_di = zrom_data;
            else if (z_ram_sel)          z_di = ram_q;
        end else if (!iorq_n && !rd_n) begin
            if (ym_sel)    z_di = ym_dout;
            else if (oki_sel) z_di = oki_dout;
            else if (latch_sel) z_di = latch;
        end
    end

    always @(posedge clk) begin
        ram_q <= zram[A[10:0]];
        if (cen_z80 && !mreq_n && !wr_n && z_ram_sel) zram[A[10:0]] <= z_do;
        if (cen_z80 && bank_sel) zbank <= z_do[3:0];
        if (rst) zbank <= 4'd0;
    end

    // ---------------- YM3812 -----------------
    wire        ym_irq_n;
    wire signed [15:0] ym_snd;
    wire        ym_sample;
    jtopl2 u_ym (
        .rst(rst), .clk(clk), .cen(cen_ym),
        .din(z_do), .addr(A[0]), .cs_n(~ym_sel), .wr_n(wr_n),
        .dout(ym_dout), .irq_n(ym_irq_n),
        .snd(ym_snd), .sample(ym_sample)
    );

    // ---------------- OKI MSM6295 -------------
    wire signed [13:0] oki_snd;
    wire        oki_sample_unused;
    jt6295 u_oki (
        .rst(rst), .clk(clk), .cen(cen_oki), .ss(1'b1),
        .wrn(wr_n | ~oki_sel), .din(z_do), .dout(oki_dout),
        .rom_addr(orom_addr), .rom_data(orom_data), .rom_ok(orom_ok),
        .sound(oki_snd), .sample(oki_sample_unused)
    );

    // ---------------- mix (MAME levels: YM 0.30, OKI 0.60) -----------------
    wire signed [31:0] oki_scaled = $signed({{18{oki_snd[13]}}, oki_snd}) <<< 2;
    wire signed [31:0] mix = (ym_snd * 3) / 10 + (oki_scaled * 6) / 10;  // 0.30*YM + 0.60*OKI
    assign snd = (mix > 32767) ? 16'sd32767 : (mix < -32768) ? 16'sh8000 : mix[15:0];
endmodule
