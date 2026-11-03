// SPDX-License-Identifier: GPL-3.0-or-later
// Borrow the main CPU shared-RAM window after all CPU transactions drain.
// A paused T80 may retain asserted physical pins: adapter requests/responses
// and wait_n, rather than MREQ/RD pin release, establish quiescence.
module airbustr_hiscore_bus_arbiter (
    input logic clk,reset,pause_active,memory_idle,storage_drained,
    input logic [2:0] cpu_req_valid,cpu_req_io,cpu_req_write,cpu_wait_n,
    input logic [47:0] cpu_req_addr,
    input logic [23:0] cpu_req_data,
    output logic [2:0] cpu_req_ready,cpu_rsp_valid,
    output logic [23:0] cpu_rsp_data,
    output logic [2:0] board_req_valid,board_req_io,board_req_write,
    output logic [47:0] board_req_addr,
    output logic [23:0] board_req_data,
    input logic [2:0] board_req_ready,board_rsp_valid,
    input logic [23:0] board_rsp_data,
    input logic score_req,score_write,
    input logic [12:0] score_addr,
    input logic [7:0] score_dout,
    output logic score_ack,
    output logic [7:0] score_din,
    output wire paused_quiet,owned,reset_blocked,
    output logic fault
);
    typedef enum logic [1:0] {RUN,ISSUE,RESPONSE,RELEASE} state_t;
    state_t state;
    logic [1:0] quiet_count;
    logic accepted_write;
    logic [12:0] accepted_addr;
    logic [7:0] accepted_data;
    wire quiet = pause_active && cpu_req_valid==0 && board_rsp_valid==0 &&
                 (&cpu_wait_n) && memory_idle && storage_drained;
    assign paused_quiet = quiet_count==2'd3 && quiet;
    assign owned = state!=RUN;
    assign reset_blocked = owned || score_req || fault;
    always_comb begin
        board_req_valid=cpu_req_valid;board_req_io=cpu_req_io;
        board_req_write=cpu_req_write;board_req_addr=cpu_req_addr;
        board_req_data=cpu_req_data;cpu_req_ready=board_req_ready;
        cpu_rsp_valid=board_rsp_valid;cpu_rsp_data=board_rsp_data;
        if(owned) begin
            board_req_valid=state==ISSUE ? 3'b001 : 3'b000;
            board_req_io=0;board_req_write={2'b00,accepted_write};
            board_req_addr={32'd0,3'b111,accepted_addr};
            board_req_data={16'd0,accepted_data};
            cpu_req_ready=0;cpu_rsp_valid=0;
        end
    end
    always_ff @(posedge clk) begin
        if(reset) begin
            state<=RUN;quiet_count<=0;score_ack<=0;score_din<=0;
            accepted_write<=0;accepted_addr<=0;accepted_data<=0;fault<=0;
        end else begin
            score_ack<=0;
            if(!quiet || owned)quiet_count<=0;
            else if(quiet_count!=2'd3)quiet_count<=quiet_count+2'd1;
            if(owned && (!pause_active || cpu_req_valid!=0))fault<=1;
            case(state)
                RUN:if(score_req && paused_quiet && !fault)begin
                    if(score_addr<13'h160 || score_addr>13'h19f)fault<=1;
                    else begin
                        accepted_write<=score_write;accepted_addr<=score_addr;
                        accepted_data<=score_dout;state<=ISSUE;
                    end
                end
                ISSUE:if(board_req_ready[0])state<=RESPONSE;
                RESPONSE:if(board_rsp_valid[0])begin
                    score_din<=board_rsp_data[7:0];score_ack<=1;state<=RELEASE;
                end
                RELEASE:if(!score_req)state<=RUN;
                default:begin state<=RUN;fault<=1;end
            endcase
        end
    end
endmodule
