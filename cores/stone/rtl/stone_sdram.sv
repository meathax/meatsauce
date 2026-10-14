//
// sdram_stock.sv — the stock MiSTer SDRAM controller (Sorgelig, GPLv3), vendored for
// Arcade-SmashTV to replace the hand-rolled sdram_phy. DE10-proven single 16-bit port
// (addr/din/dout/wtbt/we/rd/ready), CAS-latency shift-register read capture, and — the key
// fix — it forwards SDRAM_CLK via an altddio_out I/O cell (NOT a fabric assign), so reads
// land in the valid window on real silicon. Bridged to the yunit arbiter by
// yunit_sdram_adapter.
//
// Original: Copyright (c) 2015-2019 Sorgelig. GNU GPLv3.
// Local changes: module renamed to `sdram_stock`; all declarations hoisted to module level
// (Questa rejects the upstream in-always initialized vars + forward-referenced `command`);
// the SDRAM_CLK DDIO is guarded (SIM_NO_ALTERA) so the behavioral sim needs no altera_mf.
//
module sdram_stock
(
   input             init,
   input             clk,         // ~96-100 MHz (CAS_LATENCY=2)

   inout      [15:0] SDRAM_DQ,
   output reg [12:0] SDRAM_A,
   output reg        SDRAM_DQML,
   output reg        SDRAM_DQMH,
   output reg  [1:0] SDRAM_BA,
   output            SDRAM_nCS,
   output            SDRAM_nWE,
   output            SDRAM_nRAS,
   output            SDRAM_nCAS,
   output            SDRAM_CKE,
   // NOTE: SDRAM_CLK is NOT driven here. StoneBall.sv forwards the phase-shifted PLL
   // output (outclk_1) through a pin DDIO clocked by that same output, and
   // StoneBall.sdc sources the SDRAM_CLK generated clock from it. (An earlier build
   // drove a DDIO from clk_sys while the SDC named outclk_1, so STA closed the read
   // window against the wrong clock; the DDIO and SDC source must stay the same clock.)

   input       [1:0] wtbt,        // write byte mask: [1]=high, [0]=low
   input      [24:0] addr,        // BYTE address; addr[0]=0 for 16-bit accesses
   output     [15:0] dout,
   input      [15:0] din,
   input             we,
   input             rd,
   output reg        ready
);

localparam BURST_LENGTH        = 3'b000;
localparam ACCESS_TYPE         = 1'b0;
localparam CAS_LATENCY         = 3'd2;     // 2 for < 100MHz
localparam OP_MODE             = 2'b00;
localparam NO_WRITE_BURST      = 1'b1;
localparam MODE                = {3'b000, NO_WRITE_BURST, OP_MODE, CAS_LATENCY, ACCESS_TYPE, BURST_LENGTH};

localparam sdram_startup_cycles= 14'd12100;
localparam cycles_per_refresh  = 14'd780;
localparam startup_refresh_max = 14'b11111111111111;

localparam [2:0] CMD_NOP          = 3'b111;
localparam [2:0] CMD_ACTIVE       = 3'b011;
localparam [2:0] CMD_READ         = 3'b101;
localparam [2:0] CMD_WRITE        = 3'b100;
localparam [2:0] CMD_PRECHARGE    = 3'b010;
localparam [2:0] CMD_AUTO_REFRESH = 3'b001;
localparam [2:0] CMD_LOAD_MODE    = 3'b000;

typedef enum {
	STATE_STARTUP,
	STATE_OPEN_1, STATE_OPEN_2,
	STATE_IDLE, STATE_IDLE_1, STATE_IDLE_2, STATE_IDLE_3,
	STATE_IDLE_4, STATE_IDLE_5, STATE_IDLE_6, STATE_IDLE_7
} state_t;

// all state hoisted to module level (declared before use)
reg  [2:0]  command;                       // pin-side stage (see the output register stage)
reg  [2:0]  icommand;
reg  [12:0] ia;
reg  [1:0]  iba;
reg  [15:0] idq_out;
reg         idq_oe;
reg  [13:0] refresh_count = startup_refresh_max - sdram_startup_cycles;
reg  [24:0] save_addr;
reg  [15:0] data;
reg         old_we, old_rd;
reg  [CAS_LATENCY+1:0] data_ready_delay = '0;   // +1: the output stage below delays the READ command one clock
reg         data_capture_en = 1'b0;
reg  [15:0] new_data;
reg  [1:0]  new_wtbt;
reg         new_we;
reg         new_rd;
reg         save_we = 1'b1;
state_t     state = STATE_STARTUP;
reg  [15:0] sdram_dq_out;                 // DQ drive value + tristate enable (Questa rejects
reg         sdram_dq_oe;                  // a procedurally-driven inout net, so gate it here)

assign SDRAM_DQ   = sdram_dq_oe ? sdram_dq_out : 16'bZ;
assign SDRAM_CKE  = 1;
assign SDRAM_nCS  = 0;
assign SDRAM_nRAS = command[2];
assign SDRAM_nCAS = command[1];
assign SDRAM_nWE  = command[0];
assign {SDRAM_DQMH,SDRAM_DQML} = SDRAM_A[12:11];
assign dout = save_addr[0] ? {data[7:0], data[15:8]} : {data[15:8], data[7:0]};

always @(posedge clk) begin
	idq_oe <= 1'b0;                   // release the DQ bus by default
	icommand <= CMD_NOP;
	refresh_count  <= refresh_count+1'b1;

	data_ready_delay <= {1'b0, data_ready_delay[CAS_LATENCY+1:1]};
	data_capture_en <= data_ready_delay[0];
	if(data_capture_en) ready <= 1'b1;

	case(state)
		STATE_STARTUP: begin
			ia    <= 0;
			iba   <= 0;
			if (refresh_count == startup_refresh_max-31) begin icommand <= CMD_PRECHARGE; ia[10] <= 1; iba <= 2'b00; end
			if (refresh_count == startup_refresh_max-23) icommand <= CMD_AUTO_REFRESH;
			if (refresh_count == startup_refresh_max-15) icommand <= CMD_AUTO_REFRESH;
			if (refresh_count == startup_refresh_max-7)  begin icommand <= CMD_LOAD_MODE; ia <= MODE; end
			if(refresh_count == 14'd0) begin state <= STATE_IDLE; ready <= 1; refresh_count <= 0; end
		end
		STATE_IDLE_7: state <= STATE_IDLE_6;
		STATE_IDLE_6: state <= STATE_IDLE_5;
		STATE_IDLE_5: state <= STATE_IDLE_4;
		STATE_IDLE_4: state <= STATE_IDLE_3;
		STATE_IDLE_3: state <= STATE_IDLE_2;
		STATE_IDLE_2: state <= STATE_IDLE_1;
		STATE_IDLE_1: begin
			state <= STATE_IDLE;
			if(refresh_count > cycles_per_refresh) begin state <= STATE_IDLE_7; icommand <= CMD_AUTO_REFRESH; refresh_count <= 0; end
		end
		STATE_IDLE: begin
			if(refresh_count > (cycles_per_refresh<<1)) state <= STATE_IDLE_1;
			else if(new_rd | new_we) begin
				new_we <= 0; new_rd <= 0; save_we <= new_we;
				state <= STATE_OPEN_1; icommand <= CMD_ACTIVE;
				ia <= save_addr[13:1]; iba <= save_addr[24:23];
			end
		end
		STATE_OPEN_1: state <= STATE_OPEN_2;
		STATE_OPEN_2: begin
			ia <= {save_we & ((new_wtbt != 2'b00) ? ~new_wtbt[1] : ~save_addr[0]), save_we & ((new_wtbt != 2'b00) ? ~new_wtbt[0] : save_addr[0]), 2'b10, save_addr[22:14]};
			if(save_we) begin
				icommand <= CMD_WRITE;
				idq_out <= (new_wtbt != 2'b00) ? new_data : {new_data[7:0], new_data[7:0]}; idq_oe <= 1'b1;
				ready <= 1; state <= STATE_IDLE_2;
			end
			else begin icommand <= CMD_READ; data_ready_delay[CAS_LATENCY+1] <= 1; state <= STATE_IDLE_5; end
		end
		default: state <= STATE_IDLE;
	endcase

	if(init) begin
		state <= STATE_STARTUP;
		refresh_count <= startup_refresh_max - sdram_startup_cycles;
		data_ready_delay <= '0;
		data_capture_en <= 1'b0;
	end

	old_we <= we;
	if(we & ~old_we) begin save_addr <= addr; {ready, new_we, new_data, new_wtbt} <= {1'b0, 1'b1, din, wtbt}; end

	old_rd <= rd;
	if(rd & ~old_rd) begin
		save_addr <= addr;
		if(!(ready & ~save_we & (save_addr[24:1] == addr[24:1]))) {ready, new_rd} <= {1'b0, 1'b1};
	end
end

// Output register stage. The state machine's decoded outputs used to reach the
// pin registers (DDIO/FAST_OUTPUT_REGISTER cells at the edge of the die) through
// fabric logic and up to 6 ns of routing. These plain registers take the
// decode, and the pin registers only need a short register-to-register hop.
// Every output (address, bank, command, DQ and its enable) is delayed together,
// so command spacing is unchanged; the read-data capture above is delayed one
// clock to match.
always @(posedge clk) begin
	SDRAM_A    <= ia;
	SDRAM_BA   <= iba;
	command    <= icommand;
	sdram_dq_out <= idq_out;
	sdram_dq_oe  <= idq_oe;
end

// CAS2 read data is valid at the FPGA pin from about 6.4 ns after the forwarded
// clock edge until 3.2 ns after the next one. The forwarded-clock phase in
// stone_pll.sv centres that window on the rising edge that also sets ready
// (data_capture_en still high); StoneBall.sdc checks both window edges. A
// falling-edge capture handed every consumer of the data only a half cycle.
always @(posedge clk) begin
	if(data_capture_en && !init) data <= SDRAM_DQ;
end

endmodule
