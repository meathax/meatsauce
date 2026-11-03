//============================================================================
// 
//  SD card ROM loader and ROM selector for MISTer.
//  Copyright (C) 2019 Kitrinx (aka Rysha)
//
//  Permission is hereby granted, free of charge, to any person obtaining a
//  copy of this software and associated documentation files (the "Software"),
//  to deal in the Software without restriction, including without limitation
//  the rights to use, copy, modify, merge, publish, distribute, sublicense,
//  and/or sell copies of the Software, and to permit persons to whom the 
//  Software is furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
//  FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
//  DEALINGS IN THE SOFTWARE.
//
//============================================================================

// Rom layout for Jackal:
// 0x0000 - 0xFFFF = eprom_1
// 0x10000 - 0x13FFF = eprom_2
// 0x14000 - 0x17FFF = eprom_3 - This ROM is duplicated to prevent data corruption during load
// 0x20000 - 0x3FFFF = maskrom_1
// 0x40000 - 0x5FFFF = maskrom_2
// 0x60000 - 0x7FFFF = maskrom_3
// 0x80000 - 0x9FFFF = maskrom_4
// 0xA0000 - 0xA00FF = prom_1
// 0xA0100 - 0xA01FF = prom_2

module selector
(
	input logic [24:0] ioctl_addr,
	output logic ep1_cs, ep2_cs, ep3_cs, mask1_cs, mask2_cs, mask3_cs, mask4_cs, prom1_cs, prom2_cs
);

	always_comb begin
		{ep1_cs, ep2_cs, ep3_cs, mask1_cs, mask2_cs, mask3_cs, mask4_cs, prom1_cs, prom2_cs} = 0;
		if(ioctl_addr < 'h10000)
			ep1_cs = 1; // 0x10000 16
		else if(ioctl_addr < 'h18000)
			ep2_cs = 1; // 0x4000 14
		else if(ioctl_addr < 'h20000)
			ep3_cs = 1; // 0x8000 15
		else if(ioctl_addr < 'h40000)
			mask1_cs = 1; // 0x20000 17
		else if(ioctl_addr < 'h60000)
			mask2_cs = 1; // 0x20000 17
		else if(ioctl_addr < 'h80000)
			mask3_cs = 1; // 0x20000 17
		else if(ioctl_addr < 'hA0000)
			mask4_cs = 1; // 0x20000 17
		else if(ioctl_addr < 'hA0100)
			prom1_cs = 1; // 0x100  8
		else
			prom2_cs = 1; // 0x100  8
	end
endmodule

////////////
// EPROMS //
////////////

module eprom_1
(
	input logic        CLK,
	input logic        CLK_DL,
	input logic [15:0] ADDR,
	input logic [24:0] ADDR_DL,
	input logic [7:0]  DATA_IN,
	input logic        CS_DL,
	input logic        WR,
	output logic [7:0] DATA
);
	dpram_dc #(.widthad_a(16)) eprom_1
	(
		.clock_a(CLK),
		.address_a(ADDR[15:0]),
		.q_a(DATA[7:0]),

		.clock_b(CLK_DL),
		.address_b(ADDR_DL[15:0]),
		.data_b(DATA_IN),
		.wren_b(WR & CS_DL)
	);
endmodule

module eprom_2
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
	dpram_dc #(.widthad_a(14)) eprom_2
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

module eprom_3
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
	dpram_dc #(.widthad_a(15)) eprom_3
	(
		.clock_a(CLK),
		.address_a(ADDR[14:0]),
		.q_a(DATA[7:0]),

		.clock_b(CLK_DL),
		.address_b(ADDR_DL[14:0]),
		.data_b(DATA_IN),
		.wren_b(WR & CS_DL)
	);
endmodule

///////////////
// MASK ROMS //
///////////////

module maskrom_1
(
	input logic        CLK,
	input logic        CLK_DL,
	input logic [15:0] ADDR,
	input logic [24:0] ADDR_DL,
	input logic [7:0]  DATA_IN,
	input logic        CS_DL,
	input logic        WR,
	output logic [7:0] DATA
);
	dpram_dc #(.widthad_a(16)) maskrom_1
	(
		.clock_a(CLK),
		.address_a(ADDR[15:0]),
		.q_a(DATA[7:0]),

		.clock_b(CLK_DL),
		.address_b(ADDR_DL[15:0]),
		.data_b(DATA_IN),
		.wren_b(WR & CS_DL)
	);
endmodule

module maskrom_2
(
	input logic        CLK,
	input logic        CLK_DL,
	input logic [15:0] ADDR,
	input logic [24:0] ADDR_DL,
	input logic [7:0]  DATA_IN,
	input logic        CS_DL,
	input logic        WR,
	output logic [7:0] DATA
);
	dpram_dc #(.widthad_a(16)) maskrom_2
	(
		.clock_a(CLK),
		.address_a(ADDR[15:0]),
		.q_a(DATA[7:0]),

		.clock_b(CLK_DL),
		.address_b(ADDR_DL[15:0]),
		.data_b(DATA_IN),
		.wren_b(WR & CS_DL)
	);
endmodule

module maskrom_3
(
	input logic        CLK,
	input logic        CLK_DL,
	input logic [15:0] ADDR,
	input logic [24:0] ADDR_DL,
	input logic [7:0]  DATA_IN,
	input logic        CS_DL,
	input logic        WR,
	output logic [7:0] DATA
);
	dpram_dc #(.widthad_a(16)) maskrom_3
	(
		.clock_a(CLK),
		.address_a(ADDR[15:0]),
		.q_a(DATA[7:0]),

		.clock_b(CLK_DL),
		.address_b(ADDR_DL[15:0]),
		.data_b(DATA_IN),
		.wren_b(WR & CS_DL)
	);
endmodule

module maskrom_4
(
	input logic        CLK,
	input logic        CLK_DL,
	input logic [15:0] ADDR,
	input logic [24:0] ADDR_DL,
	input logic [7:0]  DATA_IN,
	input logic        CS_DL,
	input logic        WR,
	output logic [7:0] DATA
);
	dpram_dc #(.widthad_a(16)) maskrom_4
	(
		.clock_a(CLK),
		.address_a(ADDR[15:0]),
		.q_a(DATA[7:0]),

		.clock_b(CLK_DL),
		.address_b(ADDR_DL[15:0]),
		.data_b(DATA_IN),
		.wren_b(WR & CS_DL)
	);
endmodule

///////////
// PROMS //
///////////

module prom_1
(
	input logic        CLK,
	input logic        CLK_DL,
	input logic [7:0]  ADDR,
	input logic [24:0] ADDR_DL,
	input logic [3:0]  DATA_IN,
	input logic        CS_DL,
	input logic        WR,
	output logic [3:0] DATA
);
	dpram_dc #(.widthad_a(8)) prom_1
	(
		.clock_a(CLK),
		.address_a(ADDR),
		.q_a(DATA[3:0]),

		.clock_b(CLK_DL),
		.address_b(ADDR_DL[7:0]),
		.data_b(DATA_IN),
		.wren_b(WR & CS_DL)
	);
endmodule

module prom_2
(
	input logic        CLK,
	input logic        CLK_DL,
	input logic [7:0]  ADDR,
	input logic [24:0] ADDR_DL,
	input logic [3:0]  DATA_IN,
	input logic        CS_DL,
	input logic        WR,
	output logic [3:0] DATA
);
	dpram_dc #(.widthad_a(8)) prom_2
	(
		.clock_a(CLK),
		.address_a(ADDR),
		.q_a(DATA[3:0]),

		.clock_b(CLK_DL),
		.address_b(ADDR_DL[7:0]),
		.data_b(DATA_IN),
		.wren_b(WR & CS_DL)
	);
endmodule
