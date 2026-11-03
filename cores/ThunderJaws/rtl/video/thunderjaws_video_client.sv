// SPDX-License-Identifier: GPL-3.0-or-later
// Convert one group-fetch pulse into a held read descriptor, retaining replies.
// A response on the engine's sampling edge is forwarded before the register.
// Late is sticky: overwriting an unretired fetch is never silently accepted.
module thunderjaws_video_client (
    input wire clk_sys,init_reset,fetch,
    input wire [14:0] fetch_address,
    output wire request_valid,
    input wire request_ready,
    output reg [14:0] request_address,
    input wire response_valid,
    input wire [31:0] response_data,
    output wire [31:0] read_data,
    output reg late
);
    localparam IDLE=0,ISSUE=1,REPLY=2;
    reg [1:0] state;
    reg [31:0] held_data;
    assign request_valid=!init_reset && state==ISSUE;
    wire complete=response_valid && (state==REPLY || (request_valid && request_ready));
    assign read_data=complete ? response_data : held_data;
    always @(posedge clk_sys)begin
        if(init_reset)begin state<=IDLE;request_address<=0;held_data<=0;late<=0;end
        else begin
            if(complete)begin held_data<=response_data;state<=IDLE;end
            else if(request_valid && request_ready)state<=REPLY;
            if(fetch)begin
                if(state==IDLE || complete)begin request_address<=fetch_address;state<=ISSUE;end
                else late<=1;
            end
        end
    end
endmodule
