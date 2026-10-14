//============================================================================
//  ddram_rotate_arb.sv
//
//  Two-master arbiter for the single HPS->FPGA DDR3 bridge (top-level DDRAM_*),
//  added to let the standard MiSTer sys/screen_rotate.v rotation frame buffer
//  share the DDR3 port with the PSX VRAM store.
//
//  ------------------------------------------------------------------------
//  Why this module instead of routing both masters through rtl/ddram.sv:
//
//  The user's directive was to share the DDR bridge "via rtl/ddram.sv". After
//  reading the actual module shapes that turned out to be infeasible without a
//  high-risk rewrite of the latency-critical VRAM path, so a thin 2:1 DDRAM
//  passthrough mux is used instead (this is sub-approach (b) from the design
//  doc, which explicitly permits "adapt ddram.sv or write a minimal one"):
//
//    * rtl/ddram.sv exposes narrow ch1..ch5 word channels (16/32/64-bit,
//      single/double-word, address HARD-WIRED to 0x30000000). It cannot carry
//      psx_top's native 64-bit *burst* master (BURSTCNT/DOUT_READY streaming) -
//      that is exactly the VRAM path the task says must stay bit-identical.
//    * sys/screen_rotate.v already exposes a COMPLETE DDRAM-style master
//      (BURSTCNT/ADDR/DIN/BE/WE/RD). It is write-only, single-beat, and targets
//      a DISTINCT DDR region (0x24000000, 3x8MB) that never overlaps VRAM
//      (0x30000000). So both sides already speak the raw DDRAM protocol and the
//      cleanest, lowest-risk join is a small priority mux, not ddram.sv.
//
//  Design:
//    * Master 0 (psx VRAM) has ABSOLUTE priority and read+write burst access.
//      Reads are always routed straight back to it (the rotate master never
//      reads, so DDRAM_DOUT/DOUT_READY are unconditionally psx's).
//    * Master 1 (screen_rotate) is a write-only, single-beat master. Its writes
//      are buffered in a small synchronous FIFO and drained onto the bus only in
//      cycles where psx is not requesting. Once a rotate write has been presented
//      it is held (psx stalled via p_busy) until the bridge accepts it, so no
//      write is ever lost mid-handshake.
//    * ROTATION OFF path is bit-identical to before: screen_rotate emits no
//      writes when no_rotate=1 (its FB_EN stays 0), so r_we never fires, the FIFO
//      stays empty, rot_drive stays 0, and every DDRAM_* pin plus p_busy tracks
//      the psx master exactly as when it drove the port directly.
//
//  This module and the screen_rotate master both run in the DDRAM clock domain
//  (clk_2x). The pixel->clk_2x crossing for screen_rotate's CE_PIXEL is done in
//  ZN1.sv (data held stable between pixel enables; only the enable is synced).
//============================================================================

module ddram_rotate_arb
(
	input         clk,              // DDRAM clock (clk_2x)

	// ---- physical DDRAM bridge (to sys_top) ----
	input         DDRAM_BUSY,
	output  [7:0] DDRAM_BURSTCNT,
	output [28:0] DDRAM_ADDR,
	input  [63:0] DDRAM_DOUT,
	input         DDRAM_DOUT_READY,
	output        DDRAM_RD,
	output [63:0] DDRAM_DIN,
	output  [7:0] DDRAM_BE,
	output        DDRAM_WE,

	// ---- master 0: PSX VRAM (priority, read+write burst) ----
	input   [7:0] p_burstcnt,
	input  [28:0] p_addr,
	output [63:0] p_dout,
	output        p_dout_ready,
	input         p_rd,
	input  [63:0] p_din,
	input   [7:0] p_be,
	input         p_we,
	output        p_busy,

	// ---- master 1: screen_rotate framebuffer (write-only, single-beat) ----
	input         r_we,             // 1-cycle write pulse (clk domain)
	input  [28:0] r_addr,
	input  [63:0] r_din,
	input   [7:0] r_be
);

// ---------------- small write FIFO for the rotate master ----------------
localparam AW = 6;                     // depth 64
localparam DW = 29 + 64 + 8;           // {addr, din, be} = 101 bits

reg  [DW-1:0] fifo [0:(1<<AW)-1];
reg  [AW:0]   wptr = 0;
reg  [AW:0]   rptr = 0;

wire          empty = (wptr == rptr);
wire          full  = (wptr[AW-1:0] == rptr[AW-1:0]) && (wptr[AW] != rptr[AW]);
wire          start_rot;

wire [DW-1:0] fdat  = fifo[rptr[AW-1:0]];
wire [28:0]   f_addr = fdat[100:72];
wire [63:0]   f_din  = fdat[71:8];
wire  [7:0]   f_be   = fdat[7:0];

always @(posedge clk) begin
	// A pop captures the old head before this edge's nonblocking write.
	// Accept its replacement even when the FIFO was full before the edge.
	if (r_we && (!full || start_rot)) begin
		fifo[wptr[AW-1:0]] <= {r_addr, r_din, r_be};
		wptr <= wptr + 1'b1;
	end
end

// ---------------- priority arbitration (pipelined for DDR-clock timing) ----------------
// The rotate write is captured from the FIFO into a REGISTERED "presented" latch
// one cycle before it drives the bus, so the DDRAM_* data muxes see only registered
// inputs (pres_* and psx's already-registered p_*) with a registered select (issuing).
// This removes the FIFO-memory-read->wide-mux->pin path and the psx_active->p_busy
// feedback path that dominated the -0.981ns setup violation. The extra capture cycle
// only delays the (latency-tolerant) rotate writes; the PSX VRAM path is unaffected.
reg         issuing = 0;               // a captured rotate write is driving the bus
reg  [28:0] pres_addr;
reg  [63:0] pres_din;
reg   [7:0] pres_be;
wire        psx_active = p_rd | p_we;
// begin presenting the next rotate write only when psx is idle and one is queued
assign      start_rot  = ~issuing & ~psx_active & ~empty;

always @(posedge clk) begin
	if (start_rot) begin
		pres_addr <= f_addr;             // capture FIFO head into registers
		pres_din  <= f_din;
		pres_be   <= f_be;
		issuing   <= 1'b1;
		rptr      <= rptr + 1'b1;         // pop
	end
	else if (issuing && !DDRAM_BUSY) begin
		issuing   <= 1'b0;               // write accepted by the bridge
	end
end

// rot_drive is now purely registered (issuing) -> registered mux select
assign DDRAM_ADDR     = issuing ? pres_addr : p_addr;
assign DDRAM_DIN      = issuing ? pres_din  : p_din;
assign DDRAM_BE       = issuing ? pres_be   : p_be;
assign DDRAM_BURSTCNT = issuing ? 8'd1      : p_burstcnt;
assign DDRAM_WE       = issuing ? 1'b1      : p_we;
assign DDRAM_RD       = issuing ? 1'b0      : p_rd;

// reads belong to psx only; rotate master never reads
assign p_dout       = DDRAM_DOUT;
assign p_dout_ready = DDRAM_DOUT_READY;
// stall psx only while a rotate write is actually driving the bus (registered).
// start_rot cannot collide with a psx request (it requires ~psx_active), so p_busy
// need not depend combinationally on psx_active anymore.
assign p_busy       = DDRAM_BUSY | issuing;

endmodule
