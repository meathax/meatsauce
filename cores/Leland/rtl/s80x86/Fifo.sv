// Copyright Jamie Iles, 2017
//
// This file is part of s80x86.
//
// s80x86 is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// s80x86 is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with s80x86.  If not, see <http://www.gnu.org/licenses/>.

// `default_nettype none -- removed for ModelSim ASE compat (false vlog-2892
// "Net type must be explicitly declared" on fully-typed ANSI ports, confirmed
// specific to `default_nettype none` + `-mfcu`; see rtl/s80x86/README_VENDORING.md).
// Every port here already has an explicit type (logic/wire/reg), so this is a
// no-op for elaboration -- default_nettype only matters for identifiers with
// NO explicit declaration, and this codebase has none of those left after the
// declare-before-use fixes.
// Parameters moved into a #(...) parameter port list, ahead of the
// signal port list that uses them (ModelSim declare-before-use; see
// Core.sv note in rtl/s80x86/README_VENDORING.md) -- equivalent modern
// ANSI-SV form of the same trailing `parameter` statements, no
// behavior change; existing `Fifo #(.data_width(...), ...)`
// instantiations are unaffected.
module Fifo #(parameter data_width = 32,
              parameter depth = 6,
              parameter full_threshold = 2) // Number of entries free to be not-full
            (input logic clk,
            input logic reset,
            input logic flush,
            // Write port
            input logic wr_en,
            input logic [data_width-1:0] wr_data,
            // Read port
            input logic rd_en,
            output logic [data_width-1:0] rd_data,
            output logic empty,
            output logic nearly_full,
            output logic full);

localparam ptr_bits = $clog2(depth);

reg [data_width-1:0] mem[depth-1:0] /* synthesis syn_ramstyle = "no_rw_check"*/;
reg [ptr_bits-1:0] rd_ptr;
reg [ptr_bits-1:0] wr_ptr;
reg [ptr_bits:0] count;

assign empty = count == 0;
assign full = count == depth;
assign nearly_full = count >= depth - full_threshold;

assign rd_data = mem[rd_ptr];

always_ff @(posedge clk or posedge reset) begin
    if (reset) begin
        wr_ptr <= {ptr_bits{1'b0}};
    end else begin
        if (flush)
            wr_ptr <= {ptr_bits{1'b0}};
        else if (wr_en && !full) begin
            mem[wr_ptr] <= wr_data;
            wr_ptr <= wr_ptr + 1'b1;
            if (wr_ptr == depth[ptr_bits-1:0] - 1'b1)
                wr_ptr <= {ptr_bits{1'b0}};
        end
    end
end

always_ff @(posedge clk or posedge reset) begin
    if (reset) begin
        rd_ptr <= {ptr_bits{1'b0}};
    end else begin
        if (flush)
            rd_ptr <= {ptr_bits{1'b0}};
        else if (rd_en && !empty) begin
            rd_ptr <= rd_ptr + 1'b1;
            if (rd_ptr == depth[ptr_bits-1:0] - 1'b1)
                rd_ptr <= {ptr_bits{1'b0}};
        end
    end
end

always_ff @(posedge clk or posedge reset) begin
    if (reset)
        count <= {ptr_bits + 1{1'b0}};
    else begin
        if (flush)
            count <= {ptr_bits + 1{1'b0}};
        else if (wr_en && !full && rd_en && !empty)
            ;
        else if (wr_en && !full)
            count <= count + 1'b1;
        else if (rd_en && !empty)
            count <= count - 1'b1;
    end
end

endmodule
