// SPDX-License-Identifier: GPL-3.0-or-later
// Output pixel retimer: re-emits the native raster at a uniform pixel width.
//
// WHY. The board's pixel clock is 42.954545 MHz / 6 = 7.159 MHz, and clk_sys
// is 48.3173 MHz, so ssv_video_timing's fractional accumulator gives a native
// pixel 6.749 clk on average: three pixels of 7 clk then one of 6, with one
// 3-pixel group per line. Since 4a9f895 restores the accumulator on every line
// wrap, that pattern is identical on every line -- the 6-clk pixels sit in
// fixed screen COLUMNS, every 4th column, with a phase slip near x=92.
//
// Direct Video emits one HDMI pixel per CLK_VIDEO (= clk_sys) cycle, and the
// analog DAC also takes one sample per CLK_VIDEO cycle, so on both paths those
// columns are physically 14% narrower than their neighbours. A still picture
// hides it; when the playfield scrolls every edge contracts as it crosses one
// of those columns, and a line-locked scaler (RetroTINK 4K) resampling the
// 3064-sample line shows it as faint vertical seams standing still while the
// background moves through them. The scaled-HDMI path re-captures on
// CE_PIXEL and never saw it, which is why it looked like a renderer bug.
//
// WHAT. A 16-entry FIFO takes {data, hblank} on every input ce and re-emits
// it with a minimum spacing of ACTIVE_PERIOD clk for active pixels and
// BLANK_PERIOD clk for blanking pixels. Active pixels therefore come out
// exactly 7 clk wide, 6.9 MHz, 3.6% slower than the board: every active pixel
// is the same width, which is the property the display needs. The reader
// falls behind across the active region (13-14 of 16 entries at the end of a
// 336- or 352-pixel line) and catches up in blanking at the shorter period, then
// runs starved, following the input with a fixed two-clock latency. Because
// the input cadence is identical on every line the output cadence is too:
// every line is still exactly 3064 clk, and sync keeps a constant width.
//
// Only the output stream is retimed. The raster counters, renderers, IRQs and
// CPU-to-pixel ratio are untouched, so frame CRCs and MAME lockstep traces do
// not move. ce_x2 marks the emit and the emit+3 clock, so the line doubler
// still gets exactly two x2 enables per pixel enable, in phase with it.
//
// Limit: active pixels at 7 clk plus blanking at 5 fit a 3064-clk, 454-pixel
// line for active widths up to 397 (all SSV sets are 336..352). A wider
// active area would outrun the FIFO; `level_hi` then forces emission rather
// than overwriting, and the simulation check below fails loudly.
`timescale 1ns/1ps

module ssv_pixel_retime #(
    parameter int W             = 28,
    parameter int ACTIVE_PERIOD = 7,
    parameter int BLANK_PERIOD  = 5
) (
    input  logic         clk,
    input  logic         rst,
    input  logic         ce_in,
    input  logic [W-1:0] d_in,
    input  logic         hb_in,
    output logic         ce_out,
    output logic         ce_x2_out,
    output logic [W-1:0] d_out,
    output logic         hb_out
);

localparam int AW = 4;
localparam int DEPTH = 1 << AW;

logic [W:0]    fifo [DEPTH];
logic [AW:0]   wr_ptr, rd_ptr;
logic [3:0]    cnt;
wire  [AW:0]   level    = wr_ptr - rd_ptr;
wire           level_hi = level >= (AW+1)'(DEPTH - 1);
wire  [3:0]    period   = hb_out ? 4'(BLANK_PERIOD) : 4'(ACTIVE_PERIOD);
wire           emit     = (level != 0) && ((cnt >= period - 4'd1) || level_hi);

always_ff @(posedge clk) begin
    if (ce_in)
        fifo[wr_ptr[AW-1:0]] <= {hb_in, d_in};
end

always_ff @(posedge clk) begin
    if (rst) begin
        wr_ptr    <= '0;
        rd_ptr    <= '0;
        cnt       <= 4'hF;
        ce_out    <= 1'b0;
        ce_x2_out <= 1'b0;
        d_out     <= '0;
        hb_out    <= 1'b1;
    end
    else begin
        if (ce_in)
            wr_ptr <= wr_ptr + 1'd1;
        ce_out    <= emit;
        ce_x2_out <= emit || (cnt == 4'd2);
        if (emit) begin
            {hb_out, d_out} <= fifo[rd_ptr[AW-1:0]];
            rd_ptr <= rd_ptr + 1'd1;
            cnt    <= 4'd0;
        end
        else if (cnt != 4'hF)
            cnt <= cnt + 1'd1;
    end
end

`ifdef SIMULATION
always @(posedge clk) begin
    if (!rst && level_hi)
        $fatal(1, "ssv_pixel_retime: FIFO level %0d, active area too wide for uniform pixels", level);
end
`endif

endmodule
