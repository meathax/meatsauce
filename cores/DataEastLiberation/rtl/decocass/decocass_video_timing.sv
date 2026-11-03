//============================================================================
// DECO Cassette raster timing
//
// MAME decocass_base: set_raw(HCLK, 384, 0, 256, 272, 8, 248).
// HCLK is 6 MHz, giving 15.625 kHz horizontal and about 57.44 Hz vertical.
// Blanking and sync are combinational from the counters so the first and last
// visible samples are exactly x=0 and x=255; registering these decodes adds an
// unwanted one-pixel displacement before the downstream alignment pipeline.
//============================================================================

module video_timing (
  input  wire       clk_sys,
  input  wire       ce_pix,
  input  wire       reset,
  output reg  [8:0] hcnt,
  output reg  [8:0] vcnt,
  output wire       hblank,
  output wire       vblank,
  output wire       hsync,
  output wire       vsync,
  output wire       vsync_pulse
);

reg reset_d = 1'b0;
always @(posedge clk_sys) reset_d <= reset;
wire raster_restart = reset && !reset_d;

always @(posedge clk_sys) begin
  if (raster_restart) begin
    hcnt <= 9'd0;
    vcnt <= 9'd0;
  end else if (ce_pix) begin
    if (hcnt == 9'd383) begin
      hcnt <= 9'd0;
      vcnt <= (vcnt == 9'd271) ? 9'd0 : (vcnt + 9'd1);
    end else begin
      hcnt <= hcnt + 9'd1;
    end
  end
end

// Exact MAME/PCB visible area: x=0..255, y=8..247.
assign hblank = (hcnt >= 9'd256);
assign vblank = (vcnt < 9'd8) || (vcnt >= 9'd248);

// Preserve the reference core's pulse placement and active-high polarity.
assign hsync = (hcnt >= 9'd280) && (hcnt < 9'd312);
assign vsync = (vcnt >= 9'd252) && (vcnt < 9'd256);
assign vsync_pulse = ce_pix && (hcnt == 9'd383) && (vcnt == 9'd251);

endmodule
