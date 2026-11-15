// SPDX-License-Identifier: GPL-3.0-only
// Derived from pinned jlrh/snk-fpga; see PROVENANCE.md.
module snk_psychos_obj(
    input             rst,
    input             clk,
    input             start,
    input      [ 8:0] line,
    input             flip,
    input      [ 8:0] sp16_scrollx, sp16_scrolly,
    input      [ 8:0] sp32_scrollx, sp32_scrolly,
    input      [ 7:0] split,
    output reg        busy,

    output reg [ 6:0] ram_addr,
    input      [31:0] ram_data,

    output reg [17:2] s16_addr,
    output reg        s16_cs,
    input      [31:0] s16_data,
    input             s16_ok,
    output reg [18:2] s32_addr,
    output reg        s32_cs,
    input      [31:0] s32_data,
    input             s32_ok,

    input             blank_en,
    output reg [10:0] op16_addr,
    input             op16,
    output reg [ 9:0] op32_addr,
    input             op32,

    output reg [ 8:0] buf_addr,
    output reg [ 9:0] buf_data,
    output reg        buf_we,
    output reg [11:0] cycles
);

reg  [ 1:0] phase;
reg  [ 6:0] idx, last;
reg  [ 7:0] e_y, e_tile, e_x, e_attr;
reg  [ 3:0] st;
reg  [ 1:0] wcnt;
reg  [ 8:0] Yv, r, sx;
reg  [ 1:0] chunk;
reg  [ 2:0] j;
reg  [31:0] pxl;
reg         fl;
reg  [ 3:0] col;
reg  [ 8:0] scx16, scy16, scx32, scy32;
reg  [ 6:0] spl;
reg  [11:0] cyc;

wire        is32  = phase == 2'd1;
wire [ 5:0] size  = is32 ? 6'd32 : 6'd16;
wire [ 8:0] sy_c  = e_y - (is32 ? scy32 : scy16) + 9'd1 - {3'd0,size} + { e_attr[4], 8'd0 };
wire [ 8:0] sx_c  = e_x - (is32 ? scx32 : scx16) - 9'd9 + { e_attr[7], 8'd0 };
wire [ 8:0] r_c   = Yv - sy_c;
wire [ 8:0] X     = sx + { 2'd0, chunk, j };
wire [ 8:0] xs    = fl ? 9'd494 - X : X;
wire [ 3:0] pen   = { pxl[24+7-j], pxl[16+7-j], pxl[8+7-j], pxl[7-j] };
wire [ 8:0] X0    = sx + { 2'd0, chunk, 3'd0 };
wire [ 8:0] X7    = sx + { 2'd0, chunk, 3'd7 };
wire [ 8:0] xs0   = fl ? 9'd494 - X0 : X0;
wire [ 8:0] xs7   = fl ? 9'd494 - X7 : X7;

wire [ 1:0] cn    = chunk + 2'd1;
wire [ 8:0] X0n   = sx + { 2'd0, cn, 3'd0 };
wire [ 8:0] X7n   = sx + { 2'd0, cn, 3'd7 };
wire [ 8:0] xs0n  = fl ? 9'd494 - X0n : X0n;
wire [ 8:0] xs7n  = fl ? 9'd494 - X7n : X7n;
wire        lastc = chunk == (is32 ? 2'd3 : 2'd1);
wire        pf_ok = !lastc && !( xs0n >= 9'd400 && xs7n >= 9'd400 );
reg         pf;

localparam S_IDLE=0, S_NEXT=1, S_RD=2, S_RDW=3, S_CHK=4, S_FETCH=5, S_FWAIT=6, S_DRAW=7, S_BLK=8;

reg pend;
always @(posedge clk) begin
    if( rst ) begin
        pend <= 0;
        busy <= 0; st <= S_IDLE; buf_we <= 0; s16_cs <= 0; s32_cs <= 0; cycles <= 0; cyc <= 0; pf <= 0;
    end else begin
        buf_we <= 0;
        if( busy && cyc != 12'hFFF ) cyc <= cyc + 12'd1;
        case( st )
            S_IDLE: if( start || pend ) begin
                busy  <= 1; cyc <= 0;
                fl    <= flip;
                Yv    <= flip ? 9'd257 - line : line;
                scx16 <= sp16_scrollx; scy16 <= sp16_scrolly;
                scx32 <= sp32_scrollx; scy32 <= sp32_scrolly;
                spl   <= split > 8'd64 ? 7'd64 : split[6:0];
                phase <= 0; idx <= 0;
                last  <= split > 8'd64 ? 7'd64 : split[6:0];
                st    <= S_NEXT;
            end
            S_NEXT: begin
                if( idx == last ) begin
                    case( phase )
                        2'd0: begin phase <= 2'd1; idx <= 0;   last <= 7'd32; end
                        2'd1: begin phase <= 2'd2; idx <= spl; last <= 7'd64; end
                        default: begin busy <= 0; cycles <= cyc; st <= S_IDLE; end
                    endcase
                end else begin
                    st <= S_RD;
                end
            end
            S_RD: begin
                ram_addr <= { ~is32, idx[5:0] };
                wcnt <= 2'd1; st <= S_RDW;
            end
            S_RDW: if( wcnt != 0 ) wcnt <= wcnt - 2'd1; else begin
                { e_attr, e_x, e_tile, e_y } <= ram_data;
                st <= S_CHK;
            end
            S_CHK: begin
                if( r_c < {3'd0,size} ) begin
                    r     <= r_c;
                    sx    <= sx_c;

                    col   <= is32 ? e_attr[3:0] : { phase == 2'd0 || spl == 7'd0, e_attr[2:0] };
                    chunk <= 0;
                    op16_addr <= { e_attr[6:5], e_attr[3], e_tile };
                    op32_addr <= { e_attr[6:5], e_tile };
                    wcnt  <= 2'd2;
                    st    <= S_BLK;
                end else begin
                    idx <= idx + 7'd1;
                    st  <= S_NEXT;
                end
            end
            S_BLK: if( wcnt != 0 ) wcnt <= wcnt - 2'd1;
                else if( blank_en && !(is32 ? op32 : op16) ) begin
                    idx <= idx + 7'd1;
                    st  <= S_NEXT;
                end else st <= S_FETCH;
            S_FETCH: if( xs0 >= 9'd400 && xs7 >= 9'd400 ) begin
                if( chunk == (is32 ? 2'd3 : 2'd1) ) begin
                    idx <= idx + 7'd1;
                    st  <= S_NEXT;
                end else chunk <= chunk + 2'd1;
            end else begin
                if( is32 ) begin
                    s32_addr <= { e_attr[6:5], e_tile, r[4:0], ~chunk };
                    s32_cs   <= 1;
                end else begin
                    s16_addr <= { e_attr[6:5], e_attr[3], e_tile, r[3:0], ~chunk[0] };
                    s16_cs   <= 1;
                end
                wcnt <= 2'd2;
                st   <= S_FWAIT;
            end
            S_FWAIT: if( wcnt != 0 ) wcnt <= wcnt - 2'd1;
                else if( is32 ? s32_ok : s16_ok ) begin
                    pxl    <= is32 ? s32_data : s16_data;
                    s16_cs <= 0; s32_cs <= 0;
                    j      <= 0;
                    pf     <= 0;
                    if( (is32 ? s32_data : s16_data) == 32'hFFFF_FFFF ) begin
                        if( lastc ) begin idx <= idx + 7'd1; st <= S_NEXT; end
                        else begin chunk <= cn; st <= S_FETCH; end
                    end else begin
                        st <= S_DRAW;
                        if( pf_ok ) begin
                            pf <= 1;
                            if( is32 ) begin s32_addr <= { e_attr[6:5], e_tile, r[4:0], ~cn }; s32_cs <= 1; end
                            else begin s16_addr <= { e_attr[6:5], e_attr[3], e_tile, r[3:0], ~cn[0] }; s16_cs <= 1; end
                        end
                    end
                end
            S_DRAW: begin
                if( pen != 4'hF && xs < 9'd400 ) begin
                    buf_addr <= xs;
                    buf_data <= { 1'b1, is32, col, pen };
                    buf_we   <= 1;
                end
                j <= j + 3'd1;
                if( j == 3'd7 ) begin
                    if( lastc ) begin
                        idx <= idx + 7'd1;
                        st  <= S_NEXT;
                    end else begin
                        chunk <= cn;
                        if( pf ) begin wcnt <= 2'd0; st <= S_FWAIT; end
                        else st <= S_FETCH;
                    end
                end
            end
            default: st <= S_IDLE;
        endcase

        if( start && st != S_IDLE ) begin
            st <= S_IDLE; busy <= 0; pend <= 1; s16_cs <= 0; s32_cs <= 0; pf <= 0; cycles <= 12'hFFF;
        end else if( st == S_IDLE ) pend <= 0;
    end
end

endmodule
