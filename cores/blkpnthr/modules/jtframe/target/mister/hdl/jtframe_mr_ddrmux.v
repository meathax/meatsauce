/* SPDX-FileCopyrightText: 2026 Jose Tejada Gomez
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Date: 28-2-2021 */

// Vertical cores retain their existing framebuffer resource contract.
`ifdef JTFRAME_VERTICAL
`ifndef JTFRAME_FB_ROTATE
`define JTFRAME_FB_ROTATE
`endif
`endif

module jtframe_mr_ddrmux(
    input          rst,
    input          clk,
    input          ioctl_rom,
    // Fast DDR load
    input   [ 7:0] ddrld_burstcnt,
    input   [28:0] ddrld_addr,
    input          ddrld_rd,
    output         ddrld_busy,
    // Video DDR client: rotation or line-frame buffer
    input          rot_clk,
    input   [ 7:0] rot_burstcnt,
    input   [28:0] rot_addr,
    input          rot_rd,
    input          rot_we,
    input   [ 7:0] rot_be,
    input   [63:0] rot_din,
    output         rot_busy,
    // DDR Signals
    output         ddr_clk,
    input          ddr_busy,
    output  [ 7:0] ddr_burstcnt,
    output  [28:0] ddr_addr,
    output         ddr_rd,
    output  [ 7:0] ddr_be,
    output         ddr_we,
    output  [63:0] ddr_din
);

`ifdef JTFRAME_MR_DDRLOAD
    localparam DDRLOAD=1;
`else
    localparam DDRLOAD=0;
`endif

`ifdef JTFRAME_FB_ROTATE
    localparam VERTICAL=1;
`else
    localparam VERTICAL=0;
`endif

`ifdef JTFRAME_LF_BUFFER
    localparam LFBUF=1;
`else
    localparam LFBUF=0;
`endif

reg ddrld_en;

`ifdef BLKPAN_DDR_SAFE
reg reset_pending=0;
initial ddrld_en=0;
// Hold the complete selected request while waitrequest is asserted, including
// across game-local reset; reset ownership only on an acceptance boundary.
always @(posedge clk) begin
    if(rst) reset_pending<=1;
    if(!ddr_busy) begin
        if(rst || reset_pending) begin ddrld_en<=0; reset_pending<=0; end
        else ddrld_en<=ioctl_rom;
    end
end
`else
always @(posedge clk, posedge rst) begin
    if( rst ) begin
        ddrld_en <= 0;
    end else if(!ddr_busy) begin
        case( {DDRLOAD[0], VERTICAL[0] || LFBUF[0]} )
            2'b00: ddrld_en <= 0; // don't care
            2'b10: ddrld_en <= 1;
            2'b01: ddrld_en <= 0;
            2'b11: ddrld_en <= ioctl_rom;
        endcase
    end
end
`endif

assign ddr_clk = ddrld_en ? clk : rot_clk;

// This simple mux allows for bad data transfers when switching from ROM download
// to the frame buffer, but it shouldn't be a problem

assign ddr_burstcnt = ddrld_en ? ddrld_burstcnt : rot_burstcnt;
assign ddr_addr     = ddrld_en ? ddrld_addr     : rot_addr;
assign ddr_rd       = ddrld_en ? ddrld_rd       : rot_rd;
assign ddr_be       = ddrld_en ? 8'hff          : rot_be;
assign ddr_we       = ddrld_en ? 1'b0           : rot_we;
assign ddr_din      = ddrld_en ? 64'd0          : rot_din;

assign ddrld_busy   = ~ddrld_en | ddr_busy;
assign rot_busy     =  ddrld_en | ddr_busy;

endmodule