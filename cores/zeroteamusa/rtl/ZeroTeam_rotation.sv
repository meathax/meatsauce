// SPDX-License-Identifier: GPL-3.0-or-later
// Buffer the standard screen_rotate pixel writes across DDR backpressure.
module ZeroTeam_rotation (
    input wire clk,reset,
    input wire [28:0] address,
    input wire [63:0] data,
    input wire [7:0] be,
    input wire write_pixel,busy,
    output wire [28:0] ddr_address,
    output wire [63:0] ddr_data,
    output wire [7:0] ddr_be,
    output wire ddr_write,
    output reg overflow
);
    reg [10:0] head,tail;
    reg [11:0] count;
    reg [68:0] memory[0:2047];
    reg [68:0] front;
    reg loaded;
    wire pop=loaded && !busy;
    wire push=write_pixel && (count<12'd2048 || pop);
    assign ddr_address=front[68:40];
    assign ddr_be=front[39:32];
    assign ddr_data={front[31:0],front[31:0]};
    assign ddr_write=pop;
    always @(posedge clk) begin
        if(reset) begin head<=0;tail<=0;count<=0;loaded<=0;overflow<=0; end
        else begin
            if(push) begin memory[head]<={address,be,data[31:0]}; head<=head+11'd1; end
            if(write_pixel && !push) overflow<=1;
            case({push,pop})
                2'b10: count<=count+12'd1;
                2'b01: count<=count-12'd1;
                default: ;
            endcase
            if(pop) begin tail<=tail+11'd1; loaded<=0; end
            else if(!loaded && count!=0) begin front<=memory[tail]; loaded<=1; end
        end
    end
endmodule
