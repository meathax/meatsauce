// SPDX-License-Identifier: GPL-3.0-or-later
// CPU source RAM -> explicit DMA -> display RAM. All ports use clk.
// A source write is accepted only outside the sweep, so a copy is coherent
// against CPU writes. FRAME_LATCH adds a second DMA destination bank: only a
// completed table can be published, and its display bank stays read-only until
// the next publish. The default retains progressive palette/DMA semantics.
`timescale 1ns/1ns
module hangzo_buffered_ram #(parameter AW=10, SOURCE_FILE="", FRAME_LATCH=0) (
    input wire clk, reset,
    input wire select, write,
    input wire [AW-1:0] address,
    input wire [15:0] write_data,
    input wire [1:0] byte_enable,
    output wire ready,
    output wire [15:0] read_data,
    input wire copy_request,
    input wire publish,
    output wire copy_ready, busy,
    output reg copy_done, display_valid,
    input wire [AW-1:0] display_address,
    output wire [15:0] display_data
);
    reg pending, dma_ce, display_bank, staging_ready;
    wire dma_we;
    wire [AW-1:0] dma_address;
    wire [15:0] source_data;
    reg [1:0] age;
    assign copy_ready = !reset && !pending && !dma_we;
    assign busy = pending || dma_we;
    // Reserve the request edge too: it must not race a source write.
    wire source_available = !reset && !busy && !copy_request;
    assign ready = select && source_available && age >= 2;
    wire [1:0] source_we = byte_enable & {2{select && write && source_available && age==0}};
    always @(posedge clk) begin
        if (reset) begin
            pending <= 0;
            dma_ce <= 0;
            age <= 0;
            copy_done <= 0;
            display_valid <= 0;
            display_bank <= 0;
            staging_ready <= 0;
        end else begin
            dma_ce <= !dma_ce;
            copy_done <= 0;
            if (!select || !source_available) age <= 0;
            else if (age != 3) age <= age + 2'd1;
            if (copy_request && copy_ready) begin
                pending <= 1;
                staging_ready <= 0;
            end
            if (dma_we) pending <= 0;
            if (dma_we && dma_ce && &dma_address) begin
                copy_done <= 1;
                if (FRAME_LATCH) staging_ready <= 1;
                else display_valid <= 1;
            end
            // A copy finishing on this edge is eligible next publish only.
            if (FRAME_LATCH && publish && staging_ready && !busy && !copy_request) begin
                display_bank <= !display_bank;
                staging_ready <= 0;
                display_valid <= 1;
            end
        end
    end
    hangzo_bram_dma #(.AW(AW)) u_dma (
        .rst(reset),.clk(clk),.cen(dma_ce),.addr(dma_address),.start(pending),.we(dma_we));
    jtframe_dual_ram16 #(.AW(AW),.ENDIAN(1),.SIMFILE(SOURCE_FILE)) u_source (
        .clk0(clk),.addr0(address),.data0(write_data),.we0(source_we),.q0(read_data),
        .clk1(clk),.addr1(dma_address),.data1(16'd0),.we1(2'd0),.q1(source_data));
    generate if (FRAME_LATCH) begin: frame_table
        jtframe_dual_ram16 #(.AW(AW+1)) u_display (
            .clk0(clk),.addr0({!display_bank,dma_address}),.data0(source_data),
            .we0({2{dma_we && dma_ce && !reset}}),.q0(),
            .clk1(clk),.addr1({display_bank,display_address}),.data1(16'd0),.we1(2'd0),.q1(display_data));
    end else begin: immediate_table
        jtframe_dual_ram16 #(.AW(AW)) u_display (
            .clk0(clk),.addr0(dma_address),.data0(source_data),.we0({2{dma_we && dma_ce && !reset}}),.q0(),
            .clk1(clk),.addr1(display_address),.data1(16'd0),.we1(2'd0),.q1(display_data));
    end endgenerate
endmodule
