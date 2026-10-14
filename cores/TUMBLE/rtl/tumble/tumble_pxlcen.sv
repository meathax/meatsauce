// Line-locked pixel enables for the 442 x 274 TUMBLE raster on clk48.
//
// None of the three board pixel rates (7.024264, 7.26648 and 7 MHz) divides
// 48 MHz, so a free-running fractional enable gives 6/7-clk pixels and lines
// whose length dithers by one clk. MiSTer's analog, Y/C and direct-video
// outputs emit one sample per CLK_VIDEO cycle and its scandoubler resamples
// on a fixed grid of the measured pixel width, so both need an integer width.
//
// This generator keeps the exact board refresh rate and makes
//   * every pixel from 12 before to 4 after the active area exactly 7 clk,
//   * every visible line exactly the same integer number of clk,
//   * the horizontal sync pulse a fixed width.
// The fractional remainder of each line is repaid as a few extra clk in the
// first 26 lines of vertical blanking, leaving 8 nominal lines before the
// picture. The raster, renderers and CPU timing only see pxl_cen.
module tumble_pxlcen(
    input            clk,
    input      [1:0] raster,    // 0: 58 Hz, 1: 60 Hz, 2: 7 MHz / (442 x 274)
    input            LHBL,      // active-low blanks from the game video timer
    input            LVBL,
    output reg       pxl_cen,
    output reg       pxl2_cen
);

// Period index p counts pixel periods from the first blank pixel (H = 320):
//   0..3 tail margin, 4..20 front porch, 21..47 sync, 48..109 back porch,
//   110..121 lead margin, 122..441 active.
localparam [8:0] P_LAST  = 9'd441,
                 P_FRONT = 9'd4,
                 P_SYNC  = 9'd21,
                 P_BACK  = 9'd48,
                 P_LEAD  = 9'd110;
localparam [4:0] PAY_LINES = 5'd26;

// Per raster: line = 336*7 + 27*sync_w + 79*fast_w + fast_more clk, and the
// true line length is that integer plus line_rem/line_den clk.
//   58 Hz: 442 * 6000000/878033 = 3020 + 340340/878033
//   60 Hz: 442 *  200000/ 30277 = 2919 +  21437/ 30277
//   raw  : 442 *      48/     7 = 3030 +      6/     7
reg  [ 2:0] sync_w, fast_w;
reg  [ 6:0] fast_more;
reg  [19:0] line_rem, line_den;
reg  [ 3:0] pay_cap;
always @* begin
    case (raster)
        2'd1: begin
            sync_w = 3'd6; fast_w = 3'd5; fast_more = 7'd10;
            line_rem = 20'd21437; line_den = 20'd30277; pay_cap = 4'd8;
        end
        2'd2: begin
            sync_w = 3'd7; fast_w = 3'd6; fast_more = 7'd15;
            line_rem = 20'd6; line_den = 20'd7; pay_cap = 4'd10;
        end
        default: begin
            sync_w = 3'd7; fast_w = 3'd6; fast_more = 7'd5;
            line_rem = 20'd340340; line_den = 20'd878033; pay_cap = 4'd5;
        end
    endcase
end

reg  [ 8:0] p = 9'd0;
reg  [ 3:0] cnt = 4'd0, stretch = 4'd0;
reg         lhbl_l = 1'b0, pay_line = 1'b0;
reg  [ 4:0] vbl_lines = 5'd0;
reg  [27:0] debt = 28'd0;

wire        in_front = p >= P_FRONT && p < P_SYNC;
wire        in_sync  = p >= P_SYNC  && p < P_BACK;
wire        in_back  = p >= P_BACK  && p < P_LEAD;
wire [ 6:0] fast_idx = in_front ? p[6:0] - 7'd4 : p[6:0] - 7'd31;
wire [ 2:0] width    = in_sync ? sync_w :
                       (in_front || in_back) ? fast_w + {2'd0,fast_idx < fast_more} : 3'd7;
wire        last     = cnt == {1'b0,width} - 4'd1;
wire        can_pay  = p == P_FRONT && pay_line && stretch < pay_cap &&
                       debt >= {8'd0,line_den};
wire        lhbl_fall = lhbl_l && !LHBL;
wire [ 8:0] p_next   = lhbl_fall ? 9'd1 : p == P_LAST ? 9'd0 : p + 9'd1;

always @(posedge clk) begin
    pxl_cen  <= 1'b0;
    pxl2_cen <= 1'b0;
    if (last && can_pay) begin
        debt    <= debt - {8'd0,line_den};
        stretch <= stretch + 4'd1;
    end else if (last) begin
        pxl_cen  <= 1'b1;
        pxl2_cen <= 1'b1;
        cnt      <= 4'd0;
        stretch  <= 4'd0;
        lhbl_l   <= LHBL;
        p        <= p_next;
        if (p_next == 9'd1) begin
            if (!debt[27]) debt <= debt + {8'd0,line_rem};
            pay_line  <= !LVBL && vbl_lines < PAY_LINES;
            vbl_lines <= LVBL ? 5'd0 : vbl_lines + {4'd0,vbl_lines != 5'd31};
        end
    end else begin
        cnt <= cnt + 4'd1;
        if (cnt == {2'd0,width[2:1]} - 4'd1) pxl2_cen <= 1'b1;
    end
end

endmodule
