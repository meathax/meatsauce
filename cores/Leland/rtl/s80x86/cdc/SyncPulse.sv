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
module SyncPulse(input logic clk,
                 input logic reset,
                 input logic d,
                 output logic p,
                 output logic q);

wire synced;
reg last_val;

assign p = synced ^ last_val;
assign q = last_val;

always_ff @(posedge clk or posedge reset)
    if (reset)
        last_val <= 1'b0;
    else
        last_val <= synced;

BitSync         BitSync(.clk(clk),
                        .reset(reset),
                        .d(d),
                        .q(synced));
endmodule
