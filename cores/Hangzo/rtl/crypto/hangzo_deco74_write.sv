// SPDX-License-Identifier: GPL-3.0-or-later
// DECO74 write remap adapted from NightSlashers_MiSTer, Umberto Parisi.
// Original algorithm: MAME, Nicola Salmoria (BSD-3-Clause).
// Whole-word held REQ/ACK adapter, BEFORE Hangzo planar storage packing.
// reset must cancel the upstream loader and downstream bridge in one epoch.
module hangzo_deco74_write (
    input wire clk,reset,game_id,source_request,
    input wire [23:1] source_address,
    input wire [15:0] source_data,
    output wire source_ack,
    output wire memory_request,
    output reg [23:1] memory_address,
    output reg [15:0] memory_data,
    input wire memory_ack
);
    localparam [2:0] IDLE=0,DECODE=1,ISSUE=2,REPLY=3,DRAIN=4;
    reg [2:0] state;
    reg [23:1] pending_address;
    reg [15:0] pending_data;
    reg pending_remap;
    // physical word -> logical low11, xor-mask index4, swap-pattern index3.
    reg [17:0] decode_table [0:2047];
    reg [17:0] lookup_q;
    initial $readmemh("deco74_write.hex",decode_table);
    `include "rtl/crypto/deco74_functions.vh"
    wire [23:0] source_byte_address={source_address,1'b0};
    wire selected=game_id && ((source_byte_address>=24'h400000 && source_byte_address<24'h440000) ||
                             (source_byte_address>=24'h500000 && source_byte_address<24'h600000));
    wire [15:0] din_be={pending_data[7:0],pending_data[15:8]};
    wire [15:0] decoded_be=bitswap_apply(lookup_q[2:0],din_be ^ xor_mask(lookup_q[6:3]));
    assign source_ack=!reset && state==REPLY;
    assign memory_request=!reset && state==ISSUE;
    always @(posedge clk) begin
        if(reset) begin
            state<=IDLE;pending_address<=0;pending_data<=0;pending_remap<=0;
            lookup_q<=0;memory_address<=0;memory_data<=0;
        end else case(state)
            IDLE: if(source_request && !memory_ack) begin
                pending_address<=source_address;pending_data<=source_data;
                pending_remap<=selected;
                lookup_q<=decode_table[source_address[11:1]];
                state<=DECODE;
            end
            DECODE: begin
                memory_address<=pending_remap ? {pending_address[23:12],lookup_q[17:7]} : pending_address;
                // Preserve low-even/high-odd storage bytes after BE decryption.
                memory_data<=pending_remap ? {decoded_be[7:0],decoded_be[15:8]} : pending_data;
                state<=ISSUE;
            end
            ISSUE: if(memory_ack) state<=REPLY;
            REPLY: if(!source_request) state<=DRAIN;
            DRAIN: if(!memory_ack) state<=IDLE;
            default:state<=DRAIN;
        endcase
    end
endmodule
