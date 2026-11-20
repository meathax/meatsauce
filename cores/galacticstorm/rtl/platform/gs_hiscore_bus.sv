// SPDX-License-Identifier: BSD-3-Clause
// Byte access to the MAME score table through the production SDRAM host port.
// Hold the donor state machine until the real variable-latency reply arrives.
module gs_hiscore_bus(
    input wire clk,reset,paused,read_intent,write_strobe,
    input wire [23:0] address,input wire [7:0] write_data,
    output wire ready,output reg [7:0] read_data,
    output reg req,output reg write,
    output reg [24:0] mem_addr,output reg [15:0] mem_data,
    output reg [1:0] mem_bytes,input wire ack,input wire [15:0] reply
);
    reg done;
    reg [23:0] saved_address;
    reg [7:0] saved_data;
    reg saved_write;
    wire access_wanted=read_intent || write_strobe;
    wire allowed=address>=24'h202100 && address<24'h202290;
    wire same=address==saved_address && write_strobe==saved_write &&
        (!write_strobe || write_data==saved_data);
    assign ready=!access_wanted || (paused && done && same);
    always @(posedge clk)begin
        if(!access_wanted)done<=0;
        if(req)begin
            if(ack)begin
                req<=0;done<=1;
                read_data<=saved_address[0] ? reply[7:0] : reply[15:8];
            end
        end else if(access_wanted && paused && allowed && !(done && same))begin
            saved_address<=address;saved_write<=write_strobe;saved_data<=write_data;
            mem_addr<=25'h1400000+{8'b0,address[16:1],1'b0};
            mem_data<={write_data,write_data};
            mem_bytes<=write_strobe ? (address[0] ? 2'b01 : 2'b10) : 2'b11;
            write<=write_strobe;req<=1;done<=0;
        end
        if(reset)begin
            req<=0;done<=0;read_data<=0;saved_address<=0;saved_data<=0;saved_write<=0;
            mem_addr<=0;mem_data<=0;mem_bytes<=0;write<=0;
        end
    end
endmodule
