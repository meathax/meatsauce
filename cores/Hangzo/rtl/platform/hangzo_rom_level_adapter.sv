// SPDX-License-Identifier: GPL-3.0-only
// Bridge a level request to one owned, aligned 64-bit ready/valid read.
// Client holds address/CS until ready. A new address under held CS starts a
// fresh low/high ready epoch (sprite second half). Cold reset must also flush
// the arbiter/backend; this interface has no cancellation or generation tag.
module hangzo_rom_level_adapter #(
    parameter integer DATA_WIDTH = 32,
    parameter integer CACHE_BITS = 0
) (
    input wire clk,
    input wire cold_reset,
    input wire client_cs,
    input wire [25:0] client_byte_address,
    output wire client_ready,
    output wire [DATA_WIDTH-1:0] client_data,
    output wire request_valid,
    input wire request_ready,
    output wire [25:0] request_address,
    input wire response_valid,
    output wire response_ready,
    input wire [63:0] response_data
);
    localparam [1:0] IDLE=0, REQUEST=1, RESPONSE=2, HOLD=3;
    reg [1:0] state;
    reg [25:0] address;
    reg [DATA_WIDTH-1:0] data;
    wire owned_request_ready,owned_response_valid;
    wire [63:0] owned_response_data;
    generate if(CACHE_BITS==0)begin: uncached
        assign request_valid = !cold_reset && state==REQUEST;
        assign request_address = {address[25:3],3'b000};
        assign response_ready = !cold_reset && state==RESPONSE;
        assign owned_request_ready=request_ready;
        assign owned_response_valid=response_valid;
        assign owned_response_data=response_data;
    end else begin: cached
        // The level FSM still owns each request/low-high ready epoch.
        // Cache validity shares the arbiter/backend cold-reset/ROM epoch.
        assign owned_request_ready=1'b1;
        hangzo_rom_byte_cache #(.INDEX_BITS(CACHE_BITS),.DATA_WIDTH(64),.HASH_INDEX(1)) cache(
            .clk(clk),.cold_reset(cold_reset),.enable(state==REQUEST || state==RESPONSE),
            .byte_address({address[25:3],3'b000}),.ready(owned_response_valid),.data(owned_response_data),
            .request_valid(request_valid),.request_ready(request_ready),.request_address(request_address),
            .response_valid(response_valid),.response_ready(response_ready),.response_data(response_data));
    end endgenerate
    assign client_ready = !cold_reset && state==HOLD && client_cs &&
                          client_byte_address==address;
    assign client_data = data;
    always @(posedge clk) begin
        if(cold_reset) begin
            state<=IDLE;
            address<=0;
            data<=0;
        end else case(state)
            IDLE: if(client_cs) begin
                address<=client_byte_address;
                state<=REQUEST;
            end
            REQUEST: if(owned_request_ready) state<=RESPONSE;
            RESPONSE: if(owned_response_valid) begin
                data<=owned_response_data >> (8*address[2:0]);
                state<=HOLD;
            end
            HOLD: if(!client_cs) state<=IDLE;
                  else if(client_byte_address!=address) begin
                      address<=client_byte_address;
                      state<=REQUEST;
                  end
            default: state<=IDLE;
        endcase
    end
endmodule
