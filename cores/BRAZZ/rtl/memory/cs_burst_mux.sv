// SPDX-License-Identifier: GPL-3.0-or-later
// Two requesters onto the SDRAM backend's 32-byte line burst port.
// Requester A (display scanout, read-only line fetches with a raster deadline) wins
// whenever it is requesting; B (GPU) takes every other start. The backend accepts a
// burst in the cycle it is presented (burst_ready is the start), so the owner of the
// single in-flight burst is latched at acceptance and receives its done/rdata.
module cs_burst_mux (
    input logic clk, reset,
    input logic a_valid, a_region,
    input logic [17:0] a_line,
    output logic a_ready, a_done,
    input logic b_valid, b_write, b_region,
    input logic [17:0] b_line,
    input logic [7:0][31:0] b_wdata,
    input logic [7:0][3:0] b_wstrobe,
    output logic b_ready, b_done,
    output logic burst_valid, burst_write, burst_region,
    output logic [17:0] burst_line,
    output logic [7:0][31:0] burst_wdata,
    output logic [7:0][3:0] burst_wstrobe,
    input logic burst_ready, burst_done
);
    logic owner_a;
    always_comb begin
        burst_valid=a_valid || b_valid;
        burst_write=a_valid ? 1'b0 : b_write;
        burst_region=a_valid ? a_region : b_region;
        burst_line=a_valid ? a_line : b_line;
        burst_wdata=b_wdata;
        burst_wstrobe=b_wstrobe;
        a_ready=burst_ready && a_valid;
        b_ready=burst_ready && !a_valid;
        a_done=burst_done && owner_a;
        b_done=burst_done && !owner_a;
    end
    always_ff @(posedge clk)
        if(reset) owner_a<=0;
        else if(burst_ready && burst_valid) owner_a<=a_valid;
endmodule
