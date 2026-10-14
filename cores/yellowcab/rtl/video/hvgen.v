//============================================================================
// Yellow Cab raster generator
//
// MAME liberate_base: set_size(32*8, 32*8), set_visarea(0, 255, 8, 247).
// 6 MHz dot clock (48 MHz / 8), 384 dots x 263 lines => 15.625 kHz / 59.41 Hz.
//
// Blanking/sync are COMBINATIONAL from the counters. The pixel data path in
// video.sv is also combinational from hcount/vcount, so registering the blank
// edges (as this module used to) landed them one pixel/line late and shifted
// the visible window to h=1..256 -- the first visible column was fx=1 and the
// last was fx=0 (wrapped).
//============================================================================

module hvgen(
  input             clk_sys,
  input             reset,
  output            hb, vb, hs, vs,
  output reg [8:0]  hcount, vcount,
  output reg  [2:0] dot,     // 0..7 phase within the pixel (fetch scheduling)
  output reg        ce_pix
);

localparam [8:0] H_TOTAL   = 9'd384;
localparam [8:0] H_ACTIVE  = 9'd256;   // visarea x 0..255
localparam [8:0] H_SYNC_S  = 9'd308;
localparam [8:0] H_SYNC_E  = 9'd340;

localparam [8:0] V_TOTAL   = 9'd263;
localparam [8:0] V_ACT_S   = 9'd8;     // visarea y 8..247
localparam [8:0] V_ACT_E   = 9'd248;
localparam [8:0] V_SYNC_S  = 9'd249;
localparam [8:0] V_SYNC_E  = 9'd252;

// 48 MHz / 8 = 6 MHz dot clock. `dot` is the phase inside one pixel; video.sv
// uses it to sequence its BRAM fetches (all memories are synchronous-read now,
// so each pixel gets an 8-cycle fetch window).
wire cen_6 = (dot == 3'd7);

always @(posedge clk_sys) begin
  if (reset) begin
    hcount <= 9'd0;
    vcount <= 9'd0;
    dot    <= 3'd0;
    ce_pix <= 1'b0;
  end else begin
    dot    <= dot + 3'd1;
    ce_pix <= (dot == 3'd6);   // RGB is latched at dot 6, sampled during dot 7
    if (cen_6) begin
      if (hcount == H_TOTAL - 9'd1) begin
        hcount <= 9'd0;
        vcount <= (vcount == V_TOTAL - 9'd1) ? 9'd0 : (vcount + 9'd1);
      end else begin
        hcount <= hcount + 9'd1;
      end
    end
  end
end

assign hb = (hcount >= H_ACTIVE);
assign vb = (vcount <  V_ACT_S) || (vcount >= V_ACT_E);

// Active-low sync, as before. arcade_video's sync_fix normalises polarity.
assign hs = ~((hcount >= H_SYNC_S) && (hcount < H_SYNC_E));
assign vs = ~((vcount >= V_SYNC_S) && (vcount < V_SYNC_E));

endmodule
