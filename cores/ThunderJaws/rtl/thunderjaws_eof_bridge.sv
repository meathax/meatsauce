// SPDX-License-Identifier: GPL-3.0-or-later
// VAD held req/ack -> VRAM auxiliary valid/ready/response contract.
// Apply measured lesson6654: retirement includes waiting for request to drop.
// No logical game reset here: an accepted read must drain to the VAD, whose
// reset state discards old data. init_reset requires coherent backend cancel.
module thunderjaws_eof_bridge (
    input wire clk_sys,init_reset,eof_req,
    input wire [5:0] eof_index,
    output wire eof_ack,
    output wire [15:0] eof_data,
    output wire aux_valid,
    input wire aux_ready,
    output reg [14:0] aux_address,
    input wire aux_response_valid,
    input wire [15:0] aux_response_data
);
    localparam IDLE=0,ISSUE=1,REPLY=2,DROP=3;
    reg [1:0] state;
    assign aux_valid=!init_reset && state==ISSUE;
    assign eof_ack=!init_reset && aux_response_valid &&
        (state==REPLY || (aux_valid && aux_ready));
    assign eof_data=aux_response_data;
    always @(posedge clk_sys)begin
        if(init_reset)begin state<=IDLE;aux_address<=0;end
        else case(state)
            IDLE:if(eof_req)begin aux_address<=15'h4780+{9'b0,eof_index};state<=ISSUE;end
            ISSUE:if(aux_ready)state<=aux_response_valid ? DROP : REPLY;
            REPLY:if(aux_response_valid)state<=DROP;
            DROP:if(!eof_req)state<=IDLE;
        endcase
    end
endmodule
