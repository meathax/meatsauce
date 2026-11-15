// SPDX-License-Identifier: GPL-3.0-or-later
// Runtime family PLL selection for the one SNK_TripleZ80 RBF (user clock rule: clk_sys = CLK_VIDEO = N x PCB pixel).
// The downloaded profile names its board crystal family; this block rewrites only the game PLL fractional K
// (sys/pll_cfg Avalon register 7, then start register 2), the same runtime pattern as the MiSTer Jackal/Genesis cores:
//   want_early=0  K_LATE  -> 96.0 MHz (16 MHz-crystal boards, 8 MHz pixel /12)          power-up default
//   want_early=1  K_EARLY -> 93.8 MHz (13.4 MHz-crystal boards, 6.7 MHz pixel /14 = 13.4 MHz /7)
// switching (clk_sys) is high from the first clock the request differs from the programmed family until the PLL has
// been rewritten, has relocked and stayed locked for SETTLE management clocks. The root ORs it into ioctl_wait, the
// game/bridge reset and the SDRAM init, so no ROM byte, SDRAM command or game enable is issued across the relock.
// The request is taken at the profile header (ioctl index 1), before the first index-0 ROM byte reaches SDRAM.
module snk_pll_mode #(
 parameter [31:0] K_LATE=32'd2576980378,  // 9.6  x 50 MHz = 480 MHz VCO /5 = 96.0 MHz
 parameter [31:0] K_EARLY=32'd1632087572, // 9.38 x 50 MHz = 469 MHz VCO /5 = 93.8 MHz
 parameter integer SETTLE=1023
)(
 input wire clk_sys,          // game PLL outclk_0 (may stop or glitch while relocking)
 input wire pll_locked,       // game PLL lock (asynchronous)
 input wire want_early,       // clk_sys: family requested by the active profile
 output reg switching=1'b1,   // clk_sys: hold downloads, SDRAM and game while not settled on the requested family (high from configuration)
 input wire mgmt_clk,         // CLK_50M: free-running pll_cfg management clock
 input wire cfg_waitrequest,
 output reg cfg_write=1'b0,
 output reg [5:0] cfg_address=6'd0,
 output reg [31:0] cfg_data=32'd0,
 output reg mgmt_early=1'b0   // mgmt_clk: family currently programmed (settled)
);
 // clk_sys -> mgmt_clk: one quasi-static level (two-flop synchronizer; first stage cut in the SDC).
 reg req_sys=1'b0;
 always @(posedge clk_sys) req_sys<=want_early;
 (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED" *) reg [1:0] req_m=2'b00;
 (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED" *) reg [1:0] lock_m=2'b00;
 always @(posedge mgmt_clk) begin req_m<={req_m[0],req_sys}; lock_m<={lock_m[0],pll_locked}; end

 localparam [2:0] IDLE=3'd0,MODE=3'd1,KREG=3'd2,START=3'd3,LOCK=3'd4;
 reg [2:0] st=IDLE;
 reg target=1'b0,busy_m=1'b0;
 reg [10:0] settle=11'd0;
 wire accepted=cfg_write&&!cfg_waitrequest;
 always @(posedge mgmt_clk) begin
  if(accepted) cfg_write<=1'b0;
  case(st)
   IDLE: if(req_m[1]!=mgmt_early&&!cfg_write&&!cfg_waitrequest) begin
    target<=req_m[1];busy_m<=1'b1;
    cfg_address<=6'd0;cfg_data<=32'd0;cfg_write<=1'b1;        // waitrequest mode
    st<=MODE;
   end
   MODE: if(accepted) begin
    cfg_address<=6'd7;cfg_data<=target?K_EARLY:K_LATE;cfg_write<=1'b1;   // fractional K
    st<=KREG;
   end
   KREG: if(accepted) begin
    cfg_address<=6'd2;cfg_data<=32'd0;cfg_write<=1'b1;          // start reconfiguration
    st<=START;settle<=11'd0;
   end
   START: if(accepted) st<=LOCK;
   LOCK: begin
    // pll_cfg (WAIT_FOR_LOCK=1) holds waitrequest until the PLL relocks; then require a stable lock.
    if(cfg_waitrequest||!lock_m[1]) settle<=11'd0;
    else if(settle!=SETTLE[10:0]) settle<=settle+11'd1;
    else begin mgmt_early<=target;busy_m<=1'b0;st<=IDLE; end
   end
   default: st<=IDLE;
  endcase
 end

 // mgmt_clk -> clk_sys: settled family and busy flag (levels), plus the PLL lock.
 (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED" *) reg [1:0] early_s=2'b00;
 (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED" *) reg [1:0] busy_s=2'b00;
 (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED" *) reg [1:0] lock_s=2'b00;
 always @(posedge clk_sys) begin
  early_s<={early_s[0],mgmt_early};busy_s<={busy_s[0],busy_m};lock_s<={lock_s[0],pll_locked};
  switching<=(req_sys!=early_s[1])||busy_s[1]||!lock_s[1];
 end
endmodule
