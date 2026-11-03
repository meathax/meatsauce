// SPDX-License-Identifier: GPL-3.0-or-later
// Retain the unmodified rotator's write tuples until DDR accepts them.
module spy_ddr_write_fifo #(parameter DEPTH=512) (
    input wire clk,reset,input wire in_valid,
    input wire [28:0] in_addr,input wire [63:0] in_data,input wire [7:0] in_be,
    input wire busy,
    output wire out_valid,output wire [28:0] out_addr,
    output wire [63:0] out_data,output wire [7:0] out_be,
    output reg overflow
);
    localparam AW=$clog2(DEPTH);
    reg [100:0] memory[0:DEPTH-1];
    reg [100:0] memory_read,bypass_data;
    reg bypass_valid;
    reg [AW-1:0] read_pointer,write_pointer;
    reg [AW:0] count;
    wire pop=count!=0&&!busy;
    wire room=count<DEPTH||pop;
    wire push=in_valid&&room;
    wire [AW-1:0] next_read=read_pointer+1'b1;
    assign out_valid=count!=0&&!reset;
    assign {out_addr,out_data,out_be}=bypass_valid?bypass_data:memory_read;
    // Keep the memory output register independent of the empty-entry bypass,
    // so Quartus infers a synchronous embedded RAM rather than logic storage.
    always @(posedge clk) begin
        if(push&&!reset) memory[write_pointer]<={in_addr,in_data,in_be};
        memory_read<=memory[pop?next_read:read_pointer];
    end
    always @(posedge clk) begin
        if(reset) begin
            read_pointer<=0;write_pointer<=0;count<=0;overflow<=0;bypass_valid<=0;
        end else begin
            if(in_valid&&!room) overflow<=1;
            if(push) begin
                write_pointer<=write_pointer+1'b1;
            end
            if(pop) read_pointer<=next_read;
            case({push,pop})
                2'b10:count<=count+1'b1;
                2'b01:count<=count-1'b1;
                default:;
            endcase
            bypass_valid<=(count==0&&push)||(pop&&count==1&&push);
            if((count==0&&push)||(pop&&count==1&&push))
                bypass_data<={in_addr,in_data,in_be};
        end
    end
endmodule
