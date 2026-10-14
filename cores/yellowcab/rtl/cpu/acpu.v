//============================================================================
// Sound DECO222 @ ~1.5 MHz
//
// MAME deco222.cpp models this device as a stock 6502 whose read_sync() -- the
// opcode fetch, and only that -- returns bitswap<8>(byte,7,5,6,4,3,2,1,0).
// read_arg() (operands) and data reads are untouched.
//
// The decryption itself now lives inside cpu6502.v on the IR path (DECRYPT),
// which is an exact transcription of that rule: every byte that becomes the
// instruction register is swapped, nothing else is. This wrapper no longer has
// to answer "is this bus cycle an opcode fetch?" -- the previous version tried
// to reconstruct that from SYNC/STATE/COND_TRUE plus an implied-opcode table
// and a branch fall-through side channel, and got it wrong for not-taken
// branches (BRA0 -> DECODE never asserts SYNC), which left the $E266 stream
// player executing encrypted bytes and the AYs effectively silent.
//
// What remains is the DI pipeline register. Arlet's AB is combinational and
// depends on DIMUX (states ABS1 / INDY0 / ABSX2 ...), so feeding a
// combinational memory straight back into DI is a real loop. Registering DI for
// one cen breaks it; the main CPU does the same thing inside CPU16. The hold
// across BRA0/REG/PUSH/PULL keeps the branch offset presented to the ALU for
// the whole of BRA0.
//============================================================================

module acpu(
  input         clk_sys,
  input         reset,
  input         irq_n,
  input         nmi_n,
  input         ready,
  output [15:0] cpu_ab,
  input  [7:0]  cpu_din,
  output [7:0]  cpu_dout,
  output        rw,
  output        sync
);

wire cen_15;
clk_en #(31) cpu_clk_en(clk_sys, cen_15);

wire [7:0]  dout;
wire [15:0] addr;
wire        sync_i;
wire        rw_i;
wire [5:0]  state_i;

assign sync     = sync_i;
assign cpu_ab   = addr;
assign cpu_dout = dout;
assign rw       = rw_i;

// Arlet's core is written for SYNCHRONOUS memory: AB is combinational and the
// states that consume DIMUX in AB (ABS1, INDY0, ABSX2, ...) expect DI to be the
// byte addressed in the PREVIOUS cycle. One plain register gives exactly that,
// DI(t) = mem[AB(t-1)], and breaks the AB -> mem -> DI -> AB loop.
//
// It used to be held across BRA0/REG/PUSH/PULL. That hold was part of the old
// decrypt hack (di_raw doubled as the bitswap source) and it corrupted the
// normal fetch pipeline: holding through REG meant the DECODE after an implied
// instruction such as DEX read a stale byte, which is why the reset clear loop
// at $E021 never terminated.
reg [7:0] din;

always @(posedge cen_15 or posedge reset) begin
  if (reset)
    din <= 8'h00;
  else
    din <= cpu_din;
end

wire m6502_we;
assign rw_i = ~m6502_we;

cpu6502 M6502(
  .clk       ( cen_15    ),
  .reset     ( reset     ),
  .AB        ( addr      ),
  .DI        ( din       ),
  .DO        ( dout      ),
  .WE        ( m6502_we  ),
  .IRQ       ( ~irq_n    ),
  .NMI       ( ~nmi_n    ),
  .RDY       ( ready     ),
  .SYNC      ( sync_i    ),
  .STATE     ( state_i   ),
  .COND_TRUE (           ),
  .DECRYPT   ( 1'b1      ),   // DECO222 opcode bitswap on the IR path
  .IRQ_ACK   (           )
);

endmodule
