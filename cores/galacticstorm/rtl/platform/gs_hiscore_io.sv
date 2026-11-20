// SPDX-License-Identifier: GPL-3.0-or-later
// Serialize WIDE HPS downloads into the donor's byte protocol. Config and
// scores have even lengths. Keep download asserted until the last byte retires.
module gs_hiscore_io(
    input wire clk,reset,download,wr,input wire [15:0] index,data,
    input wire [26:0] address,
    output wire wait_host,output wire hs_download,
    output reg hs_wr,output wire [24:0] hs_address,
    output wire [7:0] hs_index,output reg [7:0] hs_data
);
    reg [1:0] phase;
    reg [15:0] saved_data;
    reg [24:0] saved_address;
    reg [7:0] saved_index;
    reg [24:0] byte_address;
    wire selected=index==3 || index==4;
    assign wait_host=phase!=0 || hs_wr;
    assign hs_download=(download && selected) || wait_host;
    assign hs_address=wait_host ? byte_address : address[24:0];
    assign hs_index=wait_host ? saved_index : index[7:0];
    always @(posedge clk)begin
        hs_wr<=0;
        case(phase)
            0: if(download && selected && wr)begin
                saved_data<=data;saved_address<=address[24:0];saved_index<=index[7:0];
                byte_address<=address[24:0];phase<=1;
            end
            1: begin hs_data<=saved_data[7:0];byte_address<=saved_address;hs_wr<=1;phase<=2;end
            2: begin hs_data<=saved_data[15:8];byte_address<=saved_address+1'b1;hs_wr<=1;phase<=3;end
            3: phase<=0;
        endcase
        if(reset)begin phase<=0;hs_wr<=0;saved_data<=0;saved_address<=0;saved_index<=0;byte_address<=0;hs_data<=0;end
    end
endmodule
