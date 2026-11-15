/* X-Men 6-player dual monitor composer
 *
 * The 6P board has a single set of graphics chips. It draws the left monitor
 * on one frame and the right monitor on the next (MAME xmen.cpp
 * screen_vblank: index = field latched at VB start). Each monitor is
 * 288x224: left shows native columns 0..287, right shows columns 32..319
 * (xmen6p set_raw visible areas).
 *
 * This module shows both monitors side by side in one 576x224 raster with
 * no gap. The left monitor occupies output pixels 0..287 and the right one
 * 288..575, so the two pictures touch in the middle as on the cabinet.
 *
 *  - Native pixels are stored as 12-bit pens {shadow, palette index}. MAME
 *    also keeps the drawn bitmap as pens and resolves colours when the screen
 *    is displayed.
 *  - A single 288x224 pen store holds the monitor that is not being drawn.
 *    For each native pixel inside the live monitor's window, the store does
 *    a read-then-write at the same address: the old pen is the other
 *    monitor's last frame, and the live pen replaces it.
 *  - Both pens go into a ping-pong line buffer. The next native line plays
 *    it back at twice the native pixel rate (12 MHz = 48/4, an integer CE),
 *    so the output line period equals the native line period exactly. The
 *    output is one native line late; VB/VS are delayed by one line.
 *  - Colours are resolved through a copy of the palette RAM that takes the
 *    same CPU writes, using the same 5->8 bit conversion and shadow halving
 *    as jtxmen_colmix.
 */
module jtxmen6p_dual(
    input             rst,
    input             clk,
    input             ncen,      // native pixel CE, 6 MHz
    input             ocen,      // output pixel CE, 12 MHz, ncen is a subset
    // native raster
    input             lhbl,
    input             lvbl,
    input             hs,
    input             vs,
    input      [11:0] pen,       // {shadow, palette index}, timed like colmix bgr
    input             live_idx,  // monitor being drawn: 0 left, 1 right
    // CPU palette writes (mirror of jtxmen_colmix)
    input      [11:1] cpu_addr,
    input      [15:0] cpu_dout,
    input      [ 1:0] pal_we,
    // composed raster
    // character select overlay (jtxmen6p_seats): ovl must be valid three
    // clocks after ox/oy change. 0 none, 1 dim, 2 white, 3 yellow
    output     [ 9:0] ovl_x,
    output     [ 7:0] ovl_y,
    input      [ 1:0] ovl,

    output reg [ 7:0] red,
    output reg [ 7:0] green,
    output reg [ 7:0] blue,
    output reg        lhbl_o,
    output reg        lvbl_o,
    output reg        hs_o,
    output reg        vs_o
);

localparam [8:0] SCRW = 9'd288,
                 ROFS = 9'd32;  // right monitor first native column

// ---------------------------------------------------------------------------
// native pixel sampling: pixel k = (pen_r, lhbl, lvbl) seen at the ncen that
// ends it, which matches colmix where bgr and the blanking gate change together
reg  [11:0] pen_r;
reg         lhbl_l, lvbl_l;
reg  [ 8:0] ncol;          // native active column of the sampled pixel
reg         nact;          // sampled pixel is active
reg  [11:0] npen;
reg         smp;           // one clk strobe: a native pixel was sampled

always @(posedge clk, posedge rst) begin
    if( rst ) begin
        pen_r  <= 0;
        lhbl_l <= 0;
        lvbl_l <= 0;
        ncol   <= 0;
        nact   <= 0;
        npen   <= 0;
        smp    <= 0;
    end else begin
        smp <= 0;
        if( ncen ) begin
            pen_r  <= pen;
            lhbl_l <= lhbl;
            lvbl_l <= lvbl;
            smp    <= 1;
            nact   <= lhbl && lvbl;
            npen   <= pen_r;
            // column of the pixel being sampled now
            if( !lhbl ) ncol <= 0; // reset during blanking
            else if( lhbl_l ) ncol <= ncol + 9'd1;
        end
    end
end

// Note: ncol is the column of the pixel captured on the same ncen edge. The
// first active pixel after the blank (lhbl_l low) gets ncol=0.

wire in_win = nact && (live_idx ? (ncol >= ROFS && ncol < ROFS+SCRW) : (ncol < SCRW));
wire [8:0] xwin = live_idx ? ncol - ROFS : ncol;

// ---------------------------------------------------------------------------
// pen store: 288x224, read-then-write per live pixel
reg  [15:0] fb_addr;
reg  [15:0] fb_wa;
reg  [11:0] fb_wd;
reg         fb_we;
wire [11:0] fbl_q, fbr_q;
reg  [ 2:0] rmw;
reg  [ 8:0] lb_x;
reg  [11:0] live_pen;

// line buffers: one RAM per monitor, ping-pong bank bit
reg         wr_bank;
reg         lb_we;
reg  [11:0] lb_dl, lb_dr;

always @(posedge clk, posedge rst) begin
    if( rst ) begin
        fb_addr  <= 0;
        fb_wa    <= 0;
        fb_wd    <= 0;
        fb_we    <= 0;
        rmw      <= 0;
        lb_x     <= 0;
        live_pen <= 0;
        lb_we    <= 0;
        lb_dl    <= 0;
        lb_dr    <= 0;
    end else begin
        fb_we <= 0;
        lb_we <= 0;
        rmw   <= rmw << 1;
        if( !lvbl ) fb_addr <= 0;
        if( smp && in_win ) begin
            fb_wa    <= fb_addr;    // read address presented now (port 1)
            fb_wd    <= npen;
            live_pen <= npen;
            lb_x     <= xwin;
            fb_addr  <= fb_addr + 16'd1;
            rmw      <= 3'd1;
        end
        // rmw[0]: RAM samples read address; rmw[1]: fb_q holds old pen
        if( rmw[1] ) begin
            fb_we <= 1;             // write lands after the read
            lb_we <= 1;
            // Matched pairs only (MAME shows both halves change together):
            // pair = left frame N + right frame N+1, shown during N+1 and N+2.
            //  right-draw frame: stored left (frame N)  + live right
            //  left-draw frame : old left (read before it is overwritten)
            //                    + stored right (frame N+1)
            lb_dl <= fbl_q;
            lb_dr <= live_idx ? live_pen : fbr_q;
        end
    end
end

// one pen store per monitor; the live monitor's store is read, then written
jtframe_dual_ram #(.DW(12),.AW(16)) u_fbl(
    .clk0   ( clk       ),
    .data0  ( fb_wd     ),
    .addr0  ( fb_wa     ),
    .we0    ( fb_we & ~live_idx ),
    .q0     (           ),
    .clk1   ( clk       ),
    .data1  ( 12'd0     ),
    .addr1  ( fb_wa     ),
    .we1    ( 1'b0      ),
    .q1     ( fbl_q     )
);

jtframe_dual_ram #(.DW(12),.AW(16)) u_fbr(
    .clk0   ( clk       ),
    .data0  ( fb_wd     ),
    .addr0  ( fb_wa     ),
    .we0    ( fb_we &  live_idx ),
    .q0     (           ),
    .clk1   ( clk       ),
    .data1  ( 12'd0     ),
    .addr1  ( fb_wa     ),
    .we1    ( 1'b0      ),
    .q1     ( fbr_q     )
);

// ---------------------------------------------------------------------------
// output raster: restarts at the start of each native active line
reg  [ 9:0] ox;          // output column 0..767
reg         lhbl_ll;     // native lhbl, for its rising edge
reg         line_act;    // the native line just finished was active
reg         out_vact;    // output line shows an active native line
reg         hs_l, vs_prev;
reg  [ 7:0] oy;          // active output line number
wire        nline = lhbl & ~lhbl_ll; // native active line starts

assign ovl_x = ox;
assign ovl_y = oy;

always @(posedge clk, posedge rst) begin
    if( rst ) begin
        ox       <= 10'h3ff;
        lhbl_ll  <= 0;
        line_act <= 0;
        out_vact <= 0;
        oy       <= 0;
        wr_bank  <= 0;
        hs_l     <= 0;
        vs_prev  <= 0;
        vs_o     <= 0;
    end else begin
        lhbl_ll <= lhbl;
        if( lhbl && lvbl ) line_act <= 1;
        if( nline ) begin
            // the line buffer bank just written holds the previous native line
            wr_bank  <= ~wr_bank;
            out_vact <= line_act;
            oy       <= out_vact ? oy + 8'd1 : 8'd0;
            line_act <= 0;
            ox       <= 0;
        end else if( ocen && ox != 10'h3ff ) begin
            ox <= ox + 10'd1;
        end
        // VS delayed by one line, sampled at each HS rising edge
        hs_l <= hs;
        if( hs && !hs_l ) begin
            vs_o    <= vs_prev;
            vs_prev <= vs;
        end
    end
end

// line buffer read: monitor select by output column
wire        rd_right = ox >= {1'b0,SCRW};
wire [ 8:0] rd_x     = rd_right ? ox[8:0] - SCRW : ox[8:0];
wire [11:0] lb_ql, lb_qr;

jtframe_dual_ram #(.DW(12),.AW(10)) u_lbl(
    .clk0   ( clk       ),
    .data0  ( lb_dl     ),
    .addr0  ({wr_bank, lb_x}),
    .we0    ( lb_we     ),
    .q0     (           ),
    .clk1   ( clk       ),
    .data1  ( 12'd0     ),
    .addr1  ({~wr_bank, rd_x}),
    .we1    ( 1'b0      ),
    .q1     ( lb_ql     )
);

jtframe_dual_ram #(.DW(12),.AW(10)) u_lbr(
    .clk0   ( clk       ),
    .data0  ( lb_dr     ),
    .addr0  ({wr_bank, lb_x}),
    .we0    ( lb_we     ),
    .q0     (           ),
    .clk1   ( clk       ),
    .data1  ( 12'd0     ),
    .addr1  ({~wr_bank, rd_x}),
    .we1    ( 1'b0      ),
    .q1     ( lb_qr     )
);

// palette copy (same arrangement as jtxmen_colmix: low/high byte RAMs)
reg         rd_right_l;
wire [11:0] opix = rd_right_l ? lb_qr : lb_ql;
wire [15:0] opal;

always @(posedge clk) rd_right_l <= rd_right;

jtframe_dual_ram #(.DW(8),.AW(11)) u_pallo(
    .clk0   ( clk           ),
    .data0  ( cpu_dout[7:0] ),
    .addr0  ( cpu_addr      ),
    .we0    ( pal_we[0]     ),
    .q0     (               ),
    .clk1   ( clk           ),
    .data1  ( 8'd0          ),
    .addr1  ( opix[10:0]    ),
    .we1    ( 1'b0          ),
    .q1     ( opal[7:0]     )
);

jtframe_dual_ram #(.DW(8),.AW(11)) u_palhi(
    .clk0   ( clk           ),
    .data0  ( cpu_dout[15:8]),
    .addr0  ( cpu_addr      ),
    .we0    ( pal_we[1]     ),
    .q0     (               ),
    .clk1   ( clk           ),
    .data1  ( 8'd0          ),
    .addr1  ( opix[10:0]    ),
    .we1    ( 1'b0          ),
    .q1     ( opal[15:8]    )
);

function [7:0] conv58(input [4:0] cin );
    conv58 = {cin, cin[4-:3]};
endfunction

// pipeline: the edge that sets ox (an ocen, or the line restart up to three
// clocks before an ocen) -> +1 line buffer q (opix) -> +2 palette q and
// shd_l. The next ocen registers the colour of column ox together with its
// blanking, so RGB and LHBL/LVBL always refer to the same pixel.
reg         shd_l;
wire [ 7:0] r8 = conv58(opal[ 4: 0]),
            g8 = conv58(opal[ 9: 5]),
            b8 = conv58(opal[14:10]);

always @(posedge clk) shd_l <= opix[11];

always @(posedge clk, posedge rst) begin
    if( rst ) begin
        red    <= 0;
        green  <= 0;
        blue   <= 0;
        lhbl_o <= 0;
        lvbl_o <= 0;
        hs_o   <= 0;
    end else if( ocen ) begin
        lhbl_o <= ox < 10'd576;
        lvbl_o <= out_vact;
        hs_o   <= hs;
        if( ox < 10'd576 && out_vact ) begin
            case( ovl )
                2'd1: begin // dim box behind the text
                    red   <= shd_l ? r8>>3 : r8>>2;
                    green <= shd_l ? g8>>3 : g8>>2;
                    blue  <= shd_l ? b8>>3 : b8>>2;
                end
                2'd2: begin red <= 8'hff; green <= 8'hff; blue <= 8'hff; end
                2'd3: begin red <= 8'hff; green <= 8'hd8; blue <= 8'h00; end
                default: begin
                    red   <= shd_l ? r8>>1 : r8;
                    green <= shd_l ? g8>>1 : g8;
                    blue  <= shd_l ? b8>>1 : b8;
                end
            endcase
        end else begin
            red   <= 0;
            green <= 0;
            blue  <= 0;
        end
    end
end

endmodule
