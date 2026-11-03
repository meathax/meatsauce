// SPDX-License-Identifier: GPL-3.0-only
// JTFRAME AW22/BALEN64 registered return bridge, one outstanding granule.
// Byte[24:23] selects an 8MiB bank; byte[22:1] selects its 16-bit word.
// This selects logical 32MiB geometry only, not a clock/phase or PHY timing.
// bank_flush MUST coincide with a real reset/cancel of controller bank FSMs.
// invalidate alone drains the old read and discards its result.
module hangzo_sdram_read_bridge(
    input wire clk,bank_flush,invalidate,
    input wire request_valid,
    output wire request_ready,
    input wire [25:0] request_byte_address,
    output wire response_valid,
    input wire response_ready,
    output wire [63:0] response_data,
    output wire [3:0] bank_read,
    output wire [21:0] bank_word_address,
    input wire [3:0] bank_ack,bank_dst,bank_rdy,
    input wire [15:0] bank_data,
    output reg fault
);
    localparam [2:0] IDLE=0,COMMAND=1,START=2,BEATS=3,HOLD=4;
    reg [2:0] state;
    reg [1:0] owner,beat,warm;
    reg [21:0] address;
    reg [63:0] result;
    reg discard;
    assign request_ready=&warm && !bank_flush && !invalidate && !fault && state==IDLE;
    assign response_valid=!bank_flush && !invalidate && !discard && state==HOLD;
    assign response_data=result;
    assign bank_read=(!bank_flush && state==COMMAND)?(4'b1<<owner):4'd0;
    assign bank_word_address=address;
    always @(posedge clk)begin
        if(bank_flush)begin
            state<=IDLE;owner<=0;beat<=0;warm<=0;address<=0;
            result<=0;discard<=0;fault<=0;
        end else begin
            warm<={warm[0],1'b1};
            if(invalidate && state!=IDLE)discard<=1;
            case(state)
                IDLE:if(request_valid && request_ready)begin
                    if(request_byte_address[25] || |request_byte_address[2:0])fault<=1;
                    else begin
                        owner<=request_byte_address[24:23];
                        address<=request_byte_address[22:1];
                        discard<=0;state<=COMMAND;
                    end
                end
                COMMAND:if(bank_ack[owner])begin
                    // Command acceptance is not returned data. The donor's
                    // registered DST follows later; never hold RD to RDY.
                    state<=START;
                    if(bank_dst[owner] || bank_rdy[owner])fault<=1;
                end
                START:if(bank_dst[owner])begin
                    result[15:0]<=bank_data;beat<=1;state<=BEATS;
                    if(bank_rdy[owner])fault<=1; // wrong burst profile
                end
                BEATS:begin
                    result[beat*16+:16]<=bank_data;
                    if(beat==3)begin
                        if(!bank_rdy[owner])fault<=1;
                        if(invalidate || discard)state<=IDLE;
                        else state<=HOLD;
                    end else begin
                        beat<=beat+1'b1;
                        if(bank_rdy[owner] || bank_dst[owner])fault<=1;
                    end
                end
                HOLD:if(invalidate || discard || response_ready)state<=IDLE;
                default:begin state<=IDLE;fault<=1;end
            endcase
        end
    end
endmodule
