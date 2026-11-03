`default_nettype none

// S.T.U.N. Runner output retimer.
//
// The scanout runs on the 48 MHz GSP clock, but the 5 MHz VCLK raster has a
// 10 MHz dot clock: 4.8 clocks per pixel. Its enable cadence is 5,5,5,5,4 and
// every line is re-phased to the synchronized TMS HBLANK edge, so pixel widths,
// line lengths (3043/3044 clocks) and HSYNC periods vary from line to line.
// Line-locked scalers and direct video see that as a constantly wobbling
// picture. This stage re-emits the same picture on a fixed raster in an exact
// 40 MHz clock from the same PLL: 4 clocks per pixel, 2536 clocks per line
// (= 317 VCLK), 262 lines per frame, so the output period equals the TMS
// frame and never drifts. Only active pixels cross the FIFO; the raster,
// syncs and blanking are generated here with the scanout's constants.
//
// Lock: while unlocked the raster free-runs (black) and the FIFO drains up to
// the first pixel of a frame; once START_LEVEL pixels are queued the raster
// restarts at that pixel. Each popped pixel's frame/line-start tags must
// match the raster position, otherwise the stage unlocks and re-locks at the
// next frame (source reset or reprogrammed timing).
module harddrivin_video_retimer #(
  parameter int CLKS_PER_PIX = 4,
  parameter int H_TOTAL      = 634,
  parameter int H_ACTIVE     = 512,
  parameter int HS_START     = 536,
  parameter int HS_END       = 584,
  parameter int V_TOTAL      = 262,
  parameter int V_ACTIVE     = 240,
  parameter int VS_START     = 243,
  parameter int VS_END       = 247,
  parameter int AW           = 4,
  parameter int START_LEVEL  = 8
) (
  input  logic        in_clk_i,
  input  logic        in_ce_i,
  input  logic        in_hblank_i,
  input  logic        in_vblank_i,
  input  logic [23:0] in_rgb_i,

  input  logic        out_clk_i,
  output logic        ce_pix_o,
  output logic        hblank_o,
  output logic        vblank_o,
  output logic        hsync_o,
  output logic        vsync_o,
  output logic [23:0] rgb_o,
  output logic        locked_o
);
  localparam int DEPTH = 1 << AW;
  localparam int DW = $clog2(CLKS_PER_PIX);

  function automatic logic [AW:0] bin2gray(input logic [AW:0] b);
    return b ^ (b >> 1);
  endfunction
  function automatic logic [AW:0] gray2bin(input logic [AW:0] g);
    logic [AW:0] b;
    b[AW] = g[AW];
    for (int i = AW - 1; i >= 0; i--) b[i] = b[i + 1] ^ g[i];
    return b;
  endfunction

  // {first pixel of frame, first pixel of line, rgb}
  (* ramstyle = "logic" *) logic [25:0] mem_q [DEPTH];
  logic [AW:0] wbin_q = '0, wgray_q = '0;
  logic [AW:0] rbin_q = '0, rgray_q = '0;
  logic [AW:0] rgray_in, wgray_out;

  for (genvar i = 0; i <= AW; i++) begin : g_ptr_sync
    tms34010_sync_bit u_r2w (.clk(in_clk_i),  .rst(1'b0), .async_i(rgray_q[i]), .sync_o(rgray_in[i]));
    tms34010_sync_bit u_w2r (.clk(out_clk_i), .rst(1'b0), .async_i(wgray_q[i]), .sync_o(wgray_out[i]));
  end

  // Write side: queue active pixels in order.
  logic sof_pend_q = 1'b1, sol_pend_q = 1'b1;
  wire in_active = in_ce_i && !in_hblank_i && !in_vblank_i;
  wire in_full = (wbin_q - gray2bin(rgray_in)) == (AW + 1)'(DEPTH);

  always_ff @(posedge in_clk_i) begin
    if (in_ce_i && in_vblank_i) sof_pend_q <= 1'b1;
    if (in_ce_i && in_hblank_i) sol_pend_q <= 1'b1;
    if (in_active) begin
      sof_pend_q <= 1'b0;
      sol_pend_q <= 1'b0;
      if (!in_full) begin
        mem_q[wbin_q[AW-1:0]] <= {sof_pend_q, sol_pend_q, in_rgb_i};
        wbin_q  <= wbin_q + 1'b1;
        wgray_q <= bin2gray(wbin_q + 1'b1);
      end
    end
  end

  // Read side: fixed raster.
  logic [DW-1:0] div_q = '0;
  logic [9:0] h_q = '0;
  logic [8:0] v_q = '0;
  logic locked_q = 1'b0;
  logic ce_q = 1'b0, hblank_q = 1'b1, vblank_q = 1'b1, hsync_q = 1'b0, vsync_q = 1'b0;
  logic [23:0] rgb_q = 24'd0;

  wire [AW:0]  level    = gray2bin(wgray_out) - rbin_q;
  wire         empty    = level == '0;
  wire [25:0]  head     = mem_q[rbin_q[AW-1:0]];
  wire         lock_now = !locked_q && !empty && head[25] &&
                          level >= (AW + 1)'(START_LEVEL);
  wire         emit     = (div_q == '0) || lock_now;
  wire [9:0]   h_cur    = lock_now ? 10'd0 : h_q;
  wire [8:0]   v_cur    = lock_now ? 9'd0 : v_q;
  wire         active   = (h_cur < H_ACTIVE) && (v_cur < V_ACTIVE);
  wire         take     = emit && active && (locked_q || lock_now);
  wire         tags_ok  = head[25] == (h_cur == 0 && v_cur == 0) &&
                          head[24] == (h_cur == 0);
  wire         good     = take && !empty && tags_ok;
  // Unlocked: discard up to the next frame start and keep that pixel.
  wire         drain    = !locked_q && !lock_now && !empty && !head[25];
  wire         pop      = good || drain;

  assign {ce_pix_o, hblank_o, vblank_o, hsync_o, vsync_o, rgb_o, locked_o} =
         {ce_q, hblank_q, vblank_q, hsync_q, vsync_q, rgb_q, locked_q};

  always_ff @(posedge out_clk_i) begin
    ce_q <= 1'b0;
    div_q <= (div_q == DW'(CLKS_PER_PIX - 1)) ? '0 : div_q + 1'b1;
    if (lock_now) div_q <= DW'(1);
    if (pop) begin
      rbin_q  <= rbin_q + 1'b1;
      rgray_q <= bin2gray(rbin_q + 1'b1);
    end
    if (lock_now) locked_q <= 1'b1;
    else if (take && !good) locked_q <= 1'b0;
    if (emit) begin
      ce_q     <= 1'b1;
      hblank_q <= h_cur >= H_ACTIVE;
      vblank_q <= v_cur >= V_ACTIVE;
      hsync_q  <= h_cur >= HS_START && h_cur < HS_END;
      vsync_q  <= v_cur >= VS_START && v_cur < VS_END;
      rgb_q    <= good ? head[23:0] : 24'd0;
      if (h_cur == 10'(H_TOTAL - 1)) begin
        h_q <= 10'd0;
        v_q <= (v_cur == 9'(V_TOTAL - 1)) ? 9'd0 : v_cur + 9'd1;
      end else begin
        h_q <= h_cur + 10'd1;
        v_q <= v_cur;
      end
    end
  end
endmodule

`default_nettype wire
