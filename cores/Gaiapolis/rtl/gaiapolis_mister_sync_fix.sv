//============================================================================
//
//  MiSTer hardware abstraction module
//  (c)2017-2020 Alexey Melnikov
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//
//  This program is distributed in the hope that it will be useful, but WITHOUT
//  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
//  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
//  more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//
//============================================================================

module gaiapolis_mister_sync_fix
(
	input clk,

	input sync_in,
	output sync_out
);

assign sync_out = sync_in ^ pol;

reg pol;
always @(posedge clk) begin
	reg [31:0] cnt;
	reg s1,s2;

	s1 <= sync_in;
	s2 <= s1;
	cnt <= s2 ? (cnt - 1) : (cnt + 1);

	if(~s2 & s1) begin
		cnt <= 0;
		pol <= cnt[31];
	end
end

endmodule

