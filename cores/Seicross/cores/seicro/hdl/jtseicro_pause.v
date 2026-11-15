/* SPDX-FileCopyrightText: 2026 OpenAI
 * SPDX-License-Identifier: GPL-3.0-or-later */
// Finish the active Z80 bus cycle before freezing CEs. A full nominal /16
// interval with BUSRQ held precedes resume of either CPU's enable domain.
module jtseicro_pause(
    input clk, rst, run_request, busak_n,
    output busrq_n, cpu_cen_run, sibling_run
);
localparam RUN=0, DRAIN=1, PAUSED=2, RESUME=3;
reg [1:0] state;
reg [3:0] guard_count;
assign busrq_n = state==RUN && run_request;
assign cpu_cen_run = state==RUN || state==DRAIN;
assign sibling_run = state==RUN && run_request && !rst;
always @(posedge clk) begin
    if(rst) begin
        state<=RUN;
        guard_count<=0;
    end else case(state)
        RUN: if(!run_request) state<=DRAIN;
        DRAIN: if(!busak_n) state<=PAUSED;
        PAUSED: if(run_request) begin state<=RESUME; guard_count<=0; end
        RESUME: begin
            if(!run_request) state<=PAUSED;
            else if(&guard_count) state<=RUN;
            else guard_count<=guard_count+4'd1;
        end
    endcase
end
endmodule
