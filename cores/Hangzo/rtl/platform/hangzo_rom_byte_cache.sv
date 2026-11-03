// SPDX-License-Identifier: GPL-3.0-only
// Read-through byte cache for an unstallable sample address stream. A miss is
// explicitly not ready: the system must prove service before the chip's sample
// capture deadline. Reset also flushes the external arbiter/backend.
module hangzo_rom_byte_cache #(
    parameter integer INDEX_BITS=3,
    parameter integer DATA_WIDTH=8,
    parameter integer HASH_INDEX=0
)(
    input wire clk,cold_reset,enable,
    input wire [25:0] byte_address,
    output wire ready,
    output wire [DATA_WIDTH-1:0] data,
    output wire request_valid,
    input wire request_ready,
    output wire [25:0] request_address,
    input wire response_valid,
    output wire response_ready,
    input wire [63:0] response_data
);
    localparam integer LINES=1<<INDEX_BITS;
    localparam integer TAG_BITS=23-INDEX_BITS;
    reg [LINES-1:0] valid;
    reg [TAG_BITS-1:0] tags[0:LINES-1];
    reg [63:0] lines[0:LINES-1];
    reg [1:0] state;
    reg [25:0] pending;
    // Fold tile-code bits into the row index; full upper tag plus hashed
    // index still uniquely identifies the complete aligned byte address.
    function [INDEX_BITS-1:0] cache_index(input [25:0] a);
        integer bit_offset;
        begin
            cache_index=a[3+:INDEX_BITS];
            if(HASH_INDEX)for(bit_offset=3+INDEX_BITS;bit_offset<26;bit_offset=bit_offset+INDEX_BITS)
                cache_index=cache_index ^ INDEX_BITS'(a>>bit_offset);
        end
    endfunction
    wire [INDEX_BITS-1:0] index=cache_index(byte_address);
    wire [TAG_BITS-1:0] tag=byte_address[25:3+INDEX_BITS];
    wire hit=valid[index] && tags[index]==tag;
    wire [INDEX_BITS-1:0] fill_index=cache_index(pending);
    assign ready=!cold_reset && enable && hit;
    assign data=ready ? (lines[index]>>(8*byte_address[2:0])) : 8'd0;
    assign request_valid=!cold_reset && state==1;
    assign request_address=pending;
    assign response_ready=!cold_reset && state==2;
    always @(posedge clk) begin
        if(cold_reset)begin valid<=0;state<=0;pending<=0;end
        else case(state)
            0:if(enable && !hit)begin pending<={byte_address[25:3],3'd0};state<=1;end
            1:if(request_ready)state<=2;
            2:if(response_valid)begin
                lines[fill_index]<=response_data;
                tags[fill_index]<=pending[25:3+INDEX_BITS];
                valid[fill_index]<=1;
                state<=0;
            end
            default:state<=0;
        endcase
    end
endmodule
