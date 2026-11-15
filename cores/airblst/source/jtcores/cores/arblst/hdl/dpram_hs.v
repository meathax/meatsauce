//============================================================================
//  MAME hiscore.dat support for MiSTer arcade cores.
//
//  https://github.com/JimmyStones/Hiscores_MiSTer
//
//  Copyright (c) 2021 Alan Steremberg
//  Copyright (c) 2021 Jim Gregory
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 3 of the License, or (at your option)
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
//============================================================================
/*
 Version history:
 0001 - 2021-03-06 -	First marked release
 0002 - 2021-03-06 -	Added HS_DUMPFORMAT localparam to identify dump version (for future use)
							Add HS_CONFIGINDEX and HS_DUMPINDEX parameters to configure ioctl_indexes
 0003 - 2021-03-10 -	Added WRITE_REPEATCOUNT and WRITE_REPEATWAIT to handle tricky write situations
 0004 - 2021-03-15 -	Fix ram_access assignment
 0005 - 2021-03-18 -	Add configurable score table width, clean up some stupid mistakes
 0006 - 2021-03-27 -	Move 'tweakable' parameters into MRA data header
 0007 - 2021-04-15 -	Improve state machine maintainability, add new 'pause padding' states
 0008 - 2021-05-12 -	Feed back core-level pause to halt startup timer
 0009 - 2021-07-31 -	Split hiscore extraction from upload (updates hiscore buffer on OSD open)
 0010 - 2021-08-03 -	Add hiscore buffer and change detection (ready for autosave!)
 0011 - 2021-08-07 -	Optional auto-save on OSD open
 0012 - 2021-08-17 -	Add variable length change detection mask
 0013 - 2021-09-01 -	Output configured signal for autosave option menu masking
 0014 - 2021-09-09 -	Fix turning on autosave w/o core reload 
============================================================================
*/

module dpram_hs #(
	parameter dWidth=8,
	parameter aWidth=8
)(
	input								clk,

	input			[aWidth-1:0]	addr_a,
	input			[dWidth-1:0]	d_a,
	input								we_a,
	output reg	[dWidth-1:0]	q_a,

	input			[aWidth-1:0]	addr_b,
	input			[dWidth-1:0]	d_b,
	input								we_b,
	output reg	[dWidth-1:0]	q_b
);

reg [dWidth-1:0] ram [2**aWidth-1:0];

always @(posedge clk) begin
	if (we_a) begin 
		ram[addr_a] <= d_a;
		q_a <= d_a;
	end
	else
	begin
		q_a <= ram[addr_a];
	end

	if (we_b) begin 
		ram[addr_b] <= d_b;
		q_b <= d_b;
	end
	else
	begin
		q_b <= ram[addr_b];
	end
end

endmodule
