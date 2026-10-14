//============================================================================
//  Multi32 splitscreen composer: places screen A and screen B side by side
//  in one output raster, so both simultaneous player views can be shown at
//  once instead of the single-screen A/B OSD toggle.
//
//  mix0/mix1 in s32_core already render both screens in full every frame,
//  pixel-locked to the same native hcnt/vcnt (see s32_core.sv comment at the
//  fb_rd2_* declarations) -- rgb_a(hcnt,vcnt) and rgb_b(hcnt,vcnt) are valid
//  simultaneously for the same screen-space coordinate every native ce_pix
//  tick. This module captures one native line of each into a line buffer,
//  then plays both back on an output-side raster running at exactly 2x the
//  native pixel rate: hdisp_out = 2*hdisp_native active pixels/line (screen A
//  first, screen B second), htotal_out = 2*htotal_native. Vertical timing
//  Vertical blank/sync are delayed by that same one-line latency below, so
//  direct video and the HDMI scaler see DE/sync aligned with the pixels rather
//  than a missing first line and a hidden last line at each frame edge.
//
//  Line buffers are 1-line ping-pong (write the line in progress into
//  `wr_bank`, read the previous, now-complete line from `~wr_bank`) --
//  copied directly from rtl/crt_adjust.sv's own line buffer, which uses the
//  identical bank-flip-on-line-boundary technique for the same reason: the
//  output raster runs faster than the native raster, so reading the SAME
//  bank that is still being written would race ahead of the write pointer
//  mid-line and tear the picture between this line and the previous one.
//
//  Verified in verif/common/tb_splitscreen_composer.sv (registered in
//  run_regression.ps1 as t23_splitscreen_composer): a self-referential
//  stream-shape check confirms, in both 416- and 320-mode, that the output
//  active region is exactly 416 (or 320) screen-A samples in native hcnt
//  order followed by the same for screen B, every line, with line-aligned
//  vblank/vsync. That testbench is also what caught the single-buffer
//  (non-ping-pong) first draft of this module tearing the picture -- the
//  read side, running at 2x the native rate, raced ahead of the write
//  pointer mid-line. Still no MAME/Verilator differential regression on the
//  full core with Splitscreen enabled, and no hardware verification.
//============================================================================

module s32_splitscreen_composer (
    input             clk,             // clk_sys
    input             rst,
    input             mode_416_active,

    // native (single-screen) raster from s32_core, both screens valid
    // together every native ce_pix tick
    input      [23:0] rgb_a, rgb_b,
    input       [8:0] hcnt,
    input             ce_pix_native,
    input             vblank_native,
    input             vsync_native,

    // doubled-width composite raster
    output reg [23:0] rgb_out,
    output            ce_pix_out,
    output reg        hsync_out,
    output reg        vsync_out,
    output reg        hblank_out,
    output reg        vblank_out
);

// -----------------------------------------------------------------------
// per-screen native geometry (mirrors s32_video.sv's own constants)
// -----------------------------------------------------------------------
wire [8:0] hdisp_native  = mode_416_active ? 9'd415 : 9'd319; // last active hcnt
wire [8:0] htotal_native = mode_416_active ? 9'd511 : 9'd409; // last hcnt of line
wire [9:0] hdisp_count   = {1'b0, hdisp_native}  + 10'd1;     // 416 / 320
wire [9:0] htotal_count  = {1'b0, htotal_native} + 10'd1;     // 512 / 410
wire [9:0] hdisp_out     = hdisp_count  << 1;                 // 832 / 640
wire [9:0] htotal_out    = htotal_count << 1;                 // 1024 / 820

// -----------------------------------------------------------------------
// output pixel CE: free-running fractional accumulator at exactly 2x the
// native rate (same accumulator shape as s32_video.sv), resynchronised to
// the native line boundary every line so no per-line rounding drift can
// accumulate across a frame.
// -----------------------------------------------------------------------
reg [7:0] ce_acc_out;
reg       ce_pix_out_r;
wire [7:0] ce_add_out = mode_416_active ? 8'd80 : 8'd64; // 2x native 40/32
wire line_boundary_native = ce_pix_native && (hcnt == htotal_native);

// -----------------------------------------------------------------------
// line buffers: 1-line ping-pong, same technique as crt_adjust.sv's line
// buffer. wr_bank is the line currently being filled at the native rate;
// the output side always reads ~wr_bank, the previous, already-complete
// line, so the 2x-rate output can never race ahead of the write pointer.
// The bank bit doubles as the array's MSB (matches crt_adjust's own
// {bank, addr} indexing) so each screen is one contiguous 1024-deep array.
// -----------------------------------------------------------------------
reg [23:0] buf_a [0:1023];
reg [23:0] buf_b [0:1023];
reg        wr_bank;
wire       rd_bank = ~wr_bank;

always @(posedge clk) begin
    if (rst)
        wr_bank <= 1'b0;
    else if (line_boundary_native)
        wr_bank <= ~wr_bank;
end

always @(posedge clk) begin
    if (ce_pix_native) begin
        buf_a[{wr_bank, hcnt}] <= rgb_a;
        buf_b[{wr_bank, hcnt}] <= rgb_b;
    end
end

always @(posedge clk) begin
    if (rst || line_boundary_native) begin
        ce_acc_out   <= 8'd0;
        ce_pix_out_r <= 1'b0;
    end
    else begin
        logic [8:0] s;
        s = ce_acc_out + ce_add_out;
        ce_pix_out_r <= (s >= 9'd240);
        ce_acc_out   <= (s >= 9'd240) ? (s[7:0] - 8'd240) : s[7:0];
    end
end
assign ce_pix_out = ce_pix_out_r;

// -----------------------------------------------------------------------
// output horizontal counter: resets with the native line boundary so it
// stays phase-locked to the write side every line.
// -----------------------------------------------------------------------
reg [9:0] out_hcnt;
always @(posedge clk) begin
    if (rst || line_boundary_native)
        out_hcnt <= 10'd0;
    else if (ce_pix_out && out_hcnt != htotal_out - 10'd1)
        out_hcnt <= out_hcnt + 10'd1;
    else if (ce_pix_out)
        out_hcnt <= 10'd0;
end

// screen-A / screen-B read address for the coming out_hcnt sample
wire        rd_is_b     = out_hcnt >= hdisp_count;
// rd_addr only keeps the low 9 bits of out_hcnt_b; during deep blanking
// out_hcnt_b can exceed 511 and this wraps the read address, but that read
// is never displayed (hblank_out is asserted there), so the wrap is
// harmless -- bit 9 is intentionally discarded, not an oversight.
/* verilator lint_off UNUSEDSIGNAL */
wire [9:0]  out_hcnt_b  = out_hcnt - hdisp_count;
/* verilator lint_on UNUSEDSIGNAL */
wire [8:0]  rd_addr     = rd_is_b ? out_hcnt_b[8:0] : out_hcnt[8:0];

reg [23:0] buf_a_q, buf_b_q;
reg        rd_is_b_d;
reg [9:0]  out_hcnt_d;
always @(posedge clk) begin
    if (ce_pix_out) begin
        buf_a_q    <= buf_a[{rd_bank, rd_addr}];
        buf_b_q    <= buf_b[{rd_bank, rd_addr}];
        rd_is_b_d  <= rd_is_b;
        out_hcnt_d <= out_hcnt;
    end
end

// -----------------------------------------------------------------------
// Divider bar: a solid black seam straddling the A|B join, so the two
// player views read as two pictures instead of one wide one. It is drawn
// OVER the composed pixels -- neither screen is moved, resized, or
// rescaled, so DIVIDER_W output pixels (half from A's right edge, half
// from B's left edge) are simply overpainted black. At this geometry one
// output pixel is exactly one native pixel of whichever screen it lands
// on, so DIVIDER_W=2 costs each screen its outermost column.
// -----------------------------------------------------------------------
localparam [9:0] DIVIDER_W    = 10'd2;             // total width, output px
localparam [9:0] DIVIDER_HALF = DIVIDER_W >> 1;    // eaten from each side
wire in_divider = (out_hcnt_d >= hdisp_count - DIVIDER_HALF) &&
                  (out_hcnt_d <  hdisp_count + (DIVIDER_W - DIVIDER_HALF));

// -----------------------------------------------------------------------
// output pixel/sync mux, aligned to the one-cycle buffer read latency
// -----------------------------------------------------------------------
always @(posedge clk) begin
    if (ce_pix_out) begin
        rgb_out    <= in_divider ? 24'h000000
                                 : (rd_is_b_d ? buf_b_q : buf_a_q);
        hblank_out <= (out_hcnt_d >= hdisp_out);
        // native hsync sits at [hdisp+24, hdisp+56); every native hcnt unit
        // is exactly 2 out_hcnt units, so the same window scales by 2 from
        // hdisp_out.
        hsync_out  <= (out_hcnt_d >= hdisp_out + 10'd48) &&
                      (out_hcnt_d <  hdisp_out + 10'd112);
    end
end

// The read side displays the line completed at the preceding native line
// boundary. Capture the native line's timing at that same boundary so the
// output DE/sync state describes the line held in the selected read bank.
// Reset starts blank until the first complete line has been captured; this
// prevents the uninitialized/empty read bank from being exposed as active
// video after reset.
always @(posedge clk) begin
    if (rst) begin
        vblank_out <= 1'b1;
        vsync_out  <= 1'b0;
    end
    else if (line_boundary_native) begin
        vblank_out <= vblank_native;
        vsync_out  <= vsync_native;
    end
end

endmodule
