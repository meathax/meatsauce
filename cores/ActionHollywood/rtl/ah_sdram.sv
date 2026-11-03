// Action Hollywood SDRAM controller: 95.9079 MHz (nominal 96) command clock (clk96 = 2 x clk48, same PLL),
// three read-only client ports in the clk48 domain (GFX, ROM, OKI; fixed priority loader > GFX > OKI > ROM) plus a
// 16-bit write port for the ROM loader (served first).
//
// Fixed 8-cycle slot per access (ACT - NOP - READ/WRITE(+auto-precharge) - ...), which
// satisfies tRCD>=2, tRC>=8 cycles (83 ns), tRP, tRFC (REF slot = 8 cycles) at 96 MHz.
// Mode register: CL3, burst length 2 (sequential), single-location writes.
//   READ latched by the chip at edge R=e(n+3); DQ valid at the READ+CL edge: beat0 is sampled
//   at e(n+6), beat1 at e(n+7)  (lesson 2026-10-21 CORRECTION: READ+CL, never move model and
//   controller together).  data[15:0] = word w (image bytes addr+0,+1), data[31:16] = word w+1.
//
// Client protocol (identical for the three read ports): req is a level that is held until the
// one-cycle ack pulse; data is valid in the ack cycle; a client may raise a new req in the cycle
// after ack.  addr[22:2] is a 32-bit-word index (byte address = {addr,2'b00}).
// Loader port: wr_req level, wr_addr[21:0] = 16-bit word index (byte address >> 1), ack pulse wr_ack.
//
// Clock-domain crossing: both clocks come from one PLL (clk96 rising edges include every clk48
// rising edge).  Requests cross as toggles through two flip-flops in the destination domain,
// address/data buses are held static for >= 4 destination cycles around the toggle edge.
module ah_sdram #(
    parameter INIT_WAIT = 14'd16383  // clk96 cycles after lock before the init sequence (170 us, >= 100..200 us part requirement)
)(
    input         clk96, clk48,
    input         run,                // PLL locked (async); low holds the controller in reset
    output        ready,              // clk48 domain: init sequence complete
    // SDRAM pins (clock pin is generated outside)
    output reg [12:0] SDRAM_A,
    output reg  [1:0] SDRAM_BA,
    output            SDRAM_DQML, SDRAM_DQMH,
    output            SDRAM_nCS, SDRAM_CKE,
    output reg        SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE,
    input      [15:0] dq_in,
    output reg [15:0] dq_out,
    output reg [15:0] dq_oe,   // one OE register per pad so FAST_OUTPUT_ENABLE_REGISTER can pack it
    // clients (clk48 domain)
    input         gfx_req, input [22:2] gfx_addr, output gfx_ack, output [31:0] gfx_data,
    input         rom_req, input [22:2] rom_addr, output rom_ack, output [31:0] rom_data,
    input         oki_req, input [22:2] oki_addr, output oki_ack, output [31:0] oki_data,
    input         wr_req,  input [21:0] wr_addr,  input [15:0] wr_data, output wr_ack,
    input  [1:0]  cap_sel                    // read capture tap (OSD SDRAM Capture), 0 = Pos4
);
assign SDRAM_nCS = 1'b0;
assign SDRAM_CKE = 1'b1;
assign {SDRAM_DQMH, SDRAM_DQML} = SDRAM_A[12:11];

localparam [2:0] CMD_NOP = 3'b111, CMD_ACT = 3'b011, CMD_READ = 3'b101, CMD_WRITE = 3'b100,
                 CMD_PRE = 3'b010, CMD_REF = 3'b001, CMD_LMR = 3'b000;
// BL=2 (001), sequential (0), CL=3 (011), standard op, single-location write burst (A9=1)
localparam [12:0] MODE = 13'b0_0010_0011_0001;

// ------------------------------------------------------------------ resets per domain
reg [2:0] run48 = 3'b000, run96 = 3'b000;
always @(posedge clk48 or negedge run) if (!run) run48 <= 3'b000; else run48 <= {run48[1:0], 1'b1};
always @(posedge clk96 or negedge run) if (!run) run96 <= 3'b000; else run96 <= {run96[1:0], 1'b1};
wire rst48 = ~run48[2], rst96 = ~run96[2];

// ------------------------------------------------------------------ clk48 side port adapters
// tgl48 (toggles when a new request is posted) / done96 (toggles when the data is ready)
wire [3:0] tgl48;
wire [3:0] done96;
reg [31:0] data96;                 // shared read data register (clk96)
wire [20:0] a48_0, a48_1, a48_2;   // 32-bit word index of each posted request (static while pending)
wire [21:0] a48_3;                 // loader: 16-bit word index
wire [15:0] wdata48;

ah_sdram_p48 #(.AW(21)) p_gfx (.clk(clk48), .rst(rst48), .req(gfx_req), .addr(gfx_addr),
    .ack(gfx_ack), .data(gfx_data), .tgl(tgl48[0]), .addr_o(a48_0), .done96(done96[0]), .data96(data96));
ah_sdram_p48 #(.AW(21)) p_rom (.clk(clk48), .rst(rst48), .req(rom_req), .addr(rom_addr),
    .ack(rom_ack), .data(rom_data), .tgl(tgl48[1]), .addr_o(a48_1), .done96(done96[1]), .data96(data96));
ah_sdram_p48 #(.AW(21)) p_oki (.clk(clk48), .rst(rst48), .req(oki_req), .addr(oki_addr),
    .ack(oki_ack), .data(oki_data), .tgl(tgl48[2]), .addr_o(a48_2), .done96(done96[2]), .data96(data96));

// loader write port (own small adapter: address+data captured at post time)
reg        wr_pend, wr_tgl, wr_ack_r;
reg [21:0] wr_addr_l;
reg [15:0] wr_data_l;
reg [1:0]  wr_done_s;
always @(posedge clk48) begin
    wr_done_s <= {wr_done_s[0], done96[3]};
    wr_ack_r  <= 1'b0;
    if (rst48) begin
        wr_pend <= 1'b0; wr_tgl <= 1'b0; wr_done_s <= 2'b00;
    end else begin
        if (!wr_pend && wr_req && !wr_ack_r) begin
            wr_tgl <= ~wr_tgl; wr_addr_l <= wr_addr; wr_data_l <= wr_data; wr_pend <= 1'b1;
        end
        if (wr_pend && wr_done_s[1] == wr_tgl) begin
            wr_pend <= 1'b0; wr_ack_r <= 1'b1;
        end
    end
end
assign wr_ack = wr_ack_r;
assign tgl48[3] = wr_tgl;
assign a48_3 = wr_addr_l;
assign wdata48 = wr_data_l;

// ------------------------------------------------------------------ ready crossing
reg ready96;
reg [1:0] ready_s;
always @(posedge clk48) ready_s <= rst48 ? 2'b00 : {ready_s[0], ready96};
assign ready = ready_s[1];

// ------------------------------------------------------------------ clk96 controller
reg [3:0] tg_s0 = 4'd0, tg_s1 = 4'd0;
reg [3:0] done96_r;
assign done96 = done96_r;
wire [3:0] pend = tg_s1 ^ done96_r;      // request toggled but not yet completed
always @(posedge clk96) begin tg_s0 <= tgl48; tg_s1 <= tg_s0; end

reg [13:0] icnt;
reg [3:0]  ist;       // 0 wait, 1 PRE, 2 REF, 3 REF, 4 LMR, 5 done
reg [3:0]  t;         // slot cycle being assigned
reg [9:0]  rcnt;
reg        ref_due;
reg [1:0]  last;      // last served read port (fixed priority loader > GFX > OKI > ROM)
reg [1:0]  sel;       // port in the slot
reg        kind_wr, kind_ref;
reg [21:0] sel_addr;
reg [15:0] sel_wdata;
reg [15:0] d0;
reg        inited;

// next-port selection
reg        g_valid;
reg [1:0]  g_port;
always @* begin
    g_valid = 1'b0; g_port = 2'd0;
    if (pend[3]) begin g_valid = 1'b1; g_port = 2'd3; end
    else if (pend[0]) begin g_valid = 1'b1; g_port = 2'd0; end   // GFX (line-buffer deadline)
    else if (pend[2]) begin g_valid = 1'b1; g_port = 2'd2; end   // OKI (no rom_ok in jt6295: <<190 clk)
    else if (pend[1]) begin g_valid = 1'b1; g_port = 2'd1; end   // 68k ROM (cycle recovery absorbs waits)
end
reg [21:0] g_addr;
always @* case (g_port)
    2'd0: g_addr = {a48_0, 1'b0};
    2'd1: g_addr = {a48_1, 1'b0};
    2'd2: g_addr = {a48_2, 1'b0};
    default: g_addr = a48_3;
endcase

// Unconditional pad capture register (packs into the IO input register).
reg [15:0] dq_q;
always @(posedge clk96) dq_q <= dq_in;
// DQ capture: dq_q is the only pad register (rising clk96, packed in the IO input cell, fully timed by AH.sdc).
// The beat is picked from its history.  Hardware scan on the user's MiSTer (2026-10-23, OSD debug page):
//   Pos4 = q2 reads the correct beat and runs attract for minutes (default);  Pos5 = q1 mixes beat0/beat1 (old default);
//   a falling-edge fabric tap also passed the boot check but its routing was unconstrained and the game froze later.
// The selectable taps are all history copies of the same timed register, so every choice stays STA-covered.
reg [15:0] q1, q2, q3;
always @(posedge clk96) begin q1 <= dq_q; q2 <= q1; q3 <= q2; end
reg [15:0] dq_cap;
always @* case (cap_sel)
    2'd0: dq_cap = q2;      // Pos4 (hardware default)
    2'd1: dq_cap = q1;      // Pos5
    2'd2: dq_cap = q3;      // Pos3
    default: dq_cap = dq_q; // Pos6
endcase

always @(posedge clk96) begin
    {SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} <= CMD_NOP;
    SDRAM_A  <= 13'd0;
    dq_oe    <= 16'h0000;
    if (rst96) begin
        icnt <= 14'd0; ist <= 4'd0; t <= 4'd0; rcnt <= 10'd0; ref_due <= 1'b0;
        last <= 2'd2; ready96 <= 1'b0; inited <= 1'b0; done96_r <= 4'd0;
        SDRAM_BA <= 2'b00;
    end else if (!inited) begin
        // power-up sequence; one command every 8 cycles after the initial wait
        case (ist)
            4'd0: begin
                icnt <= icnt + 14'd1;
                if (icnt == INIT_WAIT) begin ist <= 4'd1; icnt <= 14'd0; end
            end
            4'd1: begin // PRECHARGE ALL
                if (icnt == 14'd0) begin {SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} <= CMD_PRE; SDRAM_A <= 13'b0010000000000; end
                icnt <= icnt + 14'd1;
                if (icnt == 14'd7) begin ist <= 4'd2; icnt <= 14'd0; end
            end
            4'd2, 4'd3: begin // AUTO REFRESH x2
                if (icnt == 14'd0) {SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} <= CMD_REF;
                icnt <= icnt + 14'd1;
                if (icnt == 14'd7) begin ist <= ist + 4'd1; icnt <= 14'd0; end
            end
            4'd4: begin // LOAD MODE
                if (icnt == 14'd0) begin {SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} <= CMD_LMR; SDRAM_A <= MODE; SDRAM_BA <= 2'b00; end
                icnt <= icnt + 14'd1;
                if (icnt == 14'd7) begin ist <= 4'd5; icnt <= 14'd0; end
            end
            default: begin inited <= 1'b1; ready96 <= 1'b1; rcnt <= 10'd0; end
        endcase
    end else begin
        // refresh timer
        if (rcnt >= 10'd730) ref_due <= 1'b1; else rcnt <= rcnt + 10'd1;
        case (t)
            3'd0: begin
                if (ref_due) begin
                    {SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} <= CMD_REF; kind_ref <= 1'b1; ref_due <= 1'b0; rcnt <= 10'd0; t <= 3'd1;
                end else if (g_valid) begin
                    {SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} <= CMD_ACT; kind_ref <= 1'b0;
                    sel <= g_port; sel_addr <= g_addr; kind_wr <= (g_port == 2'd3);
                    sel_wdata <= wdata48;
                    SDRAM_A  <= g_addr[21:9];             // row (13 bits)
                    SDRAM_BA <= 2'b00;                    // 8 MB image = bank 0, rows 0..8191
                    if (g_port != 2'd3) last <= g_port[1:0];
                    t <= 3'd1;
                end
            end
            3'd1: t <= 3'd2;
            3'd2: begin
                if (!kind_ref) begin
                    // column: A12:A11 = 0 (DQM enabled), A10 = 1 (auto-precharge), A9 = 0, A8:0 col
                    SDRAM_A <= {2'b00, 1'b1, 1'b0, sel_addr[8:1], kind_wr ? sel_addr[0] : 1'b0};   // loader writes address 16-bit words (A0 = word bit 0)
                    if (kind_wr) begin {SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} <= CMD_WRITE; dq_out <= sel_wdata; dq_oe <= 16'hFFFF; end
                    else {SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} <= CMD_READ;
                end
                t <= 3'd3;
            end
            3'd3, 3'd4, 3'd5: t <= t + 4'd1;
            // Physical capture beat (derived from fitted STA, see AH.sdc): the forwarded pin clock lags the core
            // clock by ~5 ns, so the CL3 data of READ(E0) sampled at pin edge E1 reaches the pad register one core
            // edge later than the ideal chip timing; hardware shows the beat one edge earlier (tap Pos4, see dq_cap).
            3'd6: t <= 4'd7;
            3'd7: t <= 4'd8;
            4'd8: t <= 4'd9;                                  // calibration build: strobe one clk96 later, history taps below
            4'd9: begin
                if (!kind_ref && !kind_wr) d0 <= dq_cap;       // beat 0
                t <= 4'd10;
            end
            default: begin // 10
                if (!kind_ref) begin
                    if (!kind_wr) data96 <= {dq_cap, d0};       // beat 1
                    done96_r[sel] <= ~done96_r[sel];
                end
                t <= 4'd0;
            end
        endcase
    end
end
endmodule

// clk48 client adapter: level request -> toggle, ack pulse + registered data on completion.
module ah_sdram_p48 #(parameter AW = 21)(
    input             clk, rst,
    input             req,
    input  [AW-1:0]   addr,
    output reg        ack,
    output reg [31:0] data,
    output reg        tgl,
    output reg [AW-1:0] addr_o,
    input             done96,
    input      [31:0] data96
);
reg pend;
reg [1:0] ds;
always @(posedge clk) begin
    ds  <= {ds[0], done96};
    ack <= 1'b0;
    if (rst) begin
        pend <= 1'b0; tgl <= 1'b0; ds <= 2'b00;
    end else begin
        if (!pend && req && !ack) begin
            tgl <= ~tgl; addr_o <= addr; pend <= 1'b1;
        end
        if (pend && ds[1] == tgl) begin     // completion toggle caught up with the request
            pend <= 1'b0; ack <= 1'b1; data <= data96;
        end
    end
end
endmodule
