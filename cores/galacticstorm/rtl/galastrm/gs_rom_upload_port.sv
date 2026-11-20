// SPDX-License-Identifier: BSD-3-Clause
// The runtime CPU and loader share the native 16-bit physical ROM port.
// A captured runtime transfer survives game reset until its physical ACK.
module gs_rom_upload_port #(parameter LINE_WRITES=0)(
    input wire clk,cold_reset,
    input wire cpu_req,cpu_write,input wire [24:0] cpu_addr,
    input wire [15:0] cpu_data,input wire [1:0] cpu_bytes,output wire cpu_ack,
    input wire cpu_write_line,input wire [63:0] cpu_wline,
    input wire download_req,download_write,input wire [24:0] download_addr,
    input wire [15:0] download_data,input wire [1:0] download_bytes,output wire download_ack,
    output wire mem_req,mem_write,output wire [24:0] mem_addr,
    output wire [15:0] mem_data,output wire [1:0] mem_bytes,input wire mem_ack,
    output wire mem_write_line,output wire [63:0] mem_wline
);
    wire [1:0] port_ack;wire [63:0] port_data;wire [7:0] port_bytes;
    wire batch=LINE_WRITES && cpu_write_line;
    gs_memory_arb2 #(.LINE_WRITES(LINE_WRITES)) ports(
        .clk(clk),.reset(cold_reset),.req({download_req,cpu_req}),
        .write({download_write,cpu_write}),.line_read(2'b0),.line_write({1'b0,batch}),.urgent0(1'b0),
        .addr({download_addr,cpu_addr}),.wdata({48'b0,download_data,(batch ? cpu_wline : {48'b0,cpu_data})}),
        .bytes({6'b0,download_bytes,(batch ? 8'hff : {6'b0,cpu_bytes})}),.ack(port_ack),.rdata(),
        .mem_req(mem_req),.mem_write(mem_write),.mem_line_read(),.mem_line_write(mem_write_line),
        .mem_addr(mem_addr),.mem_wdata(port_data),.mem_bytes(port_bytes),
        .mem_ack(mem_ack),.mem_busy(1'b0),.mem_rdata(64'b0));
    assign mem_wline=port_data;
    assign mem_data=port_data[15:0];assign mem_bytes=port_bytes[1:0];
    assign {download_ack,cpu_ack}=port_ack;
endmodule
