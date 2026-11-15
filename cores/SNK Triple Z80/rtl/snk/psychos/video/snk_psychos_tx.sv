// SPDX-License-Identifier: GPL-3.0-only
// Derived from pinned jlrh/snk-fpga; see PROVENANCE.md.
module snk_psychos_tx(
    input             rst,
    input             clk,
    input             start,
    input      [ 8:0] line,
    input             flip,
    input      [ 1:0] bank,
    input             ik,          // Ikari/Victory Road: 36x28 marvins_tx_scan_cols map, dy=8, 288 wide
    output reg        busy,
    output reg [10:0] vram_addr,
    input      [ 7:0] vram_data,
    output reg [14:0] rom_addr,
    input      [ 7:0] rom_data,
    output reg [ 8:0] buf_addr,
    output reg [ 3:0] buf_data,
    output reg        buf_we
);

reg  [ 8:0] u;
reg  [ 7:0] ty;
reg  [ 9:0] code;
reg  [31:0] pxl;
reg  [ 2:0] j;
reg  [ 1:0] b;
reg  [ 2:0] st;
reg  [ 1:0] wcnt;
reg         fl;
reg  [ 1:0] bk;
reg         ikm;
wire [ 4:0] cm2 = u[7:3] - 5'd2;
wire        outer = u[8:3] < 6'd2 || u[8:3] >= 6'd34;

localparam S_IDLE=0, S_V=1, S_VW=2, S_R=3, S_RW=4, S_DRAW=5;

reg pend;
always @(posedge clk) begin
    if( rst ) begin
        pend <= 0;
        busy <= 0; st <= S_IDLE; buf_we <= 0;
    end else begin
        buf_we <= 0;
        case( st )
            S_IDLE: if( start || pend ) begin
                busy <= 1; fl <= flip; bk <= ik ? {1'b0,bank[0]} : bank; u <= 0; ikm <= ik;
                ty   <= ik ? (line[7:0] < 8'd8 ? line[7:0] + 8'd216 : line[7:0] - 8'd8) : (flip ? 8'd223 - line[7:0] : line[7:0]);
                st   <= S_V;
            end
            S_V: begin vram_addr <= ikm ? { outer, cm2, ty[7:3] } : { u[8:3], ty[7:3] }; wcnt <= 2'd2; st <= S_VW; end
            S_VW: if( wcnt != 0 ) wcnt <= wcnt - 2'd1; else begin
                code <= { bk, 8'd0 } + { 2'd0, vram_data };
                b    <= 0;
                st   <= S_R;
            end
            S_R: begin rom_addr <= { code, ty[2:0], b }; wcnt <= 2'd2; st <= S_RW; end
            S_RW: if( wcnt != 0 ) wcnt <= wcnt - 2'd1; else begin
                pxl[ {b,3'b000} +: 8 ] <= rom_data;
                b <= b + 2'd1;
                if( b == 2'd3 ) begin j <= 0; st <= S_DRAW; end
                else st <= S_R;
            end
            S_DRAW: begin
                buf_addr <= fl ? 9'd399 - u : u;
                buf_data <= pxl[ {j,2'b00} +: 4 ];
                buf_we   <= 1;
                u <= u + 9'd1;
                j <= j + 3'd1;
                if( u == (ikm ? 9'd287 : 9'd399) ) begin busy <= 0; st <= S_IDLE; end
                else if( j == 3'd7 ) st <= S_V;
            end
            default: st <= S_IDLE;
        endcase

        if( start && st != S_IDLE ) begin
            st <= S_IDLE; busy <= 0; pend <= 1;
        end else if( st == S_IDLE ) pend <= 0;
    end
end

endmodule
