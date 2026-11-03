// SPDX-License-Identifier: GPL-3.0-or-later
// Single-clock, one-client level request to a persistent toggle request/ack.
// reset inhibits new admissions; an accepted physical transaction drains.
// Physical controller reinitialization must be coordinated separately: this
// adapter does not manufacture a new toggle phase or cancel backend work.
module spinal_sdram_toggle_adapter (
    input logic clk,reset,
    input logic request,write,
    input logic [24:0] address,
    input logic [15:0] write_data,
    output wire ready,idle,
    output logic [63:0] read_data,
    output logic physical_request=0,
    output logic [25:1] physical_address,
    output logic [15:0] physical_write_data,
    output logic physical_write,
    input logic physical_ack,
    input logic [63:0] physical_read_data
);
    typedef enum logic [1:0] {IDLE,WAIT_ACK,RESPONSE} state_t;
    state_t state=IDLE;
    assign idle=state==IDLE && physical_ack==physical_request;
    logic discard;
    // A registered response must not depend combinationally on request.
    assign ready=state==RESPONSE;
    always_ff @(posedge clk) begin
        case(state)
            IDLE: if(!reset && request && physical_ack==physical_request) begin
                physical_address<={1'b0,address[24:1]};
                physical_write_data<=write_data;physical_write<=write;
                physical_request<=~physical_request;discard<=0;state<=WAIT_ACK;
            end
            WAIT_ACK: begin
                if(!request)discard<=1;
                if(physical_ack==physical_request) begin
                    if(discard || !request)state<=IDLE;
                    else begin read_data<=physical_read_data;state<=RESPONSE;end
                end
            end
            RESPONSE: if(!request)state<=IDLE;
            default:state<=IDLE;
        endcase
    end
endmodule
