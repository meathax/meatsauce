// SPDX-License-Identifier: GPL-3.0-or-later
// ThunderJaws 2816 model from MAME0.289 eeprompar.cpp/eeprom.cpp + target map.
// Reviewed Batman 28C16 donor: its physical floating-bus/any-write relock and
// timed-programming policies do not describe the verified target MAME model.
// Byte-array storage follows the pinned Atari donor RAM idiom.
// This profile commits writes immediately, as native MAME with polling disabled.
// Physical program/busy timing and MiSTer load/save coordination remain separate.
module thunderjaws_eeprom (
    input wire clk_sys,init_reset,game_reset,restore_active,
    input wire request_valid,
    output wire request_ready,
    input wire request_unlock,request_read,
    input wire [10:0] word_address,
    input wire [1:0] request_lanes,
    input wire [15:0] request_data,
    output reg response_valid,
    output reg [15:0] response_data,
    output reg unlocked,write_accepted,
    input wire load_we,
    input wire [10:0] load_address,
    input wire [7:0] load_data,
    input wire [10:0] dump_address,
    output reg [7:0] dump_data
);
    reg [7:0] mem[0:2047];
    integer i;
    initial for(i=0;i<2048;i=i+1)mem[i]=8'hff;
    assign request_ready=!init_reset && !game_reset && !restore_active && !load_we;
    wire accept=request_valid && request_ready;
    wire writing=accept && !request_unlock && !request_read && request_lanes[0] && unlocked;
    // One memory write port: explicit restore ownership takes precedence.
    always @(posedge clk_sys)begin
        if(load_we)mem[load_address]<=load_data;
        else if(writing)mem[word_address]<=request_data[7:0];
    end
    always @(posedge clk_sys)dump_data<=mem[dump_address];
    always @(posedge clk_sys)begin
        response_valid<=accept;
        write_accepted<=writing;
        if(init_reset)response_data<=0;
        else if(accept)begin
            response_data<=0;
            if(request_read && !request_unlock && request_lanes[0] && !unlocked)
                response_data<={8'h00,mem[word_address]};
        end
        if(init_reset || game_reset || restore_active)unlocked<=0;
        else if(accept && !request_read)begin
            if(request_unlock && |request_lanes)unlocked<=1;
            else if(!request_unlock && request_lanes[0])unlocked<=0;
        end
    end
endmodule
