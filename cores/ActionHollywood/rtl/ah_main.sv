// ah_main: Action Hollywood (actionhw, TCH PRO-3/B) main CPU subsystem.
// 68000 @ 12 MHz (fx68k, phi1/phi2 CE pairs from ah_cpu_ce), ROM via SDRAM client port
// with cache/prefetch, 64 KB work RAM, inputs, 93C46 EEPROM, IRQ6, video slice, sound write.
// Memory map and behaviour: D:\Arcade\AI\mame289\src\mame\tch\kickgoal.cpp 460-485.
// Everything runs on `clk` (48 MHz) with clock enables only.  See docs/lane_A.md.
module ah_main(
    input         clk, rst, pause,
    // ROM client port (SDRAM image byte 0 = 68000 byte 0)
    output        rom_req, output [22:2] rom_addr, input rom_ack, input [31:0] rom_data,
    // video slice (A00000-C007FF): level while a 68k bus cycle to it is active
    output        vid_cs, output [23:1] cpu_addr, output [15:0] cpu_dout,
    output        cpu_uds_n, cpu_lds_n, cpu_rw,          // rw = 1 read
    input  [15:0] vid_dout, input vid_ack,
    input         vint,                                  // 1-clk pulse at start of vblank -> IRQ6
    // sound: 1-clk pulse for writes to 800004
    output reg    snd_we, output reg [15:0] snd_data, output reg snd_uds_n, snd_lds_n,
    // inputs, active low (MAME layout): P1_P2 (800000), SYSTEM (800002)
    input  [15:0] p1p2_n, input [15:0] system_n,
    // EEPROM persistence (64 x 16), framework side
    input  [5:0]  nv_addr, input [15:0] nv_din, input nv_we, output [15:0] nv_dout,
    output [2:0]  dbg_state,                              // {irq6 pending, bus stalled, cpu out of reset}
    // hiscore RAM port (work RAM FF0000-FFFFFF, byte access, 16-bit byte offset inside the 64 KB)
    input         hs_pause_req,                           // stop the 68000 at an idle bus boundary
    output        cpu_paused,                             // CPU frozen (hs hold reached, or user pause)
    input  [15:0] hs_addr, input [7:0] hs_din,
    input         hs_rd, hs_wr,                           // levels, held until hs_ready rises
    output reg    hs_ready, output reg [7:0] hs_dout
);

// ------------------------------------------------------------------ CPU core
wire        fx_asn, fx_uds_n, fx_lds_n, fx_rw, fx_fc0, fx_fc1, fx_fc2;
wire [23:1] fx_addr;
wire [15:0] fx_dout;
wire        ce1, ce2;
reg         irq6;
reg  [15:0] rd_hold;
wire        dtack_n;

wire init_done;
wire cpu_rst = rst | ~init_done;

fx68k u_cpu (
    .clk(clk), .HALTn(1'b1), .extReset(cpu_rst), .pwrUp(cpu_rst),
    .enPhi1(ce1), .enPhi2(ce2),
    .eRWn(fx_rw), .ASn(fx_asn), .LDSn(fx_lds_n), .UDSn(fx_uds_n),
    .E(), .VMAn(), .FC0(fx_fc0), .FC1(fx_fc1), .FC2(fx_fc2),
    .BGn(), .oRESETn(), .oHALTEDn(),
    .DTACKn(dtack_n), .VPAn(1'b1), .BERRn(1'b1), .BRn(1'b1), .BGACKn(1'b1),
    .IPL0n(1'b1), .IPL1n(~irq6), .IPL2n(~irq6),          // level 6 = 110
    .iEdb(rd_hold), .oEdb(fx_dout), .eab(fx_addr), .dbgPc()
);

assign cpu_addr  = fx_addr;
assign cpu_dout  = fx_dout;
assign cpu_uds_n = fx_uds_n;
assign cpu_lds_n = fx_lds_n;
assign cpu_rw    = fx_rw;

// ------------------------------------------------------------------ bus decode
wire        as_act = ~fx_asn;
wire        ds_act = ~(fx_uds_n & fx_lds_n);
wire        iack   = as_act & fx_fc2 & fx_fc1 & fx_fc0;      // interrupt acknowledge
wire        cyc    = as_act & ~iack;                          // ordinary bus cycle
wire        wr     = ~fx_rw;
wire [23:1] a      = fx_addr;                                 // a[n] = byte address bit n

wire sel_rom  = (a[23:20] == 4'h0);
wire sel_io   = (a[23:12] == 12'h800);                        // 800000-800FFF
wire sel_ee   = (a[23:16] == 8'h90);                          // 900000-90FFFF
// video slice: A00000-A0FFFF, A10000-A1000F, B00000-B007FF, C00000-C007FF
wire sel_vid  = (a[23:16] == 8'hA0) || (a[23:4] == 20'hA1000) ||
                (a[23:11] == 13'h1600) || (a[23:11] == 13'h1800);
wire sel_ram  = (a[23:16] == 8'hFF);
wire sel_inp0 = sel_io && (a[11:1] == 11'd0);                 // 800000
wire sel_inp1 = sel_io && (a[11:1] == 11'd1);                 // 800002
wire sel_snd  = sel_io && (a[11:1] == 11'd2);                 // 800004
wire sel_ee_cs  = sel_ee && (a[15:1] == 15'd0);               // 900001 (odd byte)
wire sel_ee_clk = sel_ee && (a[15:1] == 15'd1);               // 900003
wire sel_ee_di  = sel_ee && (a[15:1] == 15'd2);               // 900005
wire sel_ee_do  = sel_ee && (a[15:1] == 15'd3);               // 900007

// address stability (BRAM style lookups are registered)
reg [23:1] addr_q;
always @(posedge clk) addr_q <= fx_addr;
wire addr_stable = (addr_q == fx_addr);

// ------------------------------------------------------------------ ROM + cache
wire        rom_hit;
wire [31:0] rom_line;
wire        rom_rd = cyc & sel_rom & fx_rw;
reg         rdy_q;
wire        rdy_c;
wire        rom_done = rom_rd & ~rdy_q & rdy_c;               // first clk the read is satisfied

ah_cpu_rom #(.IDXB(9)) u_rom (
    .clk(clk), .rst(rst), .line(fx_addr[19:2]), .rd_act(rom_rd), .pf_trig(rom_done),
    .hit(rom_hit), .hdata(rom_line), .init_done(init_done),
    .rom_req(rom_req), .rom_addr(rom_addr), .rom_ack(rom_ack), .rom_data(rom_data)
);
wire [15:0] rom_word = fx_addr[1] ? {rom_line[23:16], rom_line[31:24]}
                                  : {rom_line[7:0],   rom_line[15:8]};

// ------------------------------------------------------------------ work RAM (FF0000-FFFFFF)
// One physical port shared by the 68000 and the hiscore module.  The hiscore module only gets the port
// while the CPU is frozen (hold at an idle bus boundary or user pause); while hs_act is high the CPU side
// neither writes nor sees valid read data (rdy_c below), so a CPU cycle frozen mid-flight resumes cleanly.
reg        hs_act, hs_act_q, hs_phase;
reg [15:0] hs_addr_r; reg [7:0] hs_din_r; reg hs_wr_r;
(* ramstyle = "M10K,no_rw_check" *) reg [7:0] ram_h [0:32767];
(* ramstyle = "M10K,no_rw_check" *) reg [7:0] ram_l [0:32767];
reg [15:0] ram_q;
wire        ram_we_cpu = cyc & sel_ram & wr & ds_act & ~hs_act;
wire [14:0] ram_a  = hs_act ? hs_addr_r[15:1] : a[15:1];
wire        ram_wh = hs_act ? (hs_wr_r & ~hs_addr_r[0]) : (ram_we_cpu & ~fx_uds_n);   // even byte = high lane
wire        ram_wl = hs_act ? (hs_wr_r &  hs_addr_r[0]) : (ram_we_cpu & ~fx_lds_n);
wire [7:0]  ram_dh = hs_act ? hs_din_r : fx_dout[15:8];
wire [7:0]  ram_dl = hs_act ? hs_din_r : fx_dout[7:0];
always @(posedge clk) begin
    if (ram_wh) ram_h[ram_a] <= ram_dh;
    if (ram_wl) ram_l[ram_a] <= ram_dl;
    ram_q <= {ram_h[ram_a], ram_l[ram_a]};
end

// hiscore access sequencer: request (level) -> hs_act for 2 clk (write at the first, registered read at the
// second) -> hs_ready (held until the request drops).  Data is held in hs_dout until the next access.
reg hs_busy;
always @(posedge clk) begin
    hs_act_q <= hs_act;
    if (rst) begin hs_act <= 1'b0; hs_phase <= 1'b0; hs_ready <= 1'b0; hs_busy <= 1'b0; end
    else begin
        if (!(hs_rd | hs_wr)) hs_ready <= 1'b0;
        if (!hs_busy) begin
            if ((hs_rd | hs_wr) & ~hs_ready & cpu_paused) begin
                hs_busy <= 1'b1; hs_act <= 1'b1; hs_phase <= 1'b0;
                hs_addr_r <= hs_addr; hs_din_r <= hs_din; hs_wr_r <= hs_wr;
            end
        end else if (!hs_phase) hs_phase <= 1'b1;             // ram_q now holds the addressed word
        else begin
            hs_dout  <= hs_addr_r[0] ? ram_q[7:0] : ram_q[15:8];
            hs_act   <= 1'b0; hs_busy <= 1'b0; hs_ready <= 1'b1;
        end
    end
end

// ------------------------------------------------------------------ video slice
assign vid_cs = cyc & sel_vid & ds_act;
reg vid_cs_q;
always @(posedge clk) vid_cs_q <= vid_cs;

// ------------------------------------------------------------------ EEPROM (93C46 16 bit)
reg ee_cs, ee_clk, ee_di;
wire ee_do;
always @(posedge clk) begin
    if (rst) begin ee_cs <= 1'b0; ee_clk <= 1'b0; ee_di <= 1'b0; end
    else if (cyc & wr & ~fx_lds_n) begin                       // lw8 handlers on the odd (low) byte
        if (sel_ee_cs)  ee_cs  <= fx_dout[0];
        if (sel_ee_clk) ee_clk <= fx_dout[0];
        if (sel_ee_di)  ee_di  <= fx_dout[0];
    end
end
// MAME's default EEPROM image is all zero (kickgoal_default_eeprom_type1); jt9346 powers up all ones.
// Zero-fill once after configuration; a later nvram download from the HPS overrides it.
reg [6:0] ee_init = 7'd0;
wire ee_init_act = !ee_init[6];
always @(posedge clk) if (ee_init_act) ee_init <= ee_init + 7'd1;

jt9346 u_ee (
    .rst(rst), .clk(clk), .sclk(ee_clk), .sdi(ee_di), .sdo(ee_do), .scs(ee_cs),
    .dump_clk(clk), .dump_addr(ee_init_act ? ee_init[5:0] : nv_addr), .dump_we(ee_init_act | nv_we), .dump_din(ee_init_act ? 16'h0000 : nv_din),
    .dump_dout(nv_dout), .dump_clr(1'b0), .dump_flag()
);

// ------------------------------------------------------------------ read mux / ready / DTACK
reg [15:0] rd_mux;
always @* begin
    rd_mux = 16'h0000;
    if (iack)           rd_mux = 16'h001E;                     // vector 30 -> IRQ6 autovector address 0x78
    else if (sel_rom)   rd_mux = rom_word;
    else if (sel_ram)   rd_mux = ram_q;
    else if (sel_vid)   rd_mux = vid_dout;
    else if (sel_inp0)  rd_mux = p1p2_n;
    else if (sel_inp1)  rd_mux = system_n;
    else if (sel_ee_do) rd_mux = {15'd0, ee_do};
end

assign rdy_c = iack |
               (cyc & (sel_rom ? (wr | rom_hit) :
                       sel_ram ? (addr_stable & ~hs_act & ~hs_act_q) :
                       sel_vid ? (ds_act & vid_cs_q & vid_ack) : 1'b1));

always @(posedge clk) begin
    if (cpu_rst) begin
        rdy_q <= 1'b0; rd_hold <= 16'd0;
    end else begin
        rdy_q <= as_act & (rdy_q | rdy_c);
        if (as_act & ~rdy_q & rdy_c) rd_hold <= rd_mux;     // data held until AS ends
    end
end
assign dtack_n = ~(rdy_q & as_act);

// stall: withhold phi2 while a bus cycle (or IACK) waits for its data
wire block2 = as_act & (ds_act | iack) & ~(rdy_q | rdy_c);

// hiscore hold: freeze the CPU only when no bus cycle is in flight (AS inactive for 2 clk, last phi1 at
// least 2 clk ago, so an AS that phi1 creates one clk later is already visible) -> nothing half done.
reg as_q; reg [1:0] since1; reg hs_hold;
always @(posedge clk) begin
    as_q <= as_act;
    if (ce1) since1 <= 2'd0; else if (since1 != 2'd3) since1 <= since1 + 2'd1;
    if (!hs_pause_req || rst) hs_hold <= 1'b0;
    else if (!as_act && !as_q && since1 >= 2'd2) hs_hold <= 1'b1;
end
reg paused_q;
always @(posedge clk) paused_q <= pause | hs_hold;
assign cpu_paused = paused_q & (pause | hs_hold);

ah_cpu_ce #(.CMAX(48)) u_ce (
    .clk(clk), .rst(cpu_rst), .pause(pause | hs_hold), .block2(block2),
    .ce1(ce1), .ce2(ce2), .credit()
);

// ------------------------------------------------------------------ IRQ6 (level held until IACK)
// The level is dropped on the first clk of the IACK bus cycle only (IACK stays active for the
// whole cycle); a vint arriving later in or after the cycle re-arms it and is taken after RTE.
reg iack_q;
always @(posedge clk) begin
    iack_q <= iack;
    if (rst) irq6 <= 1'b0;
    else if (vint) irq6 <= 1'b1;
    else if (iack & ~iack_q) irq6 <= 1'b0;
end

// ------------------------------------------------------------------ sound write pulse (800004)
reg wdone;
always @(posedge clk) begin
    snd_we <= 1'b0;
    if (!as_act) wdone <= 1'b0;
    else if (cyc & wr & ds_act & sel_snd & ~wdone) begin
        wdone <= 1'b1; snd_we <= 1'b1;
        snd_data <= fx_dout; snd_uds_n <= fx_uds_n; snd_lds_n <= fx_lds_n;
    end
    if (rst) begin snd_we <= 1'b0; wdone <= 1'b0; end
end

assign dbg_state = {irq6, block2, init_done};
endmodule
