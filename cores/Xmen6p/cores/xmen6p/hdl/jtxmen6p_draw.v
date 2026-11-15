/* X-Men 6P sprite tile drawer with graphics prefetch.
 *
 * Same ports and pixel behaviour as jtframe_draw (KEEP_OLD=0, trunc unused),
 * split into two stages so SDRAM latency overlaps pixel writing:
 *  - fetch stage: accepts a tile command and fetches its two 32-bit words
 *    (first half at rom_lsb=hflip, second at ~hflip, as jtframe_draw does)
 *  - pixel stage: the jtframe_draw shift/zoom/buffer logic, fed from the
 *    prefetched words instead of waiting on rom_ok.
 * busy is high while the fetch stage holds a tile the pixel stage has not
 * taken yet, so the scanner can hand over the next tile while the current
 * one is still being written. Tiles are drawn strictly in order, so line
 * buffer writes are identical to jtframe_draw.
 * Reason: the 6P character select has ~130 tiles on one line; with
 * jtframe_draw each tile costs 2 SDRAM fetches + 16 pixel clocks in series
 * (4808 clk at latency 8 vs a 3072 clk line).
 */
module jtxmen6p_draw#( parameter
    AW       =  9,
    CW       = 12,
    PW       =  8,
    ZW       =  6,
    ZI       =  ZW-1,
    ZENLARGE =  0,
    SWAPH    =  0,
    KEEP_OLD =  0     // only 0 is supported
)(
    input               rst,
    input               clk,
    input               draw,
    output              busy,
    input    [CW-1:0]   code,
    input    [AW-1:0]   xpos,
    input      [ 3:0]   ysub,
    input      [ 1:0]   trunc,
    input    [ZW-1:0]   hzoom,
    input               hz_keep,
    input               hflip,
    input               vflip,
    input      [PW-5:0] pal,
    output     [CW+6:2] rom_addr,
    output reg          rom_cs,
    input               rom_ok,
    input      [31:0]   rom_data,
    output reg [AW-1:0] buf_addr,
    output              buf_we,
    output     [PW-1:0] buf_din
);

localparam [ZW-1:0] HZONE = { {ZW-1{1'b0}},1'b1} << ZI;

// ---------------------------------------------------------------- fetch
reg           f_full, f_half;      // tile held; second word being fetched
reg  [CW-1:0] f_code;
reg  [AW-1:0] f_xpos;
reg    [ 3:0] f_ysubf;
reg  [ZW-1:0] f_hzoom;
reg           f_hz_keep, f_hflip, f_got0, f_got1;
reg  [PW-5:0] f_pal;
reg    [31:0] f_w0, f_w1;
reg           f_lsb;
reg           f_skip;              // JTFRAME rom_ok is latched: stale for 1 clk after an address change
wire          f_ready = f_full & f_got0 & f_got1;
reg           take;                // pixel stage takes the queued tile
// one fetched tile waits in Q, so the fetch stage keeps working while the
// scanner sets up the next sprite or skips empty list entries
reg           q_full, q_hz_keep, q_hflip;
reg  [AW-1:0] q_xpos;
reg  [ZW-1:0] q_hzoom;
reg  [PW-5:0] q_pal;
reg    [31:0] q_w0, q_w1;
wire          f_move = f_ready && (!q_full || take);

// command slot C: the scanner hands over the next tile while the current one
// is still being fetched, so fetches run back to back
reg           c_full, c_hz_keep, c_hflip, c_vflip;
reg  [CW-1:0] c_code;
reg  [AW-1:0] c_xpos;
reg    [ 3:0] c_ysub;
reg  [ZW-1:0] c_hzoom;
reg  [PW-5:0] c_pal;
wire          f_free = !f_full || f_move;
wire          c_go   = c_full && f_free;

assign busy     = c_full;
assign rom_addr = { f_code, f_lsb^SWAPH[0], f_ysubf };

always @(posedge clk) begin
    if( rst ) begin
        f_full <= 0; f_got0 <= 0; f_got1 <= 0; rom_cs <= 0; f_half <= 0; f_skip <= 0; q_full <= 0; c_full <= 0;
    end else begin
        f_skip <= 0;
        if( take ) q_full <= 0;
        if( f_move ) begin
            q_full <= 1; q_xpos <= f_xpos; q_hzoom <= f_hzoom; q_hz_keep <= f_hz_keep;
            q_hflip <= f_hflip; q_pal <= f_pal; q_w0 <= f_w0; q_w1 <= f_w1;
            f_full <= 0; f_got0 <= 0; f_got1 <= 0; rom_cs <= 0;
        end
        if( c_go ) c_full <= 0;
        if( !c_full && draw ) begin
            c_full <= 1; c_code <= code; c_xpos <= xpos; c_ysub <= ysub; c_hzoom <= hzoom;
            c_hz_keep <= hz_keep; c_hflip <= hflip; c_vflip <= vflip; c_pal <= pal;
        end
        if( c_go ) begin
            f_full    <= 1;
            f_code    <= c_code;
            f_xpos    <= c_xpos;
            f_ysubf   <= c_ysub ^ {4{c_vflip}};
            f_hzoom   <= c_hzoom;
            f_hz_keep <= c_hz_keep;
            f_hflip   <= c_hflip;
            f_pal     <= c_pal;
            f_lsb     <= c_hflip;   // first half, as jtframe_draw
            f_half    <= 0;
            f_got0    <= 0;
            f_got1    <= 0;
            rom_cs    <= 1;
            f_skip    <= 1;
        end else if( f_full && rom_cs && rom_ok && !f_skip ) begin
            if( !f_half ) begin
                f_w0   <= rom_data;
                f_got0 <= 1;
                f_half <= 1;
                f_lsb  <= ~f_hflip; // second half
                f_skip <= 1;
            end else begin
                f_w1   <= rom_data;
                f_got1 <= 1;
                rom_cs <= 0;
            end
        end
    end
end

// ---------------------------------------------------------------- pixel
// jtframe_draw's datapath. cnt[3] marks "load next word": word 0 when
// p_half==0, word 1 when p_half==1.
reg      [31:0] pxl_data, p_w1;
reg      [ 3:0] cnt;
reg             p_busy, p_half, p_hflip, no_zoom;
reg    [ZW-1:0] hz_cnt, nx_hz, p_hzoom;
reg    [PW-5:0] p_pal;
reg             moveon, readon;
wire  [ZW-1:ZI] hzint = hz_cnt[ZW-1:ZI];
wire     [ 3:0] pxl = p_hflip ?
    { pxl_data[31], pxl_data[23], pxl_data[15], pxl_data[ 7] } :
    { pxl_data[24], pxl_data[16], pxl_data[ 8], pxl_data[ 0] };

assign buf_din = { p_pal, pxl };
assign buf_we  = p_busy & ~cnt[3];

always @* begin
    if( ZENLARGE==1 ) begin
        readon = hzint >= 1;
        moveon = hzint <= 1;
        nx_hz = readon ? hz_cnt - HZONE : hz_cnt;
        if( moveon  ) nx_hz = nx_hz + p_hzoom;
        if( no_zoom ) {moveon, readon} = 2'b11;
    end else begin
        readon = 1;
        { moveon, nx_hz } = {1'b1, hz_cnt}-{1'b0,p_hzoom};
    end
    take = q_full && !p_busy;
end

always @(posedge clk) begin
    if( rst ) begin
        buf_addr <= 0;
        pxl_data <= 0;
        p_busy   <= 0;
        cnt      <= 0;
        hz_cnt   <= 0;
        no_zoom  <= 0;
        p_half   <= 0;
    end else begin
        if( take ) begin
            p_busy   <= 1;
            cnt      <= 0;          // word 0 is already here
            pxl_data <= q_w0;
            p_w1     <= q_w1;
            p_half   <= 0;
            p_hflip  <= q_hflip;
            p_pal    <= q_pal;
            p_hzoom  <= q_hzoom;
            no_zoom  <= q_hzoom == HZONE || q_hzoom == 0;
            if( !q_hz_keep ) begin
                hz_cnt   <= ZENLARGE==1 ? q_hzoom : {ZW{1'b1}};
                buf_addr <= q_xpos;
            end
        end else if( p_busy ) begin
            if( cnt[3] ) begin      // second word, already fetched
                pxl_data <= p_w1;
                cnt[3]   <= 0;
                p_half   <= 1;
            end else begin
                hz_cnt   <= nx_hz;
                if( readon ) begin
                    cnt      <= cnt+1'd1;
                    pxl_data <= p_hflip ? pxl_data << 1 : pxl_data >> 1;
                end
                if( moveon ) buf_addr <= buf_addr+1'd1;
                if( cnt[2:0]==7 && readon && p_half ) p_busy <= 0; // 16 pixels
            end
        end
    end
end

endmodule
