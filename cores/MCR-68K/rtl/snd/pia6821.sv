// -----------------------------------------------------------------------------
// pia6821.sv
//
// Motorola MC6821 Peripheral Interface Adapter used by the Xenophobe
// "Sounds Good" board.  This is the SystemVerilog port of the generic PIA
// register/edge model originally reused from the narc core, audited against
// MiSTer's MCR3Mono PIA donor (rtl/pia6821.vhd).  Xenophobe uses only:
//
//   port A out -> AD7533 DAC bits 9:2 (pa_out)
//   port B out -> DAC bits 1:0/status outputs (pb_out)
//   port B in  <- command nibble on PB3:0 (pb_in)
//   CA1 in     <- inverted main-board command strobe -> IRQA
//   CB1/CB2 have no board connection.  CA2 is physically routed into the
//   Sounds Good remote-volume/MC3340 control network; this module exposes the
//   PIA output level, while the analogue load is intentionally modelled outside
//   the digital PIA until its transfer function is derived from the schematic.
//
// Register model per the MC6821 datasheet and the donor: RS1:RS0 select
// {PORTA/DDRA, CRA, PORTB/DDRB, CRB}; CRx bit2 swaps the port/DDR at offset
// 0/2. Reading a selected data port clears that side's IRQ flags (CRx bits
// 7,6), except that an input edge detected on the same clock wins over the
// read-clear, matching the donor's edge-process priority. IRQ lines are
// combinational from the latched flags and enables. Access is presented one
// E-cycle at a time via `en`.
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
  output wire       irqa,        // -> sound 68000 IPL4 source, active high
  output wire       irqb         // -> sound 68000 IPL4 source, active high
);
  reg [7:0] ola, olb, ddra, ddrb, cra, crb;
  reg       ca1_p, cb1_p, cb2_p;
  // `en` rising-edge one-shot.  The module contract is ONE access per asserted
  // `en`, but rtl/snd/sounds_good.sv drives `en` from a combinational chip
  // select that stays high for the whole 68000 bus phase (~10 clk at 50 MHz).
  // Re-executing the access branch on every clk of that window is NOT benign
  // for the read-clear below: a CA1 active edge arriving on clk N of a PORTA
  // read sets cra[7] (the edge process wins on that clk via the edge_active
  // guard), and clk N+1 then re-runs the read-clear with no coincident edge
  // and wipes it -- IRQA never rises and the main board's sound command is
  // lost.  Xenophobe strobes are 12.688 us apart and each ISR pass performs
  // two PORTA reads, so the alignment does occur.  Qualifying the branch with
  // the rising edge makes the held level behave as the contract states.
  // No-op for rtl/snd/williams_bg/williams_bg.sv, which already drives
  // `en = pia_cs & cpu_ce` where cpu_ce is provably never asserted on two
  // adjacent clk (its ce_holdoff term exists to coalesce exactly that case).
  // Audit 2026-09-11 finding SND-01.
  reg       en_q;

  assign pa_out  = ola;   // DDRA bits that are outputs; talkback/DAC read OLA
  // Port B output pins are masked by DDRB.  MC6821 port B has true tri-state
  // drivers: a bit configured as an input (DDRB=0) is NOT driven from the
  // output latch.  MAME models this in pia6821_device::get_out_b_value()
  // (src/devices/machine/6821pia.cpp:323-330):
  //
  //     uint8_t ret = m_out_b & m_ddr_b;
  //     if (m_ddr_b != 0xff && !m_ts_b_handler.isunset())
  //         ret |= m_ts_b_handler() & ~m_ddr_b;
  //
  // and that value -- not the raw latch -- is what send_to_out_b_func()
  // (6821pia.cpp:633-641) hands to the board's port-B write handler.  No
  // MCR-68k board binds a three-state (`ts_b`) handler, so the second term is
  // absent here and the plain DDRB mask is exact for this core.
  //
  // NOTE the deliberate asymmetry with the READ path below: a CPU read of
  // port B (6821pia.cpp:254-289) returns `(m_out_b & m_ddr_b) | (port_b_data
  // & ~m_ddr_b)` -- i.e. input-configured bits read back the PIN, not zero.
  // The two behaviours genuinely differ and the dout mux already implements
  // the read side correctly; do not "unify" them.
  //
  // pa_out is deliberately left unmasked: MAME's get_out_a_value()
  // (6821pia.cpp:304-312) applies the analogous DDRA mask, but changing it is
  // outside this task's scope and is moot on every board in this core
  // (DDRA = $FF on Sounds Good and Williams S11/S11C).
  // Recorded in doc/rtl_pia6821_ddrb.md rather than silently changed.
  assign pb_out  = olb & ddrb;
  // CA2's manual-output level is the CRA3 latch bit.  The current board users
  // configure CA2 in manual output mode; the signal is now exported so the
  // schematic-proven Sounds Good analogue control path can be observed.  Full
  // strobe/handshake mode timing remains a separate MC6821 contract item.
  assign ca2_out = cra[3];
  // Match the donor's pia_irq process: the interrupt output reflects the
  // current flags immediately after a register update, with no extra
  // clock of latency on assertion or read-clear.
  assign irqa = (cra[7] & cra[0]) | (cra[6] & cra[3] & ~cra[5]);
  assign irqb = (crb[7] & crb[0]) | (crb[6] & crb[3] & ~crb[5]);

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
    // Track `en` in and out of reset so a level that was already high when rst
    // releases cannot be seen as a fresh access edge.
    en_q <= en;
    if (rst) begin
      ola<=0; olb<=0; ddra<=0; ddrb<=0; cra<=0; crb<=0;
      ca1_p<=0; cb1_p<=0; cb2_p<=0;
    end else begin
      ca1_p <= ca1; cb1_p <= cb1; cb2_p <= cb2;

      // --- control-line interrupt flags -------------------------------------
      // CA1 -> CRA7
      if (edge_active(ca1_p, ca1, cra[1])) cra[7] <= 1'b1;
      // CB1 -> CRB7
      if (edge_active(cb1_p, cb1, crb[1])) crb[7] <= 1'b1;
      // CB2 as input (CRB5=0) -> CRB6
      if (!crb[5] && edge_active(cb2_p, cb2, crb[4])) crb[6] <= 1'b1;

      // --- bus access --------------------------------------------------------
      // One access per `en` assertion -- see the en_q declaration above.
      if (en & ~en_q) begin
        if (we) begin
          case (addr)
            2'b00: if (cra[2]) ola  <= din; else ddra <= din;
            2'b01: cra <= {cra[7:6], din[5:0]};   // flags 7,6 are read-only
            2'b10: if (crb[2]) olb  <= din; else ddrb <= din;
            2'b11: crb <= {crb[7:6], din[5:0]};
          endcase
        end else begin
          // Reading a data port clears that side's IRQ flags.  The donor's
          // edge process gives a simultaneous newly-detected edge priority
          // over this clear, so preserve a flag for that edge.
          if (addr == 2'b00 && cra[2]) begin
            if (!edge_active(ca1_p, ca1, cra[1])) cra[7] <= 1'b0;
            // CA2 input-side IRQ state is not used by the supported board
            // wiring; CA2's output level is exported separately.
          end
          if (addr == 2'b10 && crb[2]) begin
            if (!edge_active(cb1_p, cb1, crb[1])) crb[7] <= 1'b0;
            if (!(!crb[5] && edge_active(cb2_p, cb2, crb[4]))) crb[6] <= 1'b0;
          end
        end
      end
    end
  end
endmodule
`default_nettype wire
