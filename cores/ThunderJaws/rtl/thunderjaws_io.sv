// SPDX-License-Identifier: GPL-3.0-or-later
// Target-specific commit glue, from MAME0.289 thunderj.cpp367..397/404..449.
// Reviewed SkullXBones main-board I/O; its latch bits and maps differ.
// All inputs are coherent clk_sys-domain signals. commit is one accepted
// transaction, not the CPU's held AS or a data-strobe level.
module thunderjaws_io (
    input wire clk_sys,init_reset,commit,request_read,
    input wire [14:0] request_select,
    input wire [1:0] request_lanes,
    input wire [15:0] request_data,
    input wire [15:0] port_260000,port_260010,port_260012,
    input wire [7:0] sound_response,
    output reg [15:0] read_data,
    output reg extra_reset_hold,
    output reg [2:0] alpha_bank,
    output wire watchdog_kick,sound_reset_request,sound_command_write,
    output wire [7:0] sound_command_data,
    output wire sound_response_ack
);
    wire active=commit && !init_reset;
    assign watchdog_kick=active && !request_read && request_select[8];
    assign sound_reset_request=active && !request_read && request_select[10];
    assign sound_command_write=active && !request_read && request_select[11] && request_lanes[0];
    assign sound_command_data=request_data[7:0];
    assign sound_response_ack=active && request_read && request_select[7] && request_lanes[0];
    always @(posedge clk_sys) begin
        // MAME starts both CPUs normally; the first low-byte latch write can
        // assert extra reset. Alpha bank is initialized at machine creation.
        // External game/watchdog reset routing is not implemented here.
        if(init_reset)begin extra_reset_hold<=0;alpha_bank<=0;end
        else if(active && !request_read && request_select[9] && request_lanes[0])begin
            extra_reset_hold<=!request_data[0];
            // Handler mask is 7: bit5 is ignored despite its stale comment.
            alpha_bank<=request_data[4:2];
        end
    end
    always @* begin
        read_data=16'h0000;
        if(request_read)begin
            if(request_select[4])read_data=port_260000;
            else if(request_select[5])read_data=port_260010;
            else if(request_select[6])read_data=port_260012 ^ 16'h0010;
            else if(request_select[7] && request_lanes[0])read_data={8'h00,sound_response};
        end
    end
endmodule
