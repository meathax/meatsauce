// SPDX-License-Identifier: GPL-3.0-only
// Derived from pinned jlrh/snk-fpga; see PROVENANCE.md.
module snk_psychos_bg(
    input             rst,
    input             clk,
    input             start,
    input      [ 8:0] line,
    input             flip,
    input      [ 8:0] scrollx,
    input      [ 8:0] scrolly,
    output reg        busy,

    output reg [10:0] vram_addr,
    input      [ 7:0] vram_data,

    output reg [17:2] rom_addr,
    output reg        rom_cs,
    input      [31:0] rom_data,
    input             rom_ok,

    output reg [ 8:0] buf_addr,
    output reg [ 7:0] buf_data,
    output reg        buf_we
);

reg  [ 8:0] u, Y;
reg  [ 8:0] sx_l;
reg  [ 7:0] code_lo, attr;
reg  [31:0] pxl;
reg  [ 2:0] j;
reg  [ 3:0] st;
reg  [ 1:0] wcnt;
reg         fl;
wire [ 8:0] X = sx_l + u;
wire [ 9:0] tidx = { X[8:4], Y[8:4] };

localparam S_IDLE=0, S_V0=1, S_V1=2, S_V2=3, S_ROM=4, S_RWAIT=5, S_DRAW=6;

reg pend;
always @(posedge clk) begin
    if( rst ) begin
        pend <= 0;
        busy <= 0; st <= S_IDLE; rom_cs <= 0; buf_we <= 0; u <= 0;
    end else begin
        buf_we <= 0;
        case( st )
            S_IDLE: if( start || pend ) begin
                busy <= 1;
                fl   <= flip;
                u    <= 0;
                sx_l <= scrollx - (flip ? 9'd143 : 9'd16);
                Y    <= flip ? (scrolly + 9'd255 - line) : (scrolly + line);
                st   <= S_V0;
            end
            S_V0: begin vram_addr <= { tidx, 1'b0 }; wcnt <= 2'd2; st <= S_V1; end
            S_V1: if( wcnt != 0 ) wcnt <= wcnt - 2'd1; else begin
                code_lo <= vram_data; vram_addr <= { tidx, 1'b1 }; wcnt <= 2'd2; st <= S_V2;
            end
            S_V2: if( wcnt != 0 ) wcnt <= wcnt - 2'd1; else begin
                attr <= vram_data;
                st   <= S_ROM;
            end
            S_ROM: begin
                j <= X[2:0];
                if( attr[3] ) begin
                    pxl <= 32'hFFFF_FFFF;
                    st  <= S_DRAW;
                end else begin
                    rom_addr <= { attr[2:0], code_lo, Y[3:0], X[3] };
                    rom_cs   <= 1;
                    wcnt     <= 2'd2;
                    st       <= S_RWAIT;
                end
            end
            S_RWAIT: if( wcnt != 0 ) wcnt <= wcnt - 2'd1; else if( rom_ok ) begin
                pxl    <= rom_data;
                rom_cs <= 0;
                st     <= S_DRAW;
            end
            S_DRAW: begin
                buf_addr <= fl ? 9'd399 - u : u;
                buf_data <= { attr[7:4], pxl[ {j,2'b00} +: 4 ] };
                buf_we   <= 1;
                u <= u + 9'd1;
                j <= j + 3'd1;
                if( u == 9'd399 ) begin
                    busy <= 0; st <= S_IDLE;
                end else if( j == 3'd7 ) st <= S_V0;
            end
            default: st <= S_IDLE;
        endcase

        if( start && st != S_IDLE ) begin
            st <= S_IDLE; busy <= 0; pend <= 1; rom_cs <= 0;
        end else if( st == S_IDLE ) pend <= 0;
    end
end

endmodule
