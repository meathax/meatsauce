// -----------------------------------------------------------------------------
// exterm_timing.sv -- screen timing generator driven by the MASTER GSP registers.
//
// Counters hc (0..HTOTAL) / vc (0..VTOTAL) advance on ce_pix (5 MHz).  They follow
// the live register values (MAME only re-configures the screen at VTOTAL, but the
// registers are static in Exterminator, so no latching is needed).
//
// `line_start` is a combinational strobe that is true in the clk cycle whose ending
// edge advances to the first pixel of a new line (ce_pix && hc>=HTOTAL); `vn` is the
// number of that new line.  tms_display uses it to emulate MAME's per-scanline
// scanline_callback (VCOUNT update, DPYINT, DPYADR load / decrement, render params).
//
// After reset hc/vc sit on the last pixel of the frame so the first ce_pix wraps to
// line 0 and fires the line-0 strobe (MAME's scantimer is armed at time 0).
//
// Sync polarity: active-high pulses.  HSYNC = hc <  HESYNC,  VSYNC = vc <  VESYNC
// (register = END of the sync pulse, counter starts at 0).  hblank = outside
// [HEBLNK,HSBLNK), vblank = outside [VEBLNK,VSBLNK).
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
/* verilator lint_off UNUSEDSIGNAL */
`default_nettype none
module exterm_timing (
  input  wire        clk,
  input  wire        rst,
  input  wire        ce_pix,
  input  wire [15:0] hesync, heblnk, hsblnk, htotal,
  input  wire [15:0] vesync, veblnk, vsblnk, vtotal,

  output reg  [15:0] hc,          // current pixel column  (0..HTOTAL)
  output reg  [15:0] vc,          // current line          (0..VTOTAL)
  output wire        line_start,  // strobe: next ce_pix edge starts line `vn`
  output wire [15:0] vn,          // number of the line that starts at line_start
  output wire [15:0] hcount_o,    // GSP HCOUNT register read-back (MAME semantics)
  output wire [15:0] vcount_o,    // GSP VCOUNT register read-back
  output wire        hs, vs,      // unregistered flags for the pixel at (hc,vc)
  output wire        hblank, vblank
);
  wire h_last = (hc >= htotal);
  wire v_last = (vc >= vtotal);

  assign line_start = ce_pix && h_last;
  assign vn         = v_last ? 16'd0 : vc + 16'd1;

  always_ff @(posedge clk) begin
    if (rst) begin
      hc <= 16'hFFFF;            // wraps (>= htotal) at the first ce_pix
      vc <= 16'hFFFF;
    end else if (ce_pix) begin
      if (h_last) begin
        hc <= 16'd0;
        vc <= vn;
      end else begin
        hc <= hc + 16'd1;
      end
    end
  end

  assign hs     = (hc < hesync);
  assign vs     = (vc < vesync);
  assign hblank = !((hc >= heblnk) && (hc < hsblnk));
  assign vblank = !((vc >= veblnk) && (vc < vsblnk));

  // MAME io_register_r(HCOUNT): hpos + HEBLNK, minus (HTOTAL+1) when it exceeds HTOTAL+1.
  wire [16:0] hsum = {1'b0, hc} + {1'b0, heblnk};
  wire [16:0] htot = {1'b0, htotal} + 17'd1;
  assign hcount_o = (hsum > htot) ? 16'(hsum - htot) : hsum[15:0];
  assign vcount_o = vc;
endmodule
`default_nettype wire
