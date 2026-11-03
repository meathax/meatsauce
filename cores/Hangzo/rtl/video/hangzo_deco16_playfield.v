/*  This file is part of JTCORES. GPLv3. See jtcninja_game.v header.

    jtcninja_deco16 - faithful single-playfield renderer for the Data East
    deco16ic tile generator (custom chips 55 / 56 / 74, 4bpp). One instance
    renders ONE playfield; a deco16ic chip has two (instantiate twice).

    Scroll modes (control1[6:5], per deco16ic.cpp deco16_pf_update /
    custom_tilemap_draw):
        00  uniform     X = scrollx                  Y = scrolly
        40  rowscroll   X = scrollx + rs[src_y>>S]   Y = scrolly            (per line)
        20  colscroll   X = scrollx                  Y = scrolly + cs[col]  (per column)
        60  row+col     per-line X AND per-column Y   (the "custom" renderer)
    Runtime 8x8 / 16x16 (control1[7]), 64x32 / 64x64 maps, screen flip, and
    per-tile X/Y flip (tile bit 0x8000 gated by control1[1:0]).

    Streaming model: the line is walked as 8-pixel SOURCE columns (the gfx-fetch
    granularity). Each 8px column picks its own colscroll Y and lands on one
    tile's left/right half -> one tile lookup + one 32-bit gfx read per column.
    Because col_type (=8<<style) is always >=8 the colscroll value is constant
    across any 8px span, so this reproduces custom_tilemap_draw exactly.

    LIVE OUTPUT - there is no line buffer. The producer fetches columns into a
    8-entry FIFO and the consumer shifts one pixel per pxl_cen, locked to hdump,
    so a pixel is rendered as the raster reaches it and the playfield registers
    are read where the raster actually is. The FIFO is the only lead: at most
    8 columns = 64 px, against the 376-px line a buffered renderer runs ahead.
    That elasticity is what absorbs a slow gfx fetch; a column is 8 px = 64 clk
    of consume time against ~7 clk of fixed producer work plus one SDRAM read.
    vdump (not vrender) is the line being drawn, since nothing is held over.

    Tile word: [11:0]=code, [15:12]=colour, [15]=per-tile-flip-enable -> when set
    control1[0]=FLIPX, control1[1]=FLIPY. rsram: X table [0,0x200), Y table
    [0x200,0x400); the single read port is time-shared (X at line top, Y per col).
*/
module hangzo_deco16_playfield #(
    parameter [8:0] H_LAST=9'd447,
    parameter [5:0] COLUMN_LAST=6'd41,
    parameter [8:0] SCREEN_LAST=9'd319,
    parameter PXLW = 8       // output pixel = {colour[3:0], pixel[3:0]}
)(
    input             rst,
    input             clk,
    input             pxl_cen,
    input             hs,
    input      [ 8:0] vdump,          // line being scanned out right now
    input      [ 8:0] hdump,
    input             flip,           // screen flip; mirrors source rows and columns

    input             fullheight,     // 1 = 64 rows (else 32); cols always 64
    input      [15:0] scrollx,
    input      [15:0] scrolly,
    input      [ 7:0] control0,       // [7]=enable [6:3]=rowscroll style [2:0]=colscroll style
    input      [ 7:0] control1,       // [7]=8x8 [6]=rowscr [5]=colscr [1]=flipY_en [0]=flipX_en
    input      [ 2:0] bank,           // high tile-code bit(s)
    input             pswap,          // gfx plane-pair order swap
    input             rowmajor,       // 1=tiles laid out row-major (L/R 8px halves adjacent -> 64b cache hit)

    output reg [11:0] ram_addr,       // tile RAM (BRAM, 1-cyc)
    input      [15:0] ram_data,
    output reg [10:0] rsram_addr,     // row/colscroll RAM (BRAM, 1-cyc)
    input      [15:0] rsram_data,
    output reg        rom_cs,         // gfx ROM (SDRAM): 32-bit = 8px x 4 planes
    output reg [20:2] rom_addr,
    input      [31:0] rom_data,
    input             rom_ok,

    output     [PXLW-1:0] pxl
);

// ---- derived config ----
wire        tile16 = ~control1[7];
wire        en     =  control0[7];
wire        rowscr =  control1[6];
wire        colscr =  control1[5];
wire [ 3:0] rs_sh  =  control0[6:3];
wire [ 3:0] cs_sh  =  4'd3 + {1'b0,control0[2:0]};
wire        tfx_en =  control1[0];
wire        tfy_en =  control1[1];

wire [ 9:0] hmask = tile16 ? (fullheight ? 10'h3ff : 10'h1ff)
                           : (fullheight ? 10'h1ff : 10'h0ff);
wire [ 9:0] wmask = tile16 ? 10'h3ff : 10'h1ff;

// The live renderer walks source columns left-to-right while emitting screen
// pixels left-to-right. A 180-degree screen flip starts from the mirrored
// visible X endpoint and walks source columns right-to-left. The pixel counter
// then tracks the source offset within each fetched 8-pixel column.
wire [ 8:0] vr    = flip ? 9'd255 - vdump : vdump;
wire [ 9:0] src_y = (scrolly[9:0] + {1'b0,vr}) & hmask;

// ---- producer FSM ----
// XW*/CW* are wait states: the row/colscroll table is shared with the other
// playfield of the chip through a single BRAM port (see jtcninja_deco16ic), so
// rsram_addr must be held long enough for either arbiter phase to be served
// and captured. Four cycles per read covers the worst case.
localparam IDLE=0, XRD=1, XSET=2, CRD=3, CSET=4, RAMW=5, DEC=6, GFXW=7, PUSH=8,
           XW1=9, XW2=10, CW1=11, CW2=12;
reg  [ 3:0] st;
reg  [ 9:0] xstart, src_x;
reg  [ 5:0] colcnt;
reg  [ 9:0] mapy;
reg  [ 3:0] colour;
reg         tfx, tfy;
reg  [31:0] gfx;
reg         HSl;
reg         fresh, rom_good;   // guard against sampling stale rom_ok

wire        hs_neg = HSl & ~hs;
wire [ 5:0] tcol = tile16 ? src_x[9:4] : src_x[8:3];
wire [ 5:0] trow = tile16 ? mapy[9:4]  : mapy[8:3];
wire [ 3:0] subrw_raw = tile16 ? mapy[3:0] : {1'b0,mapy[2:0]};
// rom_addr is built from the JUST-READ tile word (ram_data), NOT a `code` reg:
// a reg latched this cycle still holds the PREVIOUS column's tile -> every
// column would shift one 8px column right (and the 16x16 half/code misalign
// makes even/odd columns alternate wrong). Flip comes from the same tile word.
// half-bit picks the 8px column: left (src_x[3]=0) lives in the upper 16 words
// -> half = ~src_x[3].
wire        cur_tfx = ram_data[15] & tfx_en;
wire        cur_tfy = ram_data[15] & tfy_en;
wire [ 3:0] rsubrw  = cur_tfy ? ~subrw_raw : subrw_raw;
wire        rhalf   = tile16 ? ~(cur_tfx ^ src_x[3]) : 1'b0;

wire [11:0] idx16 = { trow[5], tcol[5], trow[4:0], tcol[4:0] };
wire [11:0] idx8  = { trow[5:0], tcol[5:0] };
wire [10:0] rs_a  = {1'b0, src_y >> rs_sh};
wire [10:0] cs_a  = 11'h200 + {2'b0, ((src_x[8:0] >> cs_sh) & 9'h1ff)};
wire [ 9:0] xnew  = (scrollx[9:0] + (rowscr ? rsram_data[9:0] : 10'd0)) & wmask;
wire [ 9:0] xvisible_start = flip ? ((xnew + {1'b0,SCREEN_LAST}) & wmask) : xnew;
wire [ 9:0] xwalk_step = flip ? 10'h3f8 : 10'd8;

always @* begin
    rsram_addr = (st==XRD||st==XW1||st==XW2||st==XSET) ? rs_a : cs_a;
    ram_addr   = tile16 ? idx16 : idx8;
end

// 16x16 word layout is half-major: word-in-tile = half*16 + subrow.
wire [18:0] roma16 = rowmajor ? { bank[1:0], ram_data[11:0], rsubrw, rhalf }   // row-major: L/R halves adjacent
                              : { bank[1:0], ram_data[11:0], rhalf, rsubrw };  // half-major (default)
wire [18:0] roma8  = { 1'b0, bank[1:0], ram_data[11:0], rsubrw[2:0] };

// ---- column FIFO ----
// The producer's whole lead over the raster. Each entry is one fetched 8px
// column; the consumer drains one entry per 8 pxl_cen.
// HF1 is required by standard SDRAM command spacing. Exact replay measured
// eight queued columns plus the current column at X=0, then an empty queue
// at X=296 with the next column only reaching PUSH at its X=303 deadline.
// Larger FIFOs alone did not resolve service contention. Keep eight entries;
// immutable graphics ROM caching belongs in the shared memory frontend.
localparam FW = 3;                  // 8 columns = 64 px
reg  [36:0] fifo[0:(1<<FW)-1];      // {gfx[31:0], colour[3:0], tfx}
reg         line_restart;
reg  [FW:0] wptr, rptr;
wire        fifo_full  = wptr[FW-1:0]==rptr[FW-1:0] && wptr[FW]!=rptr[FW];
wire        fifo_empty = wptr==rptr;
wire [36:0] fifo_out   = fifo[rptr[FW-1:0]];

always @(posedge clk, posedge rst) begin
    if( rst ) begin
        st<=IDLE; HSl<=0; colcnt<=0; src_x<=0; xstart<=0; mapy<=0;
        colour<=0; tfx<=0; tfy<=0; rom_cs<=0; rom_addr<=0;
        fresh<=0; rom_good<=0; wptr<=0; line_restart<=0;
    end else begin
        HSl      <= hs;
        rom_good <= rom_ok;
        if( rom_cs && !rom_ok ) fresh <= 1;   // new read confirmed in flight
        if( hs_neg ) begin
            colcnt <= 0;
            wptr   <= 0;
            // The ROM frontend owns this address until its reply. HS expires
            // the target line, but cannot cancel or replace that transaction.
            if(rom_cs && !(fresh && rom_good && rom_ok)) begin
                st<=GFXW;
                line_restart<=1;
            end else begin
                rom_cs<=0;fresh<=0;line_restart<=0;
                st<=en ? XRD : IDLE;
            end
        end else case( st )
        IDLE: ;
        XRD:  st <= XW1;                   // rsram=rs_a issued
        XW1:  st <= XW2;
        XW2:  st <= XSET;
        XSET: begin                        // rowscroll X ready
            xstart   <= xvisible_start;
            src_x    <= xvisible_start & ~10'd7;
            st       <= CRD;
        end
        CRD:  st <= CW1;                   // rsram=cs_a(src_x) issued
        CW1:  st <= CW2;
        CW2:  st <= CSET;
        CSET: begin                        // colscroll Y ready -> mapy
            mapy <= (src_y + (colscr ? rsram_data[9:0] : 10'd0)) & hmask;
            st   <= RAMW;                  // ram_addr now combinationally valid
        end
        RAMW: st <= DEC;                   // wait 1cyc for tile RAM data
        DEC: begin                         // tile word ready -> decode + issue gfx
            // deco16ic get_pfN_tile_info: a tile that opts into per-tile flip
            // (bit 15) also drops to the low half of the palette - colour &= 7.
            // Only bites when control1[1:0] is non-zero, which cninja never sets
            // but edrandy's rowscrolled layers do.
            colour <= (ram_data[15] & (tfx_en|tfy_en)) ? {1'b0,ram_data[14:12]}
                                                       :      ram_data[15:12];
            tfx    <= cur_tfx;
            tfy    <= cur_tfy;
            rom_cs   <= 1;
            rom_addr <= tile16 ? roma16 : roma8;
            fresh    <= 0;
            st       <= GFXW;
        end
        GFXW: if( fresh && rom_good && rom_ok ) begin
            rom_cs <= 0;
            fresh  <= 0;
            if(line_restart) begin
                line_restart<=0;
                st<=en ? XRD : IDLE;
            end else begin
                gfx<=rom_data;
                st<=PUSH;
            end
        end
        PUSH: if( !fifo_full ) begin       // the only place the producer waits
            fifo[wptr[FW-1:0]] <= { gfx, colour, tfx };
            wptr     <= wptr + 1'd1;
            colcnt   <= colcnt + 6'd1;
            src_x    <= (src_x + xwalk_step) & wmask;
            st       <= (colcnt>=COLUMN_LAST) ? IDLE : CRD;
        end
        default: st <= IDLE;
        endcase
    end
end

// ---- consumer: one pixel per pxl_cen, locked to hdump ----
// Column 0 covers screen X = -xstart[2:0] .. 7-xstart[2:0], so the first
// visible pixel is that column's pixel xstart[2:0].
reg  [31:0] cgfx;
reg  [ 3:0] ccolour;
reg         ctfx, cur_vld, cactive;
reg  [ 2:0] pcnt;

wire        column_end = flip ? pcnt==3'd0 : pcnt==3'd7;
wire        pop  = ~fifo_empty & ( !cur_vld | (pxl_cen & cactive & column_end) );
// hdump updates on pxl_cen, so latch on the edge where it WRAPS to 0: pcnt and
// hdump must reach their first-visible-pixel values at the same edge.
wire        line_top = pxl_cen & hdump==H_LAST;

// 4bpp unpack: plane p lives in byte p, bit bsel (MSB-first; per-tile X flip
// reverses the bit order within the 8). pswap exchanges the two plane pairs.
wire [2:0] bsel = ctfx ? pcnt : ~pcnt;
wire [4:0] b5   = {2'b0, bsel};
wire p0 = cgfx[       b5];
wire p1 = cgfx[5'd8 + b5];
wire p2 = cgfx[5'd16+ b5];
wire p3 = cgfx[5'd24+ b5];
wire [3:0] draw_pxl = pswap ? { p1, p0, p3, p2 } : { p3, p2, p1, p0 };

// No buffer to hold a disabled layer's last line: en gates the live pixel.
assign pxl = (en & cur_vld) ? { ccolour, draw_pxl } : {PXLW{1'b0}};

always @(posedge clk, posedge rst) begin
    if( rst ) begin
        rptr<=0; cur_vld<=0; cactive<=0; pcnt<=0; cgfx<=0; ccolour<=0; ctfx<=0;
    end else begin
        if( hs_neg ) begin
            rptr <= 0; cur_vld <= 0; cactive <= 0;
        end else begin
            if( line_top ) begin
                pcnt    <= xstart[2:0];    // skip the pixels left of screen X=0
                cactive <= 1;
            end else if( pxl_cen && cactive ) pcnt <= flip ? pcnt - 3'd1 : pcnt + 3'd1;
            if( pop ) begin
                { cgfx, ccolour, ctfx } <= fifo_out;
                rptr    <= rptr + 1'd1;
                cur_vld <= 1;
            end
        end
    end
end

endmodule
