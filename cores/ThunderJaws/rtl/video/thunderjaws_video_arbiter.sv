// SPDX-License-Identifier: GPL-3.0-or-later
// Four held read clients -> one registered VRAM auxiliary port.
// Ownership pattern follows thunderjaws_cpu_arbiter; no AS/TAS lock is needed
// for these read descriptors. Grant/address remain owned through the reply.
// Data is {paired_attribute_word,selected_word}; no extra RAM port is implied.
module thunderjaws_video_arbiter (
    input wire clk_sys,init_reset,
    input wire [3:0] request_valid,
    output wire [3:0] request_ready,
    input wire [59:0] request_address,
    output wire [3:0] response_valid,
    output wire [31:0] response_data,
    output wire backend_valid,
    input wire backend_ready,
    output reg [14:0] backend_address,
    output wire backend_snapshot,
    input wire backend_response_valid,
    input wire [31:0] backend_response_data
);
    localparam IDLE=0,ISSUE=1,REPLY=2;
    reg [1:0] state,owner,next_owner;
    reg [1:0] choose,candidate;
    reg found;
    integer index;
    always @* begin
        choose=next_owner;candidate=next_owner;found=1'b0;
        for(index=0;index<4;index=index+1)begin
            candidate=next_owner+2'(index);
            if(!found && request_valid[candidate])begin choose=candidate;found=1'b1;end
        end
    end
    assign backend_valid=!init_reset && state==ISSUE && request_valid[owner];
    assign backend_snapshot=owner!=0; // EOF remains a live CPU-state read.
    assign request_ready=backend_valid && backend_ready ? (4'b0001 << owner) : 4'b0000;
    wire returning=!init_reset && backend_response_valid &&
        (state==REPLY || (backend_valid && backend_ready));
    assign response_valid=returning ? (4'b0001 << owner) : 4'b0000;
    assign response_data=backend_response_data;
    always @(posedge clk_sys)begin
        if(init_reset)begin state<=IDLE;owner<=0;next_owner<=0;backend_address<=0;end
        else case(state)
            IDLE:if(found)begin
                owner<=choose;
                case(choose)
                    0:backend_address<=request_address[14:0];
                    1:backend_address<=request_address[29:15];
                    2:backend_address<=request_address[44:30];
                    3:backend_address<=request_address[59:45];
                endcase
                state<=ISSUE;
            end
            ISSUE:if(!request_valid[owner])begin state<=IDLE;next_owner<=owner+2'd1;end
                else if(backend_ready)begin
                    if(backend_response_valid)begin state<=IDLE;next_owner<=owner+2'd1;end
                    else state<=REPLY;
                end
            REPLY:if(backend_response_valid)begin state<=IDLE;next_owner<=owner+2'd1;end
            default:state<=IDLE;
        endcase
    end
endmodule
