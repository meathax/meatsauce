// SPDX-License-Identifier: GPL-3.0-or-later
// Two held CPU descriptors -> one synchronous backend, one outstanding reply.
// Reviewed Batman gfx_mem ownership pattern; its burst/client priorities do not
// implement this target interface. Round robin here is a provisional integration
// policy, not a claim about the ThunderJaws physical SRAM collision arbiter.
// CPU logical reset is handled by each bridge, which drains accepted replies.
// init_reset is legal only with coherent backend reset/cancellation.
module thunderjaws_cpu_arbiter (
    input wire clk_sys,init_reset,
    input wire [1:0] request_valid,
    output wire [1:0] request_ready,
    input wire [45:0] request_address,
    input wire [1:0] request_read,
    input wire [3:0] request_lanes,
    input wire [31:0] request_data,
    input wire [29:0] request_select,
    output wire [1:0] response_valid,
    output wire [15:0] response_data,
    output wire backend_valid,
    input wire backend_ready,
    output wire backend_owner,
    output reg [23:1] backend_address,
    output reg backend_read,
    output reg [1:0] backend_lanes,
    output reg [15:0] backend_data,
    output reg [14:0] backend_select,
    input wire backend_response_valid,
    input wire [15:0] backend_response_data,
    input wire [1:0] cycle_active
);
    localparam IDLE=0,ISSUE=1,REPLY=2;
    reg [1:0] state;
    reg owner,next_owner;
    // AS can span two DS transfers (68000 TAS). Keep arbitration ownership
    // during that gap; response ownership still follows state/owner after AS.
    reg cycle_locked,lock_owner;
    wire lock_active = cycle_locked && cycle_active[lock_owner];
    wire choose = lock_active ? lock_owner :
        (request_valid == 2'b11 ? next_owner : request_valid[1]);
    wire eligible = lock_active ? request_valid[lock_owner] : |request_valid;
    assign backend_valid = !init_reset && state==ISSUE && request_valid[owner];
    assign backend_owner = owner;
    // Keep handshake calculation separate from request selection/capture.
    assign request_ready = backend_valid && backend_ready ? (owner ? 2'b10 : 2'b01) : 2'b00;
    wire returning = !init_reset && backend_response_valid &&
        (state==REPLY || (backend_valid && backend_ready));
    assign response_valid = returning ? (owner ? 2'b10 : 2'b01) : 2'b00;
    assign response_data = backend_response_data;
    always @(posedge clk_sys) begin
        if(init_reset) begin
            state<=IDLE;owner<=0;next_owner<=0;
            cycle_locked<=0;lock_owner<=0;
            backend_address<=0;backend_read<=1;backend_lanes<=0;
            backend_data<=0;backend_select<=0;
        end else begin
            if(cycle_locked && !cycle_active[lock_owner]) cycle_locked<=0;
            if(backend_valid && backend_ready && cycle_active[owner]) begin
                cycle_locked<=1;lock_owner<=owner;
            end
            case(state)
            IDLE: if(eligible) begin
                owner<=choose;
                backend_address<=choose ? request_address[45:23] : request_address[22:0];
                backend_read<=request_read[choose];
                backend_lanes<=choose ? request_lanes[3:2] : request_lanes[1:0];
                backend_data<=choose ? request_data[31:16] : request_data[15:0];
                backend_select<=choose ? request_select[29:15] : request_select[14:0];
                state<=ISSUE;
            end
            ISSUE: begin
                if(!request_valid[owner]) begin state<=IDLE;next_owner<=!owner;end
                else if(backend_ready) begin
                    if(backend_response_valid)begin state<=IDLE;next_owner<=!owner;end
                    else state<=REPLY;
                end
            end
            REPLY: if(backend_response_valid)begin state<=IDLE;next_owner<=!owner;end
            default: state<=IDLE;
        endcase
        end
    end
endmodule
