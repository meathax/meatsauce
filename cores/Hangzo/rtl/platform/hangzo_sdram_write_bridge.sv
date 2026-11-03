// SPDX-License-Identifier: GPL-3.0-only
// Whole-word loader to JTFRAME programming port (PROG_LEN=16).
// Withdraw WR on ACK; return host ACK only on later RDY, held to withdrawal.
// programmer_flush must reset/cancel the associated programming FSM too.
module hangzo_sdram_write_bridge(
    input wire clk,programmer_flush,
    input wire request,
    input wire [23:0] storage_word_address,
    input wire [15:0] write_data,
    output wire acknowledged,
    output wire programmer_write,
    output wire [21:0] programmer_word_address,
    output wire [1:0] programmer_bank,
    output wire [15:0] programmer_data,
    input wire programmer_ack,programmer_rdy
);
    localparam [1:0] IDLE=0,COMMAND=1,COMPLETE=2,HOLD=3;
    reg [1:0] state,warm;
    reg [23:0] address;
    reg [15:0] data;
    assign programmer_write=!programmer_flush && state==COMMAND;
    assign programmer_word_address=address[21:0];
    assign programmer_bank=address[23:22];
    assign programmer_data=data;
    assign acknowledged=!programmer_flush && state==HOLD;
    always @(posedge clk)begin
        if(programmer_flush)begin state<=IDLE;warm<=0;address<=0;data<=0;end
        else begin
            warm<={warm[0],1'b1};
            case(state)
                IDLE:if(&warm && request && !programmer_ack && !programmer_rdy)begin
                    address<=storage_word_address;data<=write_data;state<=COMMAND;
                end
                COMMAND:if(programmer_ack)state<=COMPLETE;
                COMPLETE:if(programmer_rdy)state<=HOLD;
                HOLD:if(!request)state<=IDLE;
                default:state<=IDLE;
            endcase
        end
    end
endmodule
