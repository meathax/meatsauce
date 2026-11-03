// =============================================================================
// MCU ↔ Z80 Glue Logic — Taito System SJ MCU Daughter Board
//
// Gate-level replication of TAITOSJ MCU schematic.
// All active-low signals use _n suffix matching schematic ~{} notation.
// The core must invert its active-high decode outputs before connecting:
//   .zlread_n  (~mcu_zlread),
//   .zlwrite_n (~mcu_zlwrite),
//   .zstatus_n (~mcu_zstatus),
//   .zintrq_n  (~mcu_zintrq)
//
// Schematic blocks:
//   (1) UMCU_7A, UMCU_7B    — 74LS74  Handshake flip-flops
//   (2) UMCU_9, UMCU_13     — 74LS374 Data latches
//   (3) UMCU_10, UMCU_11B/D — 74LS374 + 74LS191 Address latch/counter
//   (4) UMCU_18A            — 74LS74  Interrupt gating flip-flop
//       UMCU_23A/B/D        — 74LS32  OR gates
//       UMCU_21A/B          — 74LS08  AND gates
//       UMCU_17D            — 74LS241 Buffer
//   (5) UMCU_20B            — 74LS367 Status buffer
//   (6) UMCU_15C            — 74LS00  NAND gate (UMCU_7A clear logic)
//       + UMCU_11D          — 74LS04  inverter
// =============================================================================

module mcu_z80_glue (
    input  wire        clk,            // 48 MHz master clock
    input  wire        reset_n,        // ~RESET (active-low)

    // --- MCU port outputs (directly from mc68705p3) ---
    input  wire [7:0]  port_a_out,     // PA[7:0] data register output
    input  wire [7:0]  port_b_out,     // PB[7:0] control register output
    input  wire [7:0]  port_b_ddr,     // PB[7:0] data direction (1=output)
    input  wire [7:0]  port_c_out,     // PC[7:0] output register

    // --- Z80 bus-side decode strobes (active-LOW, matching board) ---
    input  wire        zlread_n,       // ~ZLREAD  : Z80 reads  $8800
    input  wire        zlwrite_n,      // ~ZLWRITE : Z80 writes $8800
    input  wire        zstatus_n,      // ~ZSTATUS : Z80 reads  $8801
    input  wire        zintrq_n,       // ~ZINTRQ  : Z80 writes $8801 (unused in default jumper config)

    // --- Z80 data bus ---
    input  wire [7:0]  z80_dout,       // Z80 data output (for writes)

    // --- Z80 control signals (active-low from T80pa) ---
    input  wire        busak_n,        // ~BUSAK  (0 = bus granted)
    input  wire        m1_n,           // ~CPUM1
    input  wire        iorq_n,         // ~CPUIORQ

    // --- VBLANK interrupt (active-low, directly from board) ---
    input  wire        cpuint_n,       // ~CPUINT (0 = VBLANK pending)

    // --- DMA read data from core address mux ---
    input  wire [7:0]  dma_rdata,

    // ===== OUTPUTS =====
    output wire [7:0]  port_a_in,      // data to MCU port A input pins
    output wire [7:0]  port_c_in,      // status to MCU port C input pins
    output wire [7:0]  z80_rdata,      // Z80 reads $8800 or $8801
    output wire        busrq_n,        // ~BUSRQ to Z80
    output wire        z80_int_n,      // ~MCPUINT → Z80 ~INT
    output wire        mcu_int_n,      // 68ACCEPT → MCU ~INT pin
    output wire [15:0] dma_addr,       // DMA address to Z80 bus
    output wire [7:0]  dma_wdata,      // DMA write data
    output wire        dma_wr,         // DMA write enable
    output wire        dma_active      // 1 when bus is mastered
);

// =============================================================================
// Port B effective pin levels
//
// On real hardware: DDR=1 → output register drives pin
//                   DDR=0 → pin floats HIGH via pull-up resistors
// After reset DDR=0x00, so ALL pins read HIGH (inactive for active-low).
// =============================================================================
wire [7:0] pb_pins = (port_b_out & port_b_ddr) | (~port_b_ddr);

wire pb_68intrq_n = pb_pins[0];    // ~68INTRQ PB0
wire pb_68lrd_n   = pb_pins[1];    // ~68LRD   PB1
wire pb_68lwr_n   = pb_pins[2];    // ~68LWR   PB2
wire pb_busrq_n   = pb_pins[3];    // ~BUSRQ   PB3
wire pb_68write_n = pb_pins[4];    // ~68WRITE PB4
wire pb_68read_n  = pb_pins[5];    // ~68READ  PB5
wire pb_lal_n     = pb_pins[6];    // ~LAL     PB6
wire pb_ual_n     = pb_pins[7];    // ~UAL     PB7 (active-low!)

// ~68INTAK = ~Q of U18A (active-low). Directly connects to:
//   - U18A pin 2 (D input — makes it a toggle flip-flop)
//   - UMCU_23D input (clock qualify)
//   - MCU PC3 input (firmware reads gating state)
// See q18a_qn below for the actual signal.

// =============================================================================
// Edge detection — synchronous to 48 MHz
// =============================================================================
reg pb_68lwr_n_d, pb_68lrd_n_d, pb_ual_n_d, pb_lal_n_d;
reg zlwrite_n_d;
reg cnt_clk_d;

always @(posedge clk) begin
    pb_68lwr_n_d <= pb_68lwr_n;
    pb_68lrd_n_d <= pb_68lrd_n;
    pb_ual_n_d   <= pb_ual_n;
    pb_lal_n_d   <= pb_lal_n;
    zlwrite_n_d  <= zlwrite_n;
    cnt_clk_d    <= cnt_clk;
end

// Rising/falling edges
wire lwr_rise     = pb_68lwr_n  & ~pb_68lwr_n_d;   // ~68LWR rising (deassert)
wire lrd_rise     = pb_68lrd_n  & ~pb_68lrd_n_d;   // ~68LRD rising (deassert)
wire ual_rise     = pb_ual_n    & ~pb_ual_n_d;      // ~UAL rising (deassert = latch)
wire lal_fall     = ~pb_lal_n   &  pb_lal_n_d;      // ~LAL falling (assert)
wire cnt_rise     = cnt_clk     & ~cnt_clk_d;

// =============================================================================
// (1) Handshake Flip-Flops
// =============================================================================

// --- UMCU_15C (74LS00 NAND) → 74LS04 inverter = AND ---
// NAND(~RESET, ~ZLREAD) → NOT → ~CLR for UMCU_7A
// Equivalent: ~CLR_7A = ~RESET & ~ZLREAD
wire clr_7a_n = reset_n & zlread_n;

// --- UMCU_7A (74LS74) — MCU→Z80 data available ---
// D = VCC, CLK = ~68LWR rising, ~CLR = clr_7a_n, ~PRE = VCC
// Q7A: 1 = MCU has written data for Z80
reg q7a;
always @(posedge clk) begin
    if (!clr_7a_n)                     // async clear: reset OR Z80 read $8800
        q7a <= 1'b0;
    else if (lwr_rise)                 // CLK rising: MCU wrote data
        q7a <= 1'b1;                   // D = VCC
end

// --- UMCU_7B (74LS74) — Z80→MCU data available ---
// D = GND, CLK = ~68LRD rising, ~CLR = ~RESET, ~PRE = ~ZLWRITE
// Q7B: 1 = Z80 has written data for MCU
// ~Q7B: 68ACCEPT (0 = data pending, interrupts MCU)
//
// NOTE: ~ZINTRQ is active via a jumper (default: disconnected).
//       In default config, only ~ZLWRITE presets Q7B.
reg q7b;
always @(posedge clk) begin
    if (!reset_n)                      // async clear
        q7b <= 1'b0;
    else if (!zlwrite_n)               // async preset: ~ZLWRITE asserted (Z80 wrote $8800)
        q7b <= 1'b1;
    else if (lrd_rise)                 // CLK rising: MCU read data
        q7b <= 1'b0;                   // D = GND
end

wire zready_q7b  = q7b;               // Q:  ZREADY
wire accept_q7b  = ~q7b;              // ~Q: 68ACCEPT

assign mcu_int_n = accept_q7b;        // 68ACCEPT → MCU ~INT

// =============================================================================
// (2) Data Latches
// =============================================================================

// --- UMCU_9 (74LS374) — MCU→Z80 data latch ---
// Captures PA on rising edge of ~68LWR
reg [7:0] u9_latch;
always @(posedge clk) begin
    if (lwr_rise)
        u9_latch <= port_a_out;
end

// --- UMCU_13 (74LS374) — Z80→MCU data latch ---
// Captures Z80 data bus on rising edge of ~ZLWRITE (end of write cycle)
// ~OE = ~68LRD (output enabled when MCU reads)
reg [7:0] u13_latch;
wire zlwrite_rise = zlwrite_n & ~zlwrite_n_d;  // rising edge of ~ZLWRITE
always @(posedge clk) begin
    if (zlwrite_rise)
        u13_latch <= z80_dout;
end

// =============================================================================
// (3) Address Latch / Counter
// =============================================================================

// --- UMCU_10 (74LS374) — upper address latch A[15:8] ---
// Captures PA on rising edge of ~UAL (PB7) — latches on deassert
reg [7:0] addr_hi;
always @(posedge clk) begin
    if (ual_rise)
        addr_hi <= port_a_out;
end

// --- UMCU_21D (74LS08 AND) — counter clock ---
// CNT_CLK = ~68WRITE & ~68READ
wire cnt_clk = pb_68write_n & pb_68read_n;

// --- UMCU_11B + UMCU_11D (74LS191 x2) — lower address counter A[7:0] ---
// ~PL = ~LAL (PB6), CLK = cnt_clk, D/~U = GND (count UP)
reg [7:0] addr_lo;
always @(posedge clk) begin
    if (lal_fall)                      // parallel load on ~LAL assert
        addr_lo <= port_a_out;
    else if (cnt_rise)                 // count up on clock edge
        addr_lo <= addr_lo + 8'd1;
end

assign dma_addr = {addr_hi, addr_lo};

// =============================================================================
// (4) ~MCPUINT Interrupt Gating Circuit (from schematic image)
//
// Signal flow:
//   UMCU_23A (OR):  ~CPUM1 | ~CPUIORQ
//   UMCU_23D (OR):  ~68INTAK(~Q of 18A) | UMCU_23A_out
//   UMCU_23B (OR):  ~68INTRQ(PB2) | Q_18A         ← Q feeds back from 18A
//   UMCU_21B (AND): UMCU_23B_out & UMCU_23D_out    = ~68IVR (clock for 18A)
//   UMCU_18A (D-FF): D=~Q(pin6), CLK=~68IVR↑, ~PRE=VCC, ~CLR=~RESET (TOGGLE)
//     Q  (pin 5) → feedback to UMCU_23B
//     ~Q (pin 6) = ~68INTAK → to UMCU_23D, UMCU_21A, D input, MCU PC3
//   UMCU_17D (74LS241 buffer): ~CPUINT → buf → AND input
//   UMCU_21A (AND): ~Q_18A & buffered(~CPUINT) = ~MCPUINT → Z80 ~INT
// =============================================================================

// UMCU_23A (74LS32 OR): ~CPUM1 | ~CPUIORQ
wire umcu_23a_out = m1_n | iorq_n;

// UMCU_23D (74LS32 OR): ~68INTAK(~Q of U18A) | UMCU_23A_out
wire umcu_23d_out = q18a_qn | umcu_23a_out;

// UMCU_23B (74LS32 OR): ~68INTRQ(PB2) | Q_18A
wire umcu_23b_out = pb_68intrq_n | q18a_q;

// UMCU_21B (74LS08 AND): ~68IVR = UMCU_23B_out & UMCU_23D_out
wire umcu_21b_out = umcu_23b_out & umcu_23d_out;

// --- UMCU_18A (74LS74) — interrupt gating toggle flip-flop ---
// D = ~Q (pin 2 tied to pin 6 on PCB), CLK = ~68IVR rising, ~PRE = VCC, ~CLR = ~RESET
// This makes it a toggle: each ~68IVR rising edge flips the state.
// ~Q (pin 6) = ~68INTAK net → feeds back to D, UMCU_23D, and MCU PC3 input
reg q18a_q;                            // Q  (pin 5) → UMCU_23B feedback
wire q18a_qn = ~q18a_q;               // ~Q (pin 6) = ~68INTAK

reg umcu_21b_d;
always @(posedge clk) begin
    umcu_21b_d <= umcu_21b_out;
end
wire ivr_rise = umcu_21b_out & ~umcu_21b_d;

always @(posedge clk) begin
    if (!reset_n)
        q18a_q <= 1'b0;               // ~CLR = ~RESET
    else if (ivr_rise)
        q18a_q <= q18a_qn;            // D = ~Q (toggle)
end

// UMCU_17D (74LS241 non-inverting buffer) on ~CPUINT:
// ~CPUINT → buffer → AND input (no polarity change)
// In FPGA: cpuint_n IS ~CPUINT, buffer is just a wire
wire cpuint_buffered = cpuint_n;

// UMCU_21A (74LS08 AND): ~Q_18A (pin 6) & buffered ~CPUINT (pin 1)
// Output = ~MCPUINT
wire umcu_21a_out = q18a_qn & cpuint_buffered;

assign z80_int_n = umcu_21a_out;       // ~MCPUINT → Z80 ~INT

// =============================================================================
// (5) Status Buffer — UMCU_20B (74LS367)
// =============================================================================
// Z80 reads $8801: D0 = 68ACCEPT (~Q7B), D1 = Q7A (68READY)
wire [7:0] status_byte = {6'b000000, q7a, accept_q7b};

assign z80_rdata = ~zstatus_n ? status_byte : u9_latch;

// =============================================================================
// (6) DMA Data Path
// =============================================================================
assign dma_wdata  = port_a_out;        // UMCU_16 (74LS245)
assign dma_wr     = ~pb_68write_n;     // ~68WRITE asserted = write
assign dma_active = ~busak_n;
assign busrq_n    = pb_busrq_n;        // ~BUSRQ from PB3

// =============================================================================
// (7) MCU Port Input Muxing
// =============================================================================
assign port_a_in = (~pb_68lrd_n)                ? u13_latch :
                   (~busak_n & ~pb_68read_n)    ? dma_rdata :
                   8'hFF;

// PC0 = ZREADY (Q7B), PC1 = ZACCEPT (~Q7A), PC2 = ~BUSAK, PC3 = ~68INTAK (~Q of U18A)
assign port_c_in = {4'hF, q18a_qn, busak_n, ~q7a, zready_q7b};

endmodule
