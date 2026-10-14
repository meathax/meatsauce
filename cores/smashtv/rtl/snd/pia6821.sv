// -----------------------------------------------------------------------------
// pia6821.sv
//
// Motorola MC6821 Peripheral Interface Adapter, the glue between the sound
// 6809, the YM2151, the DAC, and the host command latch on the Williams CVSD
// board. Functional model covering the paths this board actually uses
// (williamssound.cpp device_add_mconfig):
//
//   port A out -> MC1408 DAC        (pa_out)
//   port B out -> talkback latch    (pb_out)
//   CA2 out    -> YM2151 /RESET     (ca2_out, manual output mode)
//   CA1 in     <- YM2151 IRQ (inv)  -> IRQA -> 6809 /FIRQ  (irqa)
//   CB1 in     <- host cmd strobe   -> IRQB -> 6809 /NMI   (irqb)
//   CB2 in     <- host cmd bit 9
//   port B in  <- host command byte (pb_in), read by the 6809
//
// Register model per the MC6821 datasheet: RS1:RS0 select {PORTA/DDRA, CRA,
// PORTB/DDRB, CRB}; CRx bit2 swaps the port/DDR at offset 0/2. Reading a port
// clears that side's IRQ flags (CRx bits 7,6). IRQ line = (flag7 & en1) |
// (flag6 & en2). Access is presented one E-cycle at a time via `en`.
// -----------------------------------------------------------------------------

`default_nettype none
module pia6821 (
  input  wire       clk,
  input  wire       rst,

  // 6809 bus (one access per asserted `en`; reads take effect this cycle)
  input  wire       en,          // this E-cycle addresses the PIA
  input  wire       we,          // 1 = write, 0 = read
  input  wire [1:0] addr,        // {RS1, RS0}
  input  wire [7:0] din,
  output reg  [7:0] dout,

  // peripheral inputs
  input  wire [7:0] pa_in,
  input  wire [7:0] pb_in,
  input  wire       ca1,
  input  wire       cb1,
  input  wire       cb2,

  // peripheral outputs
  output wire [7:0] pa_out,
  output wire [7:0] pb_out,
  output wire       ca2_out,
  output reg        irqa,        // -> 6809 /FIRQ (active high here)
  output reg        irqb         // -> 6809 /NMI
);
  reg [7:0] ola, olb, ddra, ddrb, cra, crb;
  reg       ca1_p, cb1_p, cb2_p, ca2_in_p;

  assign pa_out  = ola;   // DDRA bits that are outputs; talkback/DAC read OLA
  assign pb_out  = olb;
  assign ca2_out = cra[3];  // manual output mode (CRA5=1,CRA4=1): CA2 = CRA3

  // read data (combinational)
  always @* begin
    dout = 8'h00;
    case (addr)
      2'b00: dout = cra[2] ? ((ola & ddra) | (pa_in & ~ddra)) : ddra; // PORTA / DDRA
      2'b01: dout = cra;
      2'b10: dout = crb[2] ? ((olb & ddrb) | (pb_in & ~ddrb)) : ddrb; // PORTB / DDRB
      2'b11: dout = crb;
    endcase
  end

  // active-edge test for C*1/C*2 given the control-reg edge-select bit
  function automatic logic edge_active(input logic prev, input logic cur, input logic rising_sel);
    edge_active = rising_sel ? (~prev & cur) : (prev & ~cur);
  endfunction

  always_ff @(posedge clk) begin
    if (rst) begin
      ola<=0; olb<=0; ddra<=0; ddrb<=0; cra<=0; crb<=0;
      ca1_p<=0; cb1_p<=0; cb2_p<=0; ca2_in_p<=0; irqa<=0; irqb<=0;
    end else begin
      ca1_p <= ca1; cb1_p <= cb1; cb2_p <= cb2;

      // --- control-line interrupt flags -------------------------------------
      // CA1 -> CRA7
      if (edge_active(ca1_p, ca1, cra[1])) cra[7] <= 1'b1;
      // CB1 -> CRB7
      if (edge_active(cb1_p, cb1, crb[1])) crb[7] <= 1'b1;
      // CB2 as input (CRB5=0) -> CRB6
      if (!crb[5] && edge_active(cb2_p, cb2, crb[4])) crb[6] <= 1'b1;

      // --- 6809 access -------------------------------------------------------
      if (en) begin
        if (we) begin
          case (addr)
            2'b00: if (cra[2]) ola  <= din; else ddra <= din;
            2'b01: cra <= {cra[7:6], din[5:0]};   // flags 7,6 are read-only
            2'b10: if (crb[2]) olb  <= din; else ddrb <= din;
            2'b11: crb <= {crb[7:6], din[5:0]};
          endcase
        end else begin
          // reading a port clears that side's IRQ flags
          if (addr == 2'b00 && cra[2]) cra[7:6] <= 2'b00;
          if (addr == 2'b10 && crb[2]) crb[7:6] <= 2'b00;
        end
      end

      // --- IRQ outputs -------------------------------------------------------
      irqa <= (cra[7] & cra[0]) | (cra[6] & cra[3] & ~cra[5]);
      irqb <= (crb[7] & crb[0]) | (crb[6] & crb[3] & ~crb[5]);
    end
  end
endmodule
`default_nettype wire
