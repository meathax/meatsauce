// SPDX-License-Identifier: GPL-3.0-or-later
// CRT portrait output for the analog/direct-video path.
//
// The HDMI rotation writer already stores the upright portrait picture in the
// DDR framebuffer (32 bpp {0,B,G,R}, one row per displayed line, FB_STRIDE
// bytes apart). This block reads that framebuffer back one row per output line
// and drives its own CRT raster:
//   MODE_15K: 480i, 9.6 MHz pixels (96 MHz / 10), 610 x 525 half-line
//             interlace, 15.738 kHz / 59.95 Hz fields. Field 0 (VSync on a
//             line start) shows rows 0,2,4..; field 1 (VSync mid-line) rows
//             1,3,5..
//   MODE_31K: progressive, 16 MHz pixels (96 MHz / 6), 508 x 525,
//             31.496 kHz / 59.99 Hz, one row per line.
// The pixel enable is a plain divide-by-N counter that only restarts when the
// mode changes, so every line and blanking interval has identical spacing.
// HSync/VSync widths and the picture window are fixed per mode. The picture is
// centred in the standard active window; rows or columns beyond it are cut.
//
// DDR: this block shares the video DDR client with the rotation writer. The
// writer is held off with its own BUSY while a read burst is owned, and the
// grant only changes when the current owner has no unaccepted request, so an
// Avalon request is never withdrawn before acceptance.
module gaiapolis_crt_portrait (
    input  logic        clk,          // CLK_VIDEO == DDRAM clock
    input  logic        rst,
    input  logic        enable,       // portrait CRT output selected
    input  logic        mode_31k,     // forced scandoubler / 31 kHz monitor
    // Framebuffer description from the rotation writer
    input  logic [31:0] fb_base,      // byte address of the displayed buffer
    input  logic [13:0] fb_stride,    // bytes per row
    input  logic [11:0] fb_width,     // pixels per row
    input  logic [11:0] fb_height,    // rows
    output logic        fb_vbl,       // rises at each output field/frame start
    // Writer side of the shared DDR client
    input  logic [28:0] w_addr,
    input  logic [63:0] w_din,
    input  logic [ 7:0] w_be,
    input  logic        w_we,
    input  logic [ 7:0] w_burstcnt,
    output logic        w_busy,
    // Shared DDR client
    output logic [28:0] ddr_addr,
    output logic [63:0] ddr_din,
    output logic [ 7:0] ddr_be,
    output logic        ddr_we,
    output logic        ddr_rd,
    output logic [ 7:0] ddr_burstcnt,
    input  logic        ddr_busy,
    input  logic [63:0] ddr_dout,
    input  logic        ddr_dout_ready,
    // CRT video
    output logic        ce_pixel,
    output logic [ 7:0] r, g, b,
    output logic        hs, vs, de,
    output logic        field
);
    // ------------------------------------------------------------------
    // Mode constants
    // ------------------------------------------------------------------
    localparam [3:0]  N15 = 4'd10,  N31 = 4'd6;
    localparam [9:0]  HT15 = 10'd610, HT31 = 10'd508;
    localparam [9:0]  HS15 = 10'd45,  HS31 = 10'd61;    // 4.7 us / 3.8 us
    localparam [9:0]  HW15 = 10'd103, HW31 = 10'd91;    // active window start
    localparam [9:0]  HL15 = 10'd505, HL31 = 10'd407;   // active window length
    localparam [9:0]  VT   = 10'd525;                   // lines per frame
    localparam [9:0]  VW15 = 10'd21,  VW31 = 10'd35;    // first visible line
    localparam [9:0]  VL15 = 10'd240, VL31 = 10'd480;   // visible lines (per field for 15k)

    logic        mode_q;          // latched mode, changes only at frame start
    logic [3:0]  div;             // pixel divider counter
    logic [9:0]  hc, ln;          // pixel within line, line within frame
    wire  [3:0]  n_now  = mode_q ? N31  : N15;
    wire  [9:0]  ht_now = mode_q ? HT31 : HT15;

    // Geometry latched at frame start (no mid-frame changes)
    logic [9:0]  hstart, width;   // picture columns
    logic [9:0]  vstart, rows_a, rows_b;
    logic [31:0] base_q;
    logic [13:0] stride_q;

    wire [9:0] fbw = fb_width  > 12'd504 ? 10'd504 : fb_width[9:0];
    wire [9:0] fbh = fb_height > 12'd480 ? 10'd480 : fb_height[9:0];

    // ------------------------------------------------------------------
    // Raster
    // ------------------------------------------------------------------
    wire frame_end = ce_pixel && hc == ht_now - 10'd1 && ln == VT - 10'd1;
    always_ff @(posedge clk) begin
        if (rst) begin
            div <= 0; hc <= 0; ln <= 0; mode_q <= mode_31k; ce_pixel <= 0;
        end else begin
            ce_pixel <= div == 0;
            div <= div == n_now - 4'd1 ? 4'd0 : div + 4'd1;
            if (ce_pixel) begin
                if (hc == ht_now - 10'd1) begin
                    hc <= 0;
                    ln <= ln == VT - 10'd1 ? 10'd0 : ln + 10'd1;
                end else hc <= hc + 10'd1;
            end
            // A mode change restarts the raster at a frame boundary with a
            // fresh divider phase; within a mode the spacing never changes.
            if (frame_end && mode_q != mode_31k) begin
                mode_q <= mode_31k; div <= 0; ce_pixel <= 0;
            end
        end
    end

    // Frame-start geometry latch
    always_ff @(posedge clk) begin
        if (rst) begin
            hstart <= HW15; width <= 0; vstart <= VW15; rows_a <= 0; rows_b <= 0;
            base_q <= 0; stride_q <= 0;
        end else if (ce_pixel && hc == 0 && ln == 0) begin
            width    <= fbw;
            base_q   <= fb_base;
            stride_q <= fb_stride;
            if (mode_q) begin
                hstart <= HW31 + ((HL31 - (fbw > HL31 ? HL31 : fbw)) >> 1);
                vstart <= VW31 + ((VL31 - fbh) >> 1);
                rows_a <= fbh; rows_b <= 0;
            end else begin
                hstart <= HW15 + ((HL15 - fbw) >> 1);
                rows_a <= (fbh + 10'd1) >> 1;          // even rows
                rows_b <= fbh >> 1;                     // odd rows
                vstart <= VW15 + ((VL15 - ((fbh + 10'd1) >> 1)) >> 1);
            end
        end
    end

    // Row shown on a line: {valid, row}
    function automatic [10:0] row_of(input [9:0] line);
        logic [9:0] rel;
        begin
            row_of = 0;
            if (mode_q) begin
                rel = line - vstart;
                if (line >= vstart && rel < rows_a) row_of = {1'b1, rel};
            end else if (line < 10'd263) begin
                rel = line - vstart;
                if (line >= vstart && rel < rows_a) row_of = {1'b1, rel[8:0], 1'b0};
            end else begin
                rel = line - 10'd263 - vstart;
                if (line >= 10'd263 + vstart && rel < rows_b) row_of = {1'b1, rel[8:0], 1'b1};
            end
        end
    endfunction

    wire [10:0] cur_row  = row_of(ln);
    wire [9:0]  next_ln  = ln == VT - 10'd1 ? 10'd0 : ln + 10'd1;
    wire [10:0] next_row = row_of(next_ln);

    // Syncs (active high). 15 kHz field 1 VSync starts mid-line 262.
    wire [9:0] half = HT15 >> 1;
    logic vs_n, hs_n, act_n;
    always_comb begin
        hs_n = hc < (mode_q ? HS31 : HS15);
        if (mode_q) vs_n = ln < 10'd2;
        else vs_n = ln < 10'd3 ||
                    (ln == 10'd262 && hc >= half) || ln == 10'd263 || ln == 10'd264 ||
                    (ln == 10'd265 && hc < half);
        act_n = cur_row[10] && hc >= hstart && hc < hstart + width;
    end

    // ------------------------------------------------------------------
    // Double line buffer: 256 x 48 (two pixels per DDR beat), per bank
    // ------------------------------------------------------------------
    logic [47:0] lbuf [0:511];
    logic [8:0]  lb_waddr;
    logic [47:0] lb_wdata;
    logic        lb_we;
    logic [47:0] lb_q;
    wire  [9:0]  px      = hc - hstart;
    wire  [8:0]  lb_raddr = {ln[0], px[8:1]};
    always_ff @(posedge clk) begin
        if (lb_we) lbuf[lb_waddr] <= lb_wdata;
        lb_q <= lbuf[lb_raddr];
    end

    // Output stage: hc is stable for N >= 6 clocks, so lb_q already holds the
    // current pixel pair; register the whole tuple together on the enable.
    always_ff @(posedge clk) begin
        if (rst) begin
            hs <= 0; vs <= 0; de <= 0; r <= 0; g <= 0; b <= 0; field <= 0;
        end else if (ce_pixel) begin
            hs <= hs_n; vs <= vs_n; de <= act_n;
            if (!mode_q && ln == 10'd262 && hc == half) field <= 1;
            if (ln == 0 && hc == 0) field <= 0;
            {b, g, r} <= act_n ? (px[0] ? lb_q[47:24] : lb_q[23:0]) : 24'd0;
        end
    end

    // Field/frame start marker for the writer's buffer selection
    always_ff @(posedge clk) begin
        if (rst) fb_vbl <= 0;
        else if (ce_pixel && hc == 0) fb_vbl <= mode_q ? ln < 10'd2 : (ln < 10'd3 || (ln >= 10'd263 && ln < 10'd266));
    end

    // ------------------------------------------------------------------
    // Row fetch: at each line start, load the next line's row
    // ------------------------------------------------------------------
    logic       nxt_valid, nxt_first, nxt_row0, nxt_ln0;
    always_ff @(posedge clk) if (ce_pixel && hc == 10'd2) begin
        nxt_valid <= next_row[10];
        nxt_first <= next_row[9:0] <= 10'd1;
        nxt_row0  <= next_row[0];
        nxt_ln0   <= next_ln[0];
    end

    typedef enum logic [2:0] { F_IDLE, F_WAITGNT, F_REQ, F_DATA } fstate_t;
    fstate_t     fst;
    logic [28:0] f_addr;           // next burst address (qwords)
    logic [8:0]  f_left;           // qwords remaining in this row
    logic [7:0]  f_beats;          // beats remaining in this burst
    logic [8:0]  f_waddr;
    logic        own_r;            // DDR client granted to the reader
    logic [23:0] row_off;          // row * stride in bytes, >> 3 -> qwords
    wire  [9:0]  qwords_w = (width + 10'd1) >> 1;
    wire  [8:0]  qwords = qwords_w[8:0];
    wire  [8:0]  burst_now = f_left > 9'd64 ? 9'd64 : f_left;

    always_ff @(posedge clk) begin
        if (rst) begin
            fst <= F_IDLE; f_addr <= 0; f_left <= 0; f_beats <= 0;
            f_waddr <= 0; row_off <= 0; lb_we <= 0; lb_waddr <= 0; lb_wdata <= 0;
        end else begin
            lb_we <= 0;
            case (fst)
                // Stage 1 (hc==2): register the next line's row decision.
                // Stage 2 (hc==3): start the fetch. Rows arrive in order, so
                // the byte offset is an accumulator (no multiplier, short paths).
                F_IDLE: if (enable && ce_pixel && hc == 10'd3 && nxt_valid && width != 0) begin
                    row_off <= nxt_first ? (nxt_row0 ? {10'd0, stride_q} : 24'd0)
                                         : row_off + (mode_q ? {10'd0, stride_q} : {9'd0, stride_q, 1'b0});
                    f_waddr <= {nxt_ln0, 8'd0};
                    f_left  <= qwords;
                    fst     <= F_WAITGNT;
                end
                F_WAITGNT: begin
                    f_addr <= base_q[31:3] + {8'd0, row_off[23:3]};
                    if (own_r) fst <= F_REQ;
                end
                F_REQ: if (!ddr_busy) begin       // read accepted this clock
                    f_beats <= burst_now[7:0];
                    f_left  <= f_left - burst_now;
                    fst     <= F_DATA;
                end
                F_DATA: if (ddr_dout_ready) begin
                    lb_we    <= 1;
                    lb_waddr <= f_waddr;
                    lb_wdata <= {ddr_dout[55:32], ddr_dout[23:0]};
                    f_waddr  <= f_waddr + 9'd1;
                    f_addr   <= f_addr + 29'd1;
                    f_beats  <= f_beats - 8'd1;
                    if (f_beats == 8'd1) fst <= f_left == 0 ? F_IDLE : F_REQ;
                end
                default: fst <= F_IDLE;
            endcase
            // Never withdraw an issued read: only an unrequested fetch aborts.
            if (!enable && fst == F_WAITGNT) fst <= F_IDLE;
        end
    end

    // ------------------------------------------------------------------
    // Grant: switch only when the current owner has nothing unaccepted
    // ------------------------------------------------------------------
    wire reader_wants = fst == F_WAITGNT || fst == F_REQ || fst == F_DATA;
    wire writer_pending = w_we && ddr_busy;          // offered but not accepted
    always_ff @(posedge clk) begin
        if (rst) own_r <= 0;
        else if (!own_r) begin
            if (reader_wants && !writer_pending) own_r <= 1;
        end else if (!reader_wants) own_r <= 0;
    end

    assign w_busy       = own_r || ddr_busy;
    assign ddr_addr     = own_r ? f_addr : w_addr;
    assign ddr_din      = w_din;
    assign ddr_be       = own_r ? 8'hff : w_be;
    assign ddr_we       = !own_r && w_we;
    assign ddr_rd       = own_r && fst == F_REQ;
    assign ddr_burstcnt = own_r ? burst_now[7:0] : w_burstcnt;
    // Unused bits: DDR pad bytes, sub-qword address bits, row/column MSBs.
    wire unused = &{1'b0, ddr_dout[63:56], ddr_dout[31:24], base_q[2:0], cur_row[9:0], px[9], row_off[2:0], qwords_w[9]};
endmodule
