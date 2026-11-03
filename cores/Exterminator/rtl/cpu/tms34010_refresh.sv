// -----------------------------------------------------------------------------
// tms34010_refresh.sv
//
// DRAM-refresh address generator for the TMS34010 (1988 User's Guide §6, the
// REFCNT register and the CONTROL.RR refresh-rate field).
//
// The TMS34010 automatically issues RAS-only DRAM-refresh cycles at a regular
// interval set by CONTROL.RR (bits 4:3):
//   00 = refresh every 32 local clock periods
//   01 = refresh every 64 local clock periods
//   10 = reserved (treated here as "no refresh")
//   11 = no DRAM refreshing
// On each refresh cycle the 8-bit refresh row address (REFCNT, the low byte)
// increments; it counts 0..255 and wraps, sequencing through all DRAM rows.
// REFCNT is 0 at reset.
//
// `refresh_req` is a one-clock strobe marking each refresh cycle; `refresh_row`
// is the current REFCNT row address. The interface to the actual memory
// arbiter (issuing the RAS-only cycle at the highest priority) is a follow-up;
// this is the standalone counter.
//
// Spec source:
//   third_party/TMS34010_Info/docs/ti-official/1988_TI_TMS34010_Users_Guide.pdf
//   §6 (REFCNT, CONTROL.RR), page 6-11.
// -----------------------------------------------------------------------------

`default_nettype none
module tms34010_refresh
  import tms34010_pkg::*;
(
  input  logic       clk,
  input  logic       rst,
  input  logic [1:0] rr,            // CONTROL.RR (bits 4:3)

  output logic [7:0] refresh_row,   // REFCNT row address (ROWADR)
  output logic       refresh_req    // one-clock strobe at each refresh cycle
);

  // Enabled only for RR = 00 (every 32) or 01 (every 64). The prescaler counts
  // up to interval-1 then wraps, so the refresh period is `interval` clocks.
  logic       enabled;
  logic [6:0] interval;             // 31 (=> 32 clocks) or 63 (=> 64 clocks)
  assign enabled  = (rr == 2'b00) || (rr == 2'b01);
  assign interval = (rr == 2'b01) ? 7'd63 : 7'd31;

  logic [6:0] presc_q;
  logic [7:0] refresh_row_q;

  // A refresh cycle occurs when the prescaler reaches the interval.
  assign refresh_req = enabled && (presc_q == interval);
  assign refresh_row = refresh_row_q;

  always_ff @(posedge clk) begin
    if (rst) begin
      presc_q       <= 7'd0;
      refresh_row_q <= 8'd0;
    end else if (enabled) begin
      if (presc_q == interval) begin
        presc_q       <= 7'd0;
        refresh_row_q <= refresh_row_q + 8'd1;   // wraps 255 -> 0
      end else begin
        presc_q <= presc_q + 7'd1;
      end
    end
    // Disabled (RR = 10 / 11): hold the prescaler and row address.
  end

endmodule : tms34010_refresh

`default_nettype wire
