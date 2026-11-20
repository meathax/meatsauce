// SPDX-License-Identifier: GPL-3.0-or-later
// Read-only ROM front-end cache: 128 sixteen-bit words, direct mapped.
// External memory misses retain the full request until acknowledgement.
// This buffer is independent of the CPU's architectural CACR register.
module gs_rom_cache #(
    parameter bit FAST_HIT = 0,
    parameter bit FAST_MISS = 0
)(
    input logic clk,reset,cpu_req,cpu_write,
    input logic [23:0] cpu_addr,
    output logic cpu_ack,
    output logic [15:0] cpu_rdata,
    output wire mem_req,
    output wire [23:0] mem_addr,
    input logic mem_ack,
    input logic [15:0] mem_rdata
);
    logic [127:0] valid;
    // Fill and hit branches are mutually exclusive: read-during-write values
    // are never consumed. Suppress collision emulation so Quartus can infer
    // asynchronous MLAB lookup storage without changing hit latency/capacity.
    (* ramstyle="MLAB, no_rw_check" *) logic [11:0] tags [0:127];
    (* ramstyle="MLAB, no_rw_check" *) logic [15:0] words [0:127];
    logic reply_ack;
    logic [15:0] reply_data;
    logic pending;
    logic [23:0] pending_addr;
    wire [6:0] index=cpu_addr[7:1];
    wire [6:0] pending_index=pending_addr[7:1];
    // The 020 wrapper can consume an asynchronous MLAB hit on its next
    // scheduled enable. Misses keep the original registered reply protocol.
    wire fast_hit=FAST_HIT && !reset && !pending && cpu_req && !cpu_write &&
        valid[index] && tags[index]==cpu_addr[19:8];
    // Forward only an already-complete physical miss; keep the registered
    // reply as a fallback and keep normal cached-hit latency unchanged.
    wire fast_miss=FAST_MISS && !reset && pending && mem_ack;
    assign cpu_ack=(FAST_HIT || FAST_MISS) ?
        (!reset && (reply_ack || fast_hit || fast_miss)) : reply_ack;
    assign cpu_rdata=fast_miss ? mem_rdata : fast_hit ? words[index] : reply_data;
    assign mem_req=pending;
    assign mem_addr=pending_addr;
    always_ff @(posedge clk) begin
        reply_ack<=0;
        if(reset) begin
            valid<=0;
            pending<=0;
            pending_addr<=0;
            reply_data<=0;
        end else if(pending) begin
            if(mem_ack) begin
                words[pending_index]<=mem_rdata;
                tags[pending_index]<=pending_addr[19:8];
                valid[pending_index]<=1;
                reply_data<=mem_rdata;
                reply_ack<=1;
                pending<=0;
            end
        end else if(cpu_req && !cpu_ack) begin
            if(cpu_write) begin
                // The mapped ROM ignores writes, including disabled byte lanes.
                reply_ack<=1;
            end else if(valid[index] && tags[index]==cpu_addr[19:8]) begin
                reply_data<=words[index];
                reply_ack<=1;
            end else begin
                pending_addr<={cpu_addr[23:1],1'b0};
                pending<=1;
            end
        end
    end
endmodule
