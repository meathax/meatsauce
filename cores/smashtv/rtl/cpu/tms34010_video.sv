// -----------------------------------------------------------------------------
// tms34010_video.sv
//
// Video timing generator for the TMS34010 (1988 User's Guide §"Video Timing",
// the HESYNC/HEBLNK/HSBLNK/HTOTAL and V* registers). Free-running horizontal
// and vertical counters driven by the video clock (VCLK) produce HSYNC/VSYNC
// and the blanking signal, plus a display-interrupt strobe.
//
//   HCOUNT increments every clock; when HCOUNT == HTOTAL it wraps to 0 and the
//   horizontal sync interval restarts. On each HCOUNT wrap, VCOUNT increments;
//   when VCOUNT == VTOTAL it wraps to 0 (a new frame).
//
//   HSYNC is asserted while HCOUNT < HESYNC (the sync interval that begins at
//   the HTOTAL wrap). HBLANK is asserted while HCOUNT < HEBLNK (the leading
//   blank, including the sync interval) or HCOUNT >= HSBLNK (the trailing
//   blank); the visible region is HEBLNK..HSBLNK. The vertical signals are the
//   analogous compares on VCOUNT. BLANK is asserted when either axis is
//   blanking. DPYINT_PULSE is a one-clock strobe at the start of the scan line
//   whose number equals DPYINT (the display-interrupt line).
//
// Scope (Task 0097 — standalone): a clean, synthesizable timing block, tested
// directly (not yet wired to the core's I/O registers or a real pixel clock).
// The spec resets HCOUNT on the VCLK FALLING edge; this synchronous design
// uses the rising edge throughout (assumption A0003 reset/clock style).
//
// Spec source:
//   third_party/TMS34010_Info/docs/ti-official/1988_TI_TMS34010_Users_Guide.pdf
//   §"Video Timing"; HESYNC page 5-?, HEBLNK page 5-?.
// -----------------------------------------------------------------------------

`default_nettype none
module tms34010_video
  import tms34010_pkg::*;
(
  input  logic        clk,        // VCLK (video / pixel clock)
  input  logic        rst,

  // Horizontal timing registers.
  input  logic [15:0] hesync,     // end of horizontal sync
  input  logic [15:0] heblnk,     // end of horizontal blank (display starts)
  input  logic [15:0] hsblnk,     // start of horizontal blank
  input  logic [15:0] htotal,     // total - 1 line length (HCOUNT wrap)
  // Vertical timing registers.
  input  logic [15:0] vesync,     // end of vertical sync
  input  logic [15:0] veblnk,     // end of vertical blank
  input  logic [15:0] vsblnk,     // start of vertical blank
  input  logic [15:0] vtotal,     // total - frame length (VCOUNT wrap)
  // Display-interrupt scan line.
  input  logic [15:0] dpyint,

  output logic [15:0] hcount,
  output logic [15:0] vcount,
  output logic        hsync,      // 1 = within the horizontal sync interval
  output logic        vsync,      // 1 = within the vertical sync interval
  output logic        hblank,     // 1 = horizontal blanking
  output logic        vblank,     // 1 = vertical blanking
  output logic        blank,      // 1 = blanked (either axis)
  output logic        dpyint_pulse// one-clock strobe at the DPYINT scan line start
);

  logic hwrap;
  assign hwrap = (hcount == htotal);

  always_ff @(posedge clk) begin
    if (rst) begin
      hcount <= 16'd0;
      vcount <= 16'd0;
    end else begin
      if (hwrap) begin
        hcount <= 16'd0;
        if (vcount == vtotal) begin
          vcount <= 16'd0;
        end else begin
          vcount <= vcount + 16'd1;
        end
      end else begin
        hcount <= hcount + 16'd1;
      end
    end
  end

  // Sync / blank window compares (combinational).
  assign hsync  = (hcount < hesync);
  assign vsync  = (vcount < vesync);
  assign hblank = (hcount < heblnk) || (hcount >= hsblnk);
  assign vblank = (vcount < veblnk) || (vcount >= vsblnk);
  assign blank  = hblank || vblank;

  // Display interrupt: a one-clock strobe at the start of the scan line whose
  // number equals DPYINT. HCOUNT == 0 holds for exactly one clock per line, so
  // (HCOUNT==0 && VCOUNT==DPYINT) is high for one clock at that line's start.
  assign dpyint_pulse = (hcount == 16'd0) && (vcount == dpyint);

endmodule : tms34010_video

`default_nettype wire
