//
// sdram.v
//
// sdram controller implementation
// Copyright (c) 2018 Sorgelig
// 
// This source file is free software: you can redistribute it and/or modify 
// it under the terms of the GNU General Public License as published 
// by the Free Software Foundation, either version 3 of the License, or 
// (at your option) any later version. 
// 
// This source file is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of 
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the 
// GNU General Public License for more details.
// 
// You should have received a copy of the GNU General Public License 
// along with this program.  If not, see <http://www.gnu.org/licenses/>. 
//

// CLK_HZ: fastest clk (power-up/init cycle counts); CLK_MIN_HZ: slowest runtime PLL setting (refresh interval).
module snk_sdram #(parameter integer CLK_HZ=53600000,parameter integer READ_BURST2=0,parameter integer CLK_MIN_HZ=CLK_HZ)
(

	// interface to the MT48LC16M16 chip
	inout wire [15:0] SDRAM_DQ,   // 16 bit bidirectional data bus
	output reg [12:0] SDRAM_A,    // 13 bit multiplexed address bus
	output reg        SDRAM_DQML, // byte mask
	output reg        SDRAM_DQMH, // byte mask
	output reg  [1:0] SDRAM_BA,   // two banks
	output            SDRAM_nCS,  // a single chip select
	output reg        SDRAM_nWE,  // write enable
	output reg        SDRAM_nRAS, // row address select
	output reg        SDRAM_nCAS, // columns address select
	output            SDRAM_CLK,
	output            SDRAM_CKE,

	// cpu/chipset interface
	output wire        initialized,
	input             init,			// init signal after FPGA config to initialize RAM
	input             clk,			// sdram is accessed at up to 128MHz
	input			  clk_shifted,

	input      [24:1] addr0,
	input             wrl0,
	input             wrh0,
	input      [15:0] din0,
	output     [15:0] dout0,
	input             req0,
	output reg        ack0,
	
	input      [24:1] addr1,
	input             wrl1,
	input             wrh1,
	input      [15:0] din1,
	output     [15:0] dout1,
	input             req1,
	output reg        ack1,
	
	input      [24:1] addr2,
	input             wrl2,
	input             wrh2,
	input      [15:0] din2,
	output     [15:0] dout2,
	input             req2,
	output reg        ack2,
    output reg [15:0] dout_next=0
);

assign SDRAM_nCS = 0;
assign SDRAM_CKE = 1;
assign {SDRAM_DQMH,SDRAM_DQML} = SDRAM_A[12:11];

localparam RASCAS_DELAY   = 3'd2; // tRCD=20ns -> 2 cycles@85MHz
localparam BURST_LENGTH   = READ_BURST2 ? 3'd1 : 3'd0;
localparam ACCESS_TYPE    = 1'd0; // 0=sequential, 1=interleaved
localparam CAS_LATENCY    = 3'd2; // 2/3 allowed
localparam OP_MODE        = 2'd0; // only 0 (standard operation) allowed
localparam NO_WRITE_BURST = 1'd1; // 0=write burst enabled, 1=only single access write

localparam MODE = { 3'b000, NO_WRITE_BURST, OP_MODE, CAS_LATENCY, ACCESS_TYPE, BURST_LENGTH}; 

localparam [3:0] STATE_IDLE  = 4'd0;             // state to check the requests
localparam [3:0] STATE_START = STATE_IDLE+1'd1;  // state in which a new command is started
localparam [3:0] STATE_CONT  = STATE_START+RASCAS_DELAY;
localparam [3:0] STATE_READY = STATE_CONT+CAS_LATENCY+1'd1;  // DQ beat 0 is sampled by dq_in at the end of this state
localparam [3:0] STATE_CAP0  = STATE_READY+1'd1;             // dout <= dq_in (beat 0)
localparam [3:0] STATE_LAST  = STATE_CAP0+(READ_BURST2 ? 4'd1 : 4'd0); // burst2: dout_next <= dq_in (beat 1)

reg  [3:0] state;
// Raw DQ input register: no enable or logic so Quartus can pack it into the I/O cell (96MHz capture budget).
(* altera_attribute = "-name FAST_INPUT_REGISTER ON" *) reg [15:0] dq_in;
always @(posedge clk) dq_in <= SDRAM_DQ;
reg [22:1] a;
reg [15:0] data;
reg        we;
reg  [1:0] ba = 0;
reg  [1:0] dqm;
reg        active = 0;
reg  [2:0] ram_req = 0;
wire [2:0] wr = {wrl2|wrh2,wrl1|wrh1,wrl0|wrh0};

reg [15:0] dout;


assign dout0 = dout;
assign dout1 = dout;
assign dout2 = dout;


// Keep the forwarded clock on its own constrained PLL phase output.
// The native model below represents the constant-data DDIO cell only.
localparam integer POWERUP_CYCLES=(CLK_HZ+4999)/5000; // 200 us guard
localparam integer REFRESH_CYCLES=CLK_MIN_HZ/128000-16; // 8192 per 64 ms at the slowest clock, with service margin
reg [$clog2(POWERUP_CYCLES+1)-1:0] powerup_count=POWERUP_CYCLES;
reg init_seen=1'b1;
reg init_precharged=1'b0;
wire powerup_wait=powerup_count!=0;
reg [15:0] dq_drive;
reg dq_oe=1'b0;
assign SDRAM_DQ=dq_oe ? dq_drive : 16'hzzzz;
// Registered (96MHz timing): initialized rises/falls one clock after the controller state does.
reg initialized_r=1'b0;
always @(posedge clk) initialized_r <= !powerup_wait && reset==0 && mode==MODE_NORMAL;
assign initialized=initialized_r;
always @(posedge clk) begin
    init_seen<=init;
    if(init || (init_seen && !init)) powerup_count<=POWERUP_CYCLES;
    else if(powerup_wait) powerup_count<=powerup_count-1'b1;
    if(powerup_wait) init_precharged<=0;
    else if(mode==MODE_PRE && state==STATE_START) init_precharged<=1;
end

// access manager
always @(posedge clk) begin
	reg [9:0] rfs_cnt;
	reg rfs, rfs2;
    if(powerup_wait) begin
        state<=STATE_IDLE; active<=0; ram_req<=0;
        rfs_cnt<=0; rfs<=0; rfs2<=0;
        ack0<=0; ack1<=0; ack2<=0;
    end else begin
	
	rfs_cnt <= rfs_cnt + 1'd1;
	if (rfs_cnt == REFRESH_CYCLES-1) begin
		rfs <= 1;
		rfs_cnt <= 0;
	end

	if (rfs_cnt == REFRESH_CYCLES/2-1) rfs2 <= 1;
	
	if(state == STATE_IDLE && mode == MODE_NORMAL) begin
		if (rfs) begin
			rfs <= 0;
			rfs2 <= 0;
			rfs_cnt <= 0;
			we <= 0;
			dqm <= 2'b00;
			active <= 0;
			state <= STATE_START;
		end
		else if (ack0 != req0) begin
			{ba,a} <= addr0;
			data <= din0;
			we <= wr[0];
			dqm <= wr[0] ? ~{wrh0,wrl0} : 2'b00;
			active <= 1;
			ram_req[0] <= 1;
			rfs <= rfs2;
			state <= STATE_START;
		end
		else if (ack1 != req1) begin
			{ba,a} <= addr1;
			data <= din1;
			we <= wr[1];
			dqm <= wr[1] ? ~{wrh1,wrl1} : 2'b00;
			active <= 1;
			ram_req[1] <= 1;
			rfs <= rfs2;
			state <= STATE_START;
		end
		else if (ack2 != req2) begin
			{ba,a} <= addr2;
			data <= din2;
			we <= wr[2];
			dqm <= wr[2] ? ~{wrh2,wrl2} : 2'b00;
			active <= 1;
			ram_req[2] <= 1;
			rfs <= rfs2;
			state <= STATE_START;
		end
	end

	if(state == STATE_CAP0 && ram_req) dout <= dq_in;
    if(state == STATE_LAST && ram_req) begin
        if(READ_BURST2 && !we) dout_next <= dq_in;
		active <= 0;
		ram_req <= 0;
		if (ram_req[0]) ack0 <= req0;
		else if (ram_req[1]) ack1 <= req1;
		else if (ram_req[2]) ack2 <= req2;
	end

	if(mode != MODE_NORMAL || state != STATE_IDLE || reset) begin
		state <= state + 1'd1;
		if(state == STATE_LAST) state <= STATE_IDLE;
	end
    end
end


localparam [1:0] MODE_NORMAL = 2'b00;
localparam [1:0] MODE_RESET  = 2'b01;
localparam [1:0] MODE_LDM    = 2'b10;
localparam [1:0] MODE_PRE    = 2'b11;

// initialization 
reg [1:0] mode;
reg [4:0] reset=5'h1f;
always @(posedge clk) begin
	reg init_old=0;
	init_old <= init;

	if(powerup_wait) begin reset<=5'h1f; mode<=MODE_RESET; end
	else if(init_old & ~init) reset <= 5'h1f;
	else if(state == STATE_LAST) begin
		if(reset != 0) begin
			reset <= reset - 5'd1;
			if(reset == 14)     mode <= MODE_PRE;
			else if(reset == 3) mode <= MODE_LDM;
			else                mode <= MODE_RESET;
		end
		else mode <= MODE_NORMAL;
	end
end

localparam CMD_NOP             = 3'b111;
localparam CMD_ACTIVE          = 3'b011;
localparam CMD_READ            = 3'b101;
localparam CMD_WRITE           = 3'b100;
localparam CMD_BURST_TERMINATE = 3'b110;
localparam CMD_PRECHARGE       = 3'b010;
localparam CMD_AUTO_REFRESH    = 3'b001;
localparam CMD_LOAD_MODE       = 3'b000;

// SDRAM state machines
always @(posedge clk) begin
	if(state == STATE_START) SDRAM_BA <= (mode == MODE_NORMAL) ? ba : 2'b00;

	dq_oe <= 1'b0;
    if(powerup_wait) begin
        {SDRAM_nRAS,SDRAM_nCAS,SDRAM_nWE}<=CMD_NOP;
        SDRAM_A<=0; SDRAM_BA<=0;
    end else begin
	casex({active,we,mode,state})
		{2'bXX, MODE_NORMAL, STATE_START}: {SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} <= active ? CMD_ACTIVE : CMD_AUTO_REFRESH;
		{2'b11, MODE_NORMAL, STATE_CONT }: begin {SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE, dq_drive} <= {CMD_WRITE, data}; dq_oe<=1'b1; end
		{2'b10, MODE_NORMAL, STATE_CONT }: {SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} <= CMD_READ;

		// init
		{2'bXX, MODE_RESET, STATE_START}: {SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} <= init_precharged ? CMD_AUTO_REFRESH : CMD_NOP;
		{2'bXX,    MODE_LDM, STATE_START}: {SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} <= CMD_LOAD_MODE;
		{2'bXX,    MODE_PRE, STATE_START}: {SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} <= CMD_PRECHARGE;

		                          default: {SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} <= CMD_NOP;
	endcase

	if(mode == MODE_NORMAL) begin
		casex(state)
            // BL2 needs consecutive logical words in consecutive columns.
            // BL1 retains the pinned donor's row-first address mapping.
			STATE_START: SDRAM_A <= READ_BURST2 ? a[22:10] : a[13:1];
			STATE_CONT:  SDRAM_A <= {dqm, 2'b10, (READ_BURST2 ? a[9:1] : a[22:14])};
		endcase
	end
	else if(mode == MODE_LDM && state == STATE_START) SDRAM_A <= MODE;
	else if(mode == MODE_PRE && state == STATE_START) SDRAM_A <= 13'b0010000000000;
	else SDRAM_A <= 0;
    end
end

`ifdef VERILATOR
reg native_sdram_clock=1'b0;
always @(posedge clk_shifted or negedge clk_shifted)
    native_sdram_clock<=~clk_shifted;
assign SDRAM_CLK=native_sdram_clock;
`else
altddio_out
#(
	.extend_oe_disable("OFF"),
	.intended_device_family("Cyclone V"),
	.invert_output("OFF"),
	.lpm_hint("UNUSED"),
	.lpm_type("altddio_out"),
	.oe_reg("UNREGISTERED"),
	.power_up_high("OFF"),
	.width(1)
)
sdramclk_ddr
(
	.datain_h(1'b0),
	.datain_l(1'b1),
	.outclock(clk_shifted),
	.dataout(SDRAM_CLK),
	.aclr(1'b0),
	.aset(1'b0),
	.oe(1'b1),
	.outclocken(1'b1),
	.sclr(1'b0),
	.sset(1'b0)
);

`endif

endmodule
