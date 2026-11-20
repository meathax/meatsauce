// SPDX-License-Identifier: BSD-3-Clause
// Physical delay-store port; arbitrate its DDR commands with graphics upstream.
module gs_es5510_delay_ddr(
    input wire clk,reset,
    input wire req,write,input wire [19:0] addr,input wire [15:0] wdata,
    output wire ack,output wire [15:0] rdata,
    input wire clear_req,output wire clear_ack,
    input wire DDRAM_BUSY,output wire [7:0] DDRAM_BURSTCNT,
    output wire [28:0] DDRAM_ADDR,input wire [63:0] DDRAM_DOUT,
    input wire DDRAM_DOUT_READY,output wire DDRAM_RD,
    output wire [63:0] DDRAM_DIN,output wire [7:0] DDRAM_BE,output wire DDRAM_WE
);
    wire mem_req,mem_write,mem_ack;
    wire [24:0] mem_addr;
    wire [63:0] mem_wdata,mem_rdata;
    wire [7:0] mem_bytes;
    gs_es5510_delay delay_store(.*,.busy());
    // A hashed 32 KiB coherent write-through cache shares the device budget
    // with the full MiSTer wrapper. Miss latency must meet native audio gates.
    gs_ddr_surface #(.CACHE_BITS(9),.SPLIT_CLASSES(0),.HASH_INDEX(2),.TAG_RAM(1),.WRITE_THROUGH(1)) physical(
        .clk(clk),.reset(reset),.req(mem_req),.write(mem_write),.addr(mem_addr),
        .wdata(mem_wdata),.bytes(mem_bytes),.ack(mem_ack),.rdata(mem_rdata),.busy(),
        .stream_line(1'b0),.line_valid(),.line_word(),.line_data(),
        .DDRAM_BUSY(DDRAM_BUSY),.DDRAM_BURSTCNT(DDRAM_BURSTCNT),.DDRAM_ADDR(DDRAM_ADDR),
        .DDRAM_DOUT(DDRAM_DOUT),.DDRAM_DOUT_READY(DDRAM_DOUT_READY),.DDRAM_RD(DDRAM_RD),
        .DDRAM_DIN(DDRAM_DIN),.DDRAM_BE(DDRAM_BE),.DDRAM_WE(DDRAM_WE));
endmodule
