// SPDX-License-Identifier: BSD-3-Clause
// Full native pump/device/delay path. Serial words are already scaled upstream;
// AUX/processed outputs remain separate for the native gain/mix frontend.
module gs_es5510_physical(
    input wire clk,cold_reset,reset,pause,esp_halted,
    input wire host_req,host_write,input wire [7:0] host_addr,host_wdata,
    output wire host_ack,output wire [7:0] host_rdata,
    input wire sample_req,input wire [127:0] sample_input,
    output wire sample_ack,output_valid,
    output wire signed [15:0] processed_l,processed_r,aux_l,aux_r,
    output wire fault,busy,clear_busy,
    output wire [15:0] sample_cycles,max_sample_cycles,
    input wire [7:0] inspect_reg,output wire [31:0] inspect_data,
    input wire DDRAM_BUSY,output wire [7:0] DDRAM_BURSTCNT,
    output wire [28:0] DDRAM_ADDR,input wire [63:0] DDRAM_DOUT,
    input wire DDRAM_DOUT_READY,output wire DDRAM_RD,
    output wire [63:0] DDRAM_DIN,output wire [7:0] DDRAM_BE,output wire DDRAM_WE
);
    wire dram_req,dram_write,dram_ack,clear_req,clear_ack;
    wire [19:0] dram_addr;
    wire [15:0] dram_wdata,dram_rdata;
    assign clear_busy=clear_req;
    gs_es5510_pump pump(.*);
    // Warm native reset uses the clear request and drains normal transactions;
    // only cold platform reset restarts the physical command/cache controller.
    gs_es5510_delay_ddr delay_memory(
        .clk(clk),.reset(cold_reset),.req(dram_req),.write(dram_write),.addr(dram_addr),.wdata(dram_wdata),
        .ack(dram_ack),.rdata(dram_rdata),.clear_req(clear_req),.clear_ack(clear_ack),
        .DDRAM_BUSY(DDRAM_BUSY),.DDRAM_BURSTCNT(DDRAM_BURSTCNT),.DDRAM_ADDR(DDRAM_ADDR),
        .DDRAM_DOUT(DDRAM_DOUT),.DDRAM_DOUT_READY(DDRAM_DOUT_READY),.DDRAM_RD(DDRAM_RD),
        .DDRAM_DIN(DDRAM_DIN),.DDRAM_BE(DDRAM_BE),.DDRAM_WE(DDRAM_WE));
endmodule
