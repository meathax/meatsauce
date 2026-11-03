// SPDX-License-Identifier: GPL-3.0-or-later
// Verify the final acknowledged word by an ordered granule read before release.
// This is a final-write/readback fence, not a whole-image integrity check.
module spinal_rom_fence (
    input logic clk,reset,download_active,image_acknowledged,
    input logic write_request,write_ack,input logic [24:0] write_address,input logic [15:0] write_data,
    output logic backend_request,output logic [24:0] backend_address,
    input logic backend_ready,input logic [63:0] backend_data,
    output wire image_verified,output logic fault
);
    typedef enum logic [1:0] {IDLE,WAIT_REPLY,DRAIN} state_t;
    state_t state=IDLE;
    logic download_q=0,have_last=0,valid=0,discard=0;
    logic [24:0] last_address,held_address;
    logic [15:0] last_data,held_data;
    wire [63:0] selected=backend_data >> (held_address[2:0]*8);
    assign image_verified=valid && image_acknowledged && !download_active && !reset;
    initial begin backend_request=0;fault=0;end
    always_ff @(posedge clk) begin
        download_q<=download_active;
        if(reset || download_active || !image_acknowledged)valid<=0;
        if(reset || (download_active && !download_q))begin have_last<=0;fault<=0;end
        if(!reset && write_request && write_ack)begin
            if(write_address[0])fault<=1;
            else begin last_address<=write_address;last_data<=write_data;have_last<=1;end
        end
        case(state)
            IDLE: if(!reset && !download_active && image_acknowledged && have_last && !valid && !fault && !backend_ready)begin
                held_address<=last_address;held_data<=last_data;backend_address<={last_address[24:3],3'b000};
                backend_request<=1;discard<=0;state<=WAIT_REPLY;
            end
            WAIT_REPLY: begin
                if(reset || download_active || !image_acknowledged)discard<=1;
                if(backend_ready)begin
                    backend_request<=0;state<=DRAIN;
                    if(!discard && !reset && !download_active && image_acknowledged)begin
                        if(selected[15:0]==held_data)valid<=1;else fault<=1;
                    end
                end
            end
            DRAIN: if(!backend_ready)state<=IDLE;
            default:begin backend_request<=0;state<=DRAIN;end
        endcase
    end
endmodule
