// SPDX-License-Identifier: GPL-3.0-or-later
// Immutable program-ROM words. Full tags; fill only from the accepted reply.
// Reset/download hold invalidates residency, never a write to cached ROM data.
// Tiny asynchronous lookup deliberately has no no_rw_check or timing exception.
module hangzo_rom_cache (
    input wire clk, reset, request,
    input wire [19:1] address,
    output wire ready,
    output wire [15:0] data,
    output wire memory_request,
    output wire [19:1] memory_address,
    input wire memory_ready,
    input wire [15:0] memory_data
);
    reg [63:0] valid;
    reg [12:0] tags [0:63];
    reg [15:0] words [0:63];
    wire [5:0] index = address[6:1];
    wire hit = valid[index] && tags[index] == address[19:7];
    assign memory_request = request && !reset && !hit;
    assign memory_address = address;
    assign ready = request && !reset && (hit || memory_ready);
    assign data = hit ? words[index] : memory_data;
    always @(posedge clk) begin
        if (reset) valid <= 0;
        else if (memory_request && memory_ready) begin
            valid[index] <= 1;
            tags[index] <= address[19:7];
            words[index] <= memory_data;
        end
    end
endmodule
