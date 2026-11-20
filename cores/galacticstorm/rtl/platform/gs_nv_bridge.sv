// SPDX-License-Identifier: BSD-3-Clause
// Held RAM-clock upload packet to the CPU-clock EEPROM load port. The CDC
// acknowledgement returns only after the EEPROM has sampled its write pulse.
module gs_nv_bridge(
    input wire ram_clk,cpu_clk,cold_reset,
    input wire req,input wire [5:0] addr,input wire [15:0] data,
    output wire ack,
    output wire nvram_ld_wr,output wire [5:0] nvram_ld_addr,
    output wire [15:0] nvram_ld_data
);
    wire [24:0] cpu_address;
    gs_bus_cdc bridge(
        .cpu_clk(ram_clk),.ram_clk(cpu_clk),.reset(cold_reset),
        .cpu_req(req),.cpu_write(1'b1),.cpu_addr({18'b0,addr,1'b0}),
        .cpu_wdata(data),.cpu_bytes(2'b11),.cpu_ack(ack),.cpu_idle(),.cpu_rdata(),
        .ram_req(nvram_ld_wr),.ram_write(),.ram_addr(cpu_address),
        .ram_wdata(nvram_ld_data),.ram_bytes(),.ram_ack(nvram_ld_wr),.ram_rdata(16'b0));
    assign nvram_ld_addr=cpu_address[6:1];
endmodule
