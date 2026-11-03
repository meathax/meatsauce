// -----------------------------------------------------------------------------
// tms_display.sv -- per-GSP display-address unit (one instance for the master, one
// for the slave).  Reproduces tms340x0_device::scanline_callback() DPYADR handling
// and get_display_params() of MAME 0.289 (TMS34010 branch):
//
//   at the start of line vn (hpos 0), in this order
//     1. render parameters are derived from the CURRENT (pre-update) DPYADR:
//          dpyadr' = DPYCTL.ORG ? DPYADR : DPYADR ^ 0xFFFC
//          rowaddr = dpyadr' >> 4
//          coladdr = ((dpyadr' & 0x7C) << 4) | (DPYTAP & 0x3FFF)
//          yoffset = (DPYSTRT - DPYADR) & 3
//     2. DPYINT: if DPYCTL.ENB && vn == DPYINT -> dint pulse
//     3. vn == VSBLNK : DPYADR <= DPYSTRT
//     4. VEBLNK <= vn < VSBLNK : DPYADR steps by DUDATE (DPYCTL[9:2]):
//          if (DPYADR&3)==0 : DPYADR = ((DPYADR&~3) - (DPYCTL&0x3FC)) | (DPYSTRT&3)
//          else             : DPYADR = (DPYADR&~3) | ((DPYADR-1)&3)
//   The master callback runs before the slave's in the same line, so the slave
//   parameters used by the master's scanline_update are also pre-update values.
//
// `strobe`/`vn` come from exterm_timing.  Outputs are registers updated on the
// strobe edge (valid for the whole new line).  A CPU write to the DPYADR register
// is not modelled (the contract has no write strobe); see docs/lane2_video.md.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
/* verilator lint_off UNUSEDSIGNAL */
`default_nettype none
module tms_display (
  input  wire        clk,
  input  wire        rst,
  input  wire        strobe,
  input  wire [15:0] vn,
  input  wire [15:0] dpyctl, dpystrt, dpytap, dpyint, veblnk, vsblnk,
  input  wire [15:0] vtotal,       // this GSP's VTOTAL register
  input  wire [15:0] scr_vtotal,   // screen height-1 (master timing, effective)

  output reg  [15:0] dpyadr_live,
  output reg         dint,
  output reg  [11:0] rowaddr,
  output reg  [13:0] coladdr,
  output reg  [1:0]  yoffset,
  output reg         enabled
);
  // MAME scanline_callback arming: the per-line timer chain only reaches line vn if the previous
  // callback saw (vn <= vtotal_eff); line 0 always has a callback (timer restarts each frame).
  // vtotal_eff = master (DPYCTL bit13) ? VTOTAL : min(screen_height-1, VTOTAL).
  wire [15:0] vt_eff = (dpyctl[13] || vtotal <= scr_vtotal) ? vtotal : scr_vtotal;
  reg         armed;
  wire        cb_runs = (vn == 16'd0) || armed;

  wire [15:0] eff = dpyctl[10] ? dpyadr_live : (dpyadr_live ^ 16'hFFFC);

  wire        in_win = (vn >= veblnk) && (vn < vsblnk);
  wire [15:0] ld     = (vn == vsblnk) ? dpystrt : dpyadr_live;
  wire [15:0] dec    = {ld[15:2], 2'b00} - {6'd0, dpyctl[9:2], 2'b00};
  wire [15:0] stepd  = (ld[1:0] == 2'd0) ? {dec[15:2], dpystrt[1:0]}
                                         : {ld[15:2], ld[1:0] - 2'd1};
  wire [15:0] nxt    = in_win ? stepd : ld;

  always_ff @(posedge clk) begin
    dint <= 1'b0;
    if (rst) begin
      dpyadr_live <= 16'd0; armed <= 1'b0;
      rowaddr <= 12'd0; coladdr <= 14'd0; yoffset <= 2'd0; enabled <= 1'b0;
    end else if (strobe) begin
      rowaddr  <= eff[15:4];
      coladdr  <= {3'b000, eff[6:2], 6'b000000} | dpytap[13:0];
      yoffset  <= 2'(dpystrt - dpyadr_live);
      enabled  <= dpyctl[15];
      dint     <= cb_runs && dpyctl[15] && (vn == dpyint);
      armed    <= cb_runs && (vn + 16'd1 <= vt_eff);
      dpyadr_live <= nxt;
    end
  end
endmodule
`default_nettype wire
