// SPDX-License-Identifier: GPL-3.0-or-later
// Sound board and held program-ROM bridge, with a shared-clock granule backend.
module spinal_sound_subsystem (
    input logic clk,reset,cpu_ce,ym_ce,invalidate,bus_request,
    input logic command_write,input logic [7:0] command_data,
    output wire backend_request,output wire [24:0] backend_address,
    input logic backend_ready,input logic [63:0] backend_data,output wire program_error,
    output wire [19:0] adpcma_address,output wire [4:0] adpcma_bank,output wire adpcma_roe_n,
    input logic [7:0] adpcma_data,output wire signed [15:0] sound_l,sound_r,output wire sample,
    output wire cpu_bus_idle,program_idle,bus_ack
);
    wire request,ready;wire [3:0] region;wire [21:0] offset;wire [63:0] mapped;
    spinal_sound sound(.clk(clk),.reset(reset),.cpu_ce(cpu_ce),.ym_ce(ym_ce),.bus_request(bus_request),.bus_ack(bus_ack),
        .command_write(command_write),.command_data(command_data),.program_request(request),
        .program_region(region),.program_offset(offset),.program_ready(ready),.program_data(mapped[7:0]),
        .adpcma_address(adpcma_address),.adpcma_bank(adpcma_bank),.adpcma_roe_n(adpcma_roe_n),
        .adpcma_data(adpcma_data),.sound_l(sound_l),.sound_r(sound_r),.sample(sample),.cpu_bus_idle(cpu_bus_idle));
    spinal_rom_bridge #(.CACHE_ENABLE(1),.CACHE_LINES(64)) program_rom(.clk(clk),.reset(reset),.invalidate(invalidate),
        .request(request),.region(region),.offset(offset),.ready(ready),.error(program_error),.data(mapped),
        .backend_request(backend_request),.backend_address(backend_address),.backend_ready(backend_ready),.backend_data(backend_data),.idle(program_idle));
endmodule
