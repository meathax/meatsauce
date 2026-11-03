//============================================================================
// 
//  SD card ROM loader and ROM selector for MISTer.
//  Copyright (C) 2019 Kitrinx (aka Rysha)
//
//  Permission is hereby granted, free of charge, to any person obtaining a
//  copy of this software and associated documentation files (the "Software"),
//  to deal in the Software without restriction, including without limitation
//	 the rights to use, copy, modify, merge, publish, distribute, sublicense,
//	 and/or sell copies of the Software, and to permit persons to whom the 
//	 Software is furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//	 all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//	 IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//	 FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//	 AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//	 LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
//	 FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
//	 DEALINGS IN THE SOFTWARE.
//
//============================================================================

// Rom layout for Taito System SJ:
// 0x00000 - 0x07FFF = eprom_0 - Main CPU Program
// 0x08000 - 0x0FFFF = eprom_1 - Main CPU Program (banked)
// 0x10000 - 0x17FFF = eprom_2 - Graphics
// 0x18000 - 0x180FF = eprom_3 - Other stuff (should probably switch to end and move sound up)
// 0x180FF - 0x184FF =           //reserved for PAL
// 0x18500 - 0x18FFF =           //reserved for MCU
// 0x19000 - 0x1A0FF = eprom_4 - Sound


module selector
(
	input logic [24:0] ioctl_addr,
	output logic ep0_cs, ep1_cs, ep2_cs, ep3_cs, ep4_cs, ep5_cs, ep6_cs, ep7_cs, ep8_cs, ep9_cs, ep10_cs, ep11_cs, ep12_cs, ep13_cs,cp1_cs,cp2_cs,cp3_cs
);

	always_comb begin
		{ep0_cs, ep1_cs, ep2_cs, ep3_cs, ep4_cs, ep5_cs, ep6_cs, ep7_cs, ep8_cs, ep9_cs, ep10_cs, ep11_cs, ep12_cs, ep13_cs,cp1_cs,cp2_cs,cp3_cs} = 0;


		if     (ioctl_addr < 'h08000) ep0_cs = 1; // 0x8000 15   - Main CPU Main ROM Bank
		else if(ioctl_addr < 'h10000) ep1_cs = 1; // 0x8000 15   - Main CPU Banked ROM
		else if(ioctl_addr < 'h18000) ep2_cs = 1; // 0x8000 14	- Graphics ROM
		else if(ioctl_addr < 'h1C000) ep3_cs = 1; // 0x8000 14   - Sound
		else if(ioctl_addr < 'h1C100) ep4_cs = 1; // 0x0100 8    - Layer PROM
		//padding from 'h1C100 to h1C7FF
		else if(ioctl_addr < 'h1D000) ep5_cs = 1; // 0x0F00 12   - MCU

		else ep6_cs = 1; // Extra ROM (FrontLine)

	end
endmodule

////////////
// EPROMS //
////////////

module eprom_0 //Main Program ROM
(
	input logic        CLK,
	input logic        CLK_DL,
	input logic        CEN,
	input logic [14:0] ADDR,
	input logic [24:0] ADDR_DL,
	input logic [7:0]  DATA_IN,
	input logic        CS_DL,
	input logic        WR,
	output logic [7:0] DATA
);

	dpram_dc #(.widthad_a(15)) eprom_0
	(
		.clock_a(CLK),
		.address_a(ADDR[14:0]),
		.q_a(DATA),
		.clock_b(CLK_DL),
		.address_b(ADDR_DL[14:0]),
		.data_b(DATA_IN),
		.wren_b(WR & CS_DL)
	);
endmodule


module eprom_1  //Banked Program ROM
(
	input logic        CLK,
	input logic        CLK_DL,
	input logic        CEN,	
	input logic [14:0] ADDR,
	input logic [24:0] ADDR_DL,
	input logic [7:0]  DATA_IN,
	input logic        CS_DL,
	input logic        WR,
	output logic [7:0] DATA
);
	
	dpram_dc #(.widthad_a(15)) eprom_1
	(
		.clock_a(CLK),
		.address_a(ADDR[14:0]),
		.q_a(DATA),
		.clock_b(CLK_DL),
		.address_b(ADDR_DL[14:0]),
		.data_b(DATA_IN),
		.wren_b(WR & CS_DL)
	);
endmodule

module eprom_2 //Graphics ROM
(
	input logic        CLK,
	input logic        CLK_DL,
	input logic [14:0] ADDR,
	input logic [24:0] ADDR_DL,
	input logic [7:0]  DATA_IN,
	input logic        CS_DL,
	input logic        WR,
	output logic [7:0] DATA
);

	dpram_dc #(.widthad_a(15)) eprom_2
	(
		.clock_a(CLK),
		.address_a(ADDR[14:0]),
		.q_a(DATA),
		.clock_b(CLK_DL),
		.address_b(ADDR_DL[14:0]),
		.data_b(DATA_IN),
		.wren_b(WR & CS_DL)
	);
endmodule

module eprom_3 //sound ROM
(
	input logic        CLK,
	input logic        CLK_DL,
	input logic [13:0] ADDR,
	input logic [24:0] ADDR_DL,
	input logic [7:0]  DATA_IN,
	input logic        CS_DL,
	input logic        WR,
	output logic [7:0] DATA
);

	dpram_dc #(.widthad_a(14)) eprom_3
	(
		.clock_a(CLK),
		.address_a(ADDR[13:0]),
		.q_a(DATA[7:0]),
		.clock_b(CLK_DL),
		.address_b(ADDR_DL[13:0]),
		.data_b(DATA_IN),
		.wren_b(WR & CS_DL)
	);
endmodule



module eprom_4 //layer ROM
(
	input logic        CLK,
	input logic        CLK_DL,
	input logic [7:0] ADDR,
	input logic [24:0] ADDR_DL,
	input logic [7:0]  DATA_IN,
	input logic        CS_DL,
	input logic        WR,
	output logic [7:0] DATA
);
	dpram_dc #(.widthad_a(8)) eprom_4
	(
		.clock_a(CLK),
		.address_a(ADDR[7:0]),
		.q_a(DATA[7:0]),

		.clock_b(CLK_DL),
		.address_b(ADDR_DL[7:0]),
		.data_b(DATA_IN),
		.wren_b(WR & CS_DL)
	);
endmodule

module eprom_mcu
(
	input logic        CLK,
	input logic        CLK_DL,
	input logic [10:0] ADDR,
	input logic [24:0] ADDR_DL,
	input logic [7:0]  DATA_IN,
	input logic        CS_DL,
	input logic        WR,
	output logic [7:0] DATA
);
	dpram_dc #(.widthad_a(11)) eprom_mcu
	(
		.clock_a(CLK),
		.address_a(ADDR[10:0]),
		.q_a(DATA[7:0]),

		.clock_b(CLK_DL),
		.address_b(ADDR_DL[10:0]),
		.data_b(DATA_IN),
		.wren_b(WR & CS_DL)
	);
endmodule


module extra_rom
(
	input logic        CLK,
	input logic        CLK_DL,
	input logic [11:0] ADDR,
	input logic [24:0] ADDR_DL,
	input logic [7:0]  DATA_IN,
	input logic        CS_DL,
	input logic        WR,
	output logic [7:0] DATA
);
	dpram_dc #(.widthad_a(12)) extra_rom
	(
		.clock_a(CLK),
		.address_a(ADDR[11:0]),
		.q_a(DATA[7:0]),

		.clock_b(CLK_DL),
		.address_b(ADDR_DL[11:0]),
		.data_b(DATA_IN),
		.wren_b(WR & CS_DL)
	);
endmodule





