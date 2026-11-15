// SPDX-License-Identifier: GPL-3.0-or-later
// Keep each rotated pixel's Avalon write intact until waitrequest clears.
module gaiapolis_mister_rotate_fifo #(
    parameter integer AW = 8
)(
    input wire clk, push, upper, busy, drain_req,
    input wire [28:0] address,
    input wire [31:0] pixel,
    output wire [28:0] ddr_address,
    output wire [63:0] ddr_data,
    output wire [7:0] ddr_be,
    output wire ddr_write, drained,
    output reg overflow,
    output wire [AW:0] used
);
    // Reserve one RAM slot. Concurrent read/write then never alias, including
    // full-queue replacement. Together with pending, total capacity is 2**AW.
    localparam [AW:0] FULL = {1'b0,{AW{1'b1}}};
    reg [61:0] memory[0:(1<<AW)-1];
    reg [AW-1:0] write_ptr, read_ptr;
    reg [AW:0] count;
    reg [61:0] pending;
    reg valid, draining;
    initial begin
        write_ptr='0; read_ptr='0; count='0; pending='0;
        valid=1'b0; draining=1'b0; overflow=1'b0;
    end
    wire take = (!valid || !busy) && count != '0;
    // Admit the already-produced tail on the first drain-request edge.
    wire offered = push && (!drain_req || !draining);
    wire store = offered && (count != FULL || take);
    assign drained = drain_req && draining && count == '0 && !valid;
    assign used = count + {{AW{1'b0}},valid};
    assign ddr_address = pending[61:33];
    assign ddr_be = pending[32] ? 8'hf0 : 8'h0f;
    assign ddr_data = {pending[31:0],pending[31:0]};
    assign ddr_write = valid;
    always @(posedge clk) begin
        draining <= drain_req;
        if (drained) begin
            write_ptr <= '0;
            read_ptr <= '0;
            count <= '0;
            valid <= 1'b0;
            overflow <= 1'b0;
        end else begin
            if (store) begin
                memory[write_ptr] <= {address,upper,pixel};
                write_ptr <= write_ptr + {{(AW-1){1'b0}},1'b1};
            end
            if (take) begin
                pending <= memory[read_ptr];
                read_ptr <= read_ptr + {{(AW-1){1'b0}},1'b1};
                valid <= 1'b1;
            end else if (!busy) valid <= 1'b0;
            case ({store,take})
                2'b10: count <= count + {{AW{1'b0}},1'b1};
                2'b01: count <= count - {{AW{1'b0}},1'b1};
                default: ;
            endcase
            if (offered && !store) overflow <= 1'b1;
        end
`ifdef SIMULATION
        if (store && take && write_ptr == read_ptr)
            $fatal(1,"Rotation FIFO RAM ports alias");
        if (count > FULL) $fatal(1,"Rotation FIFO count invariant");
`endif
    end
endmodule
