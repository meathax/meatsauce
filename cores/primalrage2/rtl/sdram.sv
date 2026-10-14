//
// sdram
// Copyright (c) 2015-2019 Sorgelig
//
// Some parts of SDRAM code used from project:
// http://hamsterworks.co.nz/mediawiki/index.php/Simple_SDRAM_Controller
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

module sdram
(
	input              init,        // reset to initialize RAM
	input              clk,         // clock ~100MHz
	input              clk_base,    // clock ~33MHz
                      
	input              SDRAM_EN,    // Set all output SDRAM_* signals to Z ASAP if SDRAM2_EN is 0 
   
	inout wire [15:0]  SDRAM_DQ,    // 16 bit bidirectional data bus
	output wire [12:0] SDRAM_A,     // 13 bit multiplexed address bus
	output             SDRAM_DQML,  // two byte masks
	output             SDRAM_DQMH,  // 
	output wire [1:0]  SDRAM_BA,    // two banks
	output             SDRAM_nCS,   // a single chip select
	output             SDRAM_nWE,   // write enable
	output             SDRAM_nRAS,  // row address select
	output             SDRAM_nCAS,  // columns address select
	output             SDRAM_CKE,   // clock enable
	// Inverted controller clock, forwarded through a DDR output cell.
	// Connect this output to the physical SDRAM clock pin.
	output             SDRAM_CLK,

	input              refreshForce,
	input              pagemode_en, // 1=enable ch1 page-mode (skip CMD_ACTIVE on same-row hits)
	output             ram_idle,    // used to tell the core a write command on ch2 will be accepted instantly

	input      [26:0]  ch1_addr,    // 25 bit address for 8bit mode. addr[0] = 0 for 16bit mode for correct operations.
	output reg [127:0] ch1_dout,    // data output to cpu
	output reg [31:0]  ch1_dout32,  // data output to cpu
	input      [15:0]  ch1_din,     // data input from cpu
	input              ch1_req,     // request
	input              ch1_rnw,     // 1 - read, 0 - write
	input              ch1_dma,     // 1 - read 128bit for dma
	input      [ 1:0]  ch1_cntDMA,  // count of words-1 for dma read
	input              ch1_cache,   // 1 - read 128bit for cache
	output reg         ch1_ready,
	output reg [ 3:0]  cache_wr,    
	output reg [31:0]  cache_data,  
	output reg [ 7:0]  cache_addr,  
	output reg         dma_wr,  
	output reg         dma_reqprocessed,  
	output reg [31:0]  dma_data,  

	input      [26:0]  ch2_addr,    // 25 bit address for 8bit mode. addr[0] = 0 for 16bit mode for correct operations.
	output reg [31:0]  ch2_dout,    // data output to cpu
	input      [31:0]  ch2_din,     // data input from cpu
	input              ch2_req,     // request
	input              ch2_rnw,     // 1 - read, 0 - write
   input      [3:0]   ch2_be,      
	output reg         ch2_ready,
                      
	input      [26:0]  ch3_addr,    // 25 bit address for 8bit mode. addr[0] = 0 for 16bit mode for correct operations.
	output reg [31:0]  ch3_dout,    // data output to cpu
	input      [31:0]  ch3_din,     // data input from cpu
	input              ch3_req,     // request
	input              ch3_rnw,     // 1 - read, 0 - write
	input      [3:0]   ch3_be,
	output reg         ch3_ready,

	input      [26:0]  dmafifo_adr,
	input      [31:0]  dmafifo_data,
	input              dmafifo_empty,
	output reg         dmafifo_read,

	// B-pm-probe: sticky latches for page-mode FSM events (debug-bar observability)
	output reg         dbg_pm_hit  = 1'b0,  // page-mode HIT (skip-ACTIVE) path ever taken
	output reg         dbg_pm_open = 1'b0,  // page-mode ACTIVE left a row open (pagemode_en path) ever
	output reg         dbg_pm_pre  = 1'b0,  // page-mode PRECHARGE (entered PRECHARGE_1) ever fired
	// B-jtag-probe: live FSM state for the ISSP/JTAG observability node
	output      [8:0]  dbg_sdram,            // {lastbank_ch1_valid, command[2:0], state[4:0]}
	output      [7:0]  dbg_drd1              // data_ready_delay1[7:0]: read-data capture window
);

// Keep tri-state enables at the pins, outside the command/address registers.
reg [12:0] address_out = 0;
reg [1:0] bank_out = 0;

localparam BURST_LENGTH        = 8;
//(BURST_LENGTH == 8) ? 3'b011 : (BURST_LENGTH == 4) ? 3'b010 : (BURST_LENGTH == 2) ? 3'b001 : 3'b000;  // 000=1, 001=2, 010=4, 011=8
// we do 4 bursts of 2 words(16bit) for every read. The reason is that a burst of 8 will wrap inside the page. e.g. reading address 6,7,8,.. is not possible, it will read 6,7,0,.. instead
// as bursts of 2 can be done back-to-back, this does not have any latency or bandwidth penalty compared to full 8 word burst
localparam BURST_CODE          = 3'b001;   
localparam ACCESS_TYPE         = 1'b0;     // 0=sequential, 1=interleaved
localparam CAS_LATENCY         = 3'd3;     // 3 for the 101.6064MHz SDRAM clock
localparam OP_MODE             = 2'b00;    // only 00 (standard operation) allowed
localparam NO_WRITE_BURST      = 1'b1;     // 0= write burst enabled, 1=only single access write
localparam MODE                = {3'b000, NO_WRITE_BURST, OP_MODE, CAS_LATENCY, ACCESS_TYPE, BURST_CODE};

localparam sdram_startup_cycles= 14'd12100;// 100us, plus a little more, @ 100MHz
localparam cycles_per_refresh  = 14'd780;  // (64000*100)/8192-1 Calc'd as (64ms @ 100MHz)/8192 rose
localparam startup_refresh_max = 14'b11111111111111;

// SDRAM commands
wire [2:0] CMD_NOP             = 3'b111;
wire [2:0] CMD_ACTIVE          = 3'b011;
wire [2:0] CMD_READ            = 3'b101;
wire [2:0] CMD_WRITE           = 3'b100;
wire [2:0] CMD_PRECHARGE       = 3'b010;
wire [2:0] CMD_AUTO_REFRESH    = 3'b001;
wire [2:0] CMD_LOAD_MODE       = 3'b000;

reg [13:0] refresh_count = startup_refresh_max - sdram_startup_cycles;
reg  [2:0] command = 0;
reg        chip = 0;

localparam [4:0] STATE_STARTUP = 5'd0;
localparam [4:0] STATE_WAIT    = 5'd1;
localparam [4:0] STATE_RW1     = 5'd2;
localparam [4:0] STATE_RW2     = 5'd3;
localparam [4:0] STATE_IDLE    = 5'd4;
localparam [4:0] STATE_IDLE_1  = 5'd5;
localparam [4:0] STATE_IDLE_2  = 5'd6;
localparam [4:0] STATE_IDLE_3  = 5'd7;
localparam [4:0] STATE_IDLE_4  = 5'd8;
localparam [4:0] STATE_IDLE_5  = 5'd9;
localparam [4:0] STATE_IDLE_6  = 5'd10;
localparam [4:0] STATE_IDLE_7  = 5'd11;
localparam [4:0] STATE_IDLE_8  = 5'd12;
localparam [4:0] STATE_IDLE_9  = 5'd13;
localparam [4:0] STATE_RFSH    = 5'd14;
// ch1 page-mode states (only reachable when pagemode_en=1). tRP = 2 cycles.
localparam [4:0] STATE_PRECHARGE_1 = 5'd15;
localparam [4:0] STATE_PRECHARGE_2 = 5'd16;
// Stage DMA FIFO output before driving the SDRAM active-address register.
// This breaks the clk1x DMA-address to clk3x pin-address critical path while
// preserving FIFO order; STATE_DMA_LOAD adds one deterministic clk3x setup
// cycle before the existing ACTIVE/WAIT sequence.
localparam [4:0] STATE_DMA_LOAD = 5'd17;
localparam [4:0] STATE_READ_DRAIN = 5'd18;

reg clk1xToggle     = 0;
reg clk1xToggle3X   = 0;
reg clk1xToggle3X_1 = 0;
reg clk3xIndex      = 0;

reg ram_idleNext    = 0;

// Never advertise an idle/ready memory interface while the controller is
// being reinitialised. A stale response token from the previous SDRAM epoch
// must not be consumed by memorymux during PLL/reset recovery.
assign ram_idle = !init && ram_idleNext && !ch3_req;

reg [10:0] lastbank = 0;
// ch1 page-mode tracker (only meaningful when pagemode_en=1).
// {chip, bank, row} of the currently-open ch1 row.
reg        lastbank_ch1_chip  = 1'b0;
reg  [1:0] lastbank_ch1_bank  = 2'b0;
reg [12:0] lastbank_ch1_row   = 13'b0;
reg        lastbank_ch1_valid = 1'b0;
// Register page-mode row decisions before the command/address cycle.  This
// keeps the wide row comparator off the STATE_IDLE pin-register mux.
reg        ch1_page_match = 1'b0;
reg        ch2_page_match = 1'b0;
// ch3 buffered for timing closure
reg [26:0]  ch3buf_addr = 0;
reg [31:0]  ch3buf_din = 0;
reg         ch3buf_rnw = 0;
reg [3:0]   ch3buf_be = 0;
// Register the CPU/memorymux request at the clk3x ingress.  The handshake
// already waits for clk3xIndex; using the captured bundle removes the long
// clk1x -> SDRAM address decode path without changing ordering or completion.
reg [26:0]  ch1buf_addr = 0;
reg [15:0]  ch1buf_din = 0;
reg         ch1buf_rnw = 0;
reg         ch1buf_dma = 0;
reg [1:0]   ch1buf_cntDMA = 0;
reg         ch1buf_cache = 0;
// CPU write requests share the same clk1x address bus as reads.  Capture the
// write bundle at the same clk3xIndex handshake so SDRAM command/address
// outputs do not retain a long clk1x-to-clk3x path.
reg [26:0]  ch2buf_addr = 0;
reg [31:0]  ch2buf_din = 0;
reg         ch2buf_rnw = 0;
reg [3:0]   ch2buf_be = 0;

reg ch1_ready_ramclock = 0;
reg ch2_ready_ramclock = 0;
reg ch3_ready_ramclock = 0;
reg refreshForce_1 = 0;

reg cache_buffer      = 0;
reg cache_buffer_next = 0;

reg cache_done_0  = 0;
reg cache_done_1  = 0;
reg cache_done_2  = 0;
reg cache_done_3  = 0;
reg [3:0] cache_wr_next = 0;

reg       dma_buffer    = 0;
reg       dma_done      = 0;
reg       dma_ack       = 0;
reg [1:0] dma_count_3x  = 0;
reg [1:0] dma_count     = 0;
reg [1:0] dma_counter   = 0;
reg       dma_reqprocessed_ramclock = 0;

reg  [4:0] state = STATE_STARTUP;  // 5 bits: holds STATE_PRECHARGE_2 (16)

reg ch1_rq = 0, ch2_rq = 0, ch3_rq = 0, refreshForce_req = 0;
reg saved_wr = 0;
reg saved_128read = 0;

localparam READ_CAPTURE_STAGES = 1;
reg [CAS_LATENCY+BURST_LENGTH+READ_CAPTURE_STAGES:0] data_ready_delay1 = 0, data_ready_delay2 = 0, data_ready_delay3 = 0;

reg [12:0] cas_addr = 0;
reg [26:0] dmafifo_adr_stage = 0;
reg [31:0] dmafifo_data_stage = 0;
reg [31:0] saved_data = 0;
reg  [3:0] saved_be = 0;
reg [15:0] dq_reg = 0;
reg [15:0] dq_out = 0;
reg dq_oe = 0;
reg [1:0] ch = 0;

assign dbg_sdram = {lastbank_ch1_valid, command, state[4:0]};
assign dbg_drd1  = data_ready_delay1[7:0];
assign SDRAM_A = SDRAM_EN ? address_out : 13'bz;
assign SDRAM_BA = SDRAM_EN ? bank_out : 2'bz;
assign SDRAM_nCS  = SDRAM_EN ? chip : 1'bz;
assign SDRAM_nRAS = SDRAM_EN ? command[2] : 1'bz;
assign SDRAM_nCAS = SDRAM_EN ? command[1] : 1'bz;
assign SDRAM_nWE  = command[0];
assign SDRAM_CKE  = 1;
assign {SDRAM_DQMH,SDRAM_DQML} = SDRAM_EN ? address_out[12:11] : 2'bz;

always @(posedge clk_base) begin

   ch1_ready <= init ? 1'b0 : ch1_ready_ramclock;
	ch2_ready <= init ? 1'b0 : ch2_ready_ramclock;
	ch3_ready <= init ? 1'b0 : ch3_ready_ramclock;

	dma_reqprocessed <= dma_reqprocessed_ramclock;
   
   clk1xToggle <= !clk1xToggle;
      
   ram_idleNext <= 0;
   if (state == STATE_IDLE || state == STATE_IDLE_1 || state == STATE_IDLE_2 || (state == STATE_RW1 && saved_wr) || state == STATE_RW2) begin
      if (refresh_count < (cycles_per_refresh - 14'd16) && !ch1_rq && !ch2_rq && !ch3_rq) begin
         ram_idleNext <= 1;
      end
   end
   
   if (ch1_ready_ramclock) begin
      ch1_dout32 <= ch1_dout[31:0];
   end
   
   dma_wr  <= 0;
   dma_ack <= 0;

   if (dma_wr) begin
      if (dma_counter < dma_count) begin
         dma_wr      <= 1;
         dma_counter <= dma_counter + 1'b1;
         if (dma_counter == 0) dma_data <= ch1_dout[ 63:32];
         if (dma_counter == 1) dma_data <= ch1_dout[ 95:64];
         if (dma_counter == 2) dma_data <= ch1_dout[127:96];
      end
   end
   
   if (dma_done) begin
      dma_ack     <= 1;
      dma_wr      <= 1;
      dma_data    <= ch1_dout[31:0];
      dma_counter <= 0;
      dma_count   <= dma_count_3x;
   end

   // The base-clock side has its own registered handshake outputs. Override
   // every one of them on init as well, so a request that completed just
   // before reset cannot leak a ready/ DMA pulse into the new epoch.
   if (init) begin
      clk1xToggle <= 1'b0;
      ram_idleNext <= 1'b0;
      ch1_ready <= 1'b0;
      ch2_ready <= 1'b0;
      ch3_ready <= 1'b0;
      dma_reqprocessed <= 1'b0;
      dma_wr <= 1'b0;
      dma_ack <= 1'b0;
      dma_counter <= 2'b0;
      dma_count <= 2'b0;
      dma_data <= 16'b0;
      ch1_dout32 <= 32'b0;
   end

end

// One registered output driver for the bidirectional pins. Keeping the data
// register separate from its output enable also avoids splitting procedural
// tri-state assignments into independent retained drivers during simulation.
assign SDRAM_DQ = dq_oe ? dq_out : 16'bz;

// Board-clock output delay plus DQ input delay moves the valid read window
// beyond the ideal falling edge. Capture the previous SDRAM beat on the
// following rising edge. The burst-valid pipeline has one matching extra
// stage, so dq_reg has a full clk period to reach the burst registers.
// The SDC checks this previous-beat setup AND the next-beat hold boundary.
always @(posedge clk) begin
   if (init)
      dq_reg <= 16'b0;
   else
      dq_reg <= SDRAM_DQ;
end

always @(posedge clk) begin
  
   clk1xToggle3X   <= clk1xToggle;
   clk1xToggle3X_1 <= clk1xToggle3X;
   clk3xIndex      <= clk1xToggle3X_1 == clk1xToggle;


   if (ch1_req & clk3xIndex & ~ch1_rq) begin
      ch1_rq        <= 1'b1;
      ch1buf_addr   <= ch1_addr;
      ch1buf_din    <= ch1_din;
      ch1buf_rnw    <= ch1_rnw;
      ch1buf_dma    <= ch1_dma;
      ch1buf_cntDMA <= ch1_cntDMA;
      ch1buf_cache  <= ch1_cache;
   end

   if (ch2_req & clk3xIndex & ~ch2_rq) begin
      ch2buf_addr <= ch2_addr;
      ch2buf_din  <= ch2_din;
      ch2buf_rnw  <= ch2_rnw;
      ch2buf_be   <= ch2_be;
   end

	// Request bundles and the page tracker are stable before idle dispatch.
	// Use the live bus only on the capture edge so the registered decision
	// corresponds to a newly arriving request; all later FSM cycles consume
	// the buffered bundle.
	if (ch1_req & clk3xIndex & ~ch1_rq) begin
	   ch1_page_match <= pagemode_en && lastbank_ch1_valid &&
                     lastbank_ch1_chip == ch1_addr[26] &&
                     lastbank_ch1_bank == ch1_addr[24:23] &&
                     lastbank_ch1_row  == ch1_addr[22:10];
	end else begin
	   ch1_page_match <= pagemode_en && lastbank_ch1_valid &&
                     lastbank_ch1_chip == ch1buf_addr[26] &&
                     lastbank_ch1_bank == ch1buf_addr[24:23] &&
                     lastbank_ch1_row  == ch1buf_addr[22:10];
	end
	if (ch2_req & clk3xIndex & ~ch2_rq) begin
	   ch2_page_match <= pagemode_en && lastbank_ch1_valid &&
                     lastbank_ch1_chip == ch2_addr[26] &&
                     lastbank_ch1_bank == ch2_addr[24:23] &&
                     lastbank_ch1_row  == ch2_addr[22:10];
	end else begin
	   ch2_page_match <= pagemode_en && lastbank_ch1_valid &&
                     lastbank_ch1_chip == ch2buf_addr[26] &&
                     lastbank_ch1_bank == ch2buf_addr[24:23] &&
                     lastbank_ch1_row  == ch2buf_addr[22:10];
	end
	ch2_rq <= ch2_rq | (ch2_req & clk3xIndex);
	ch3_rq <= ch3_rq | (ch3_req & clk3xIndex);
   
   ch3buf_addr <= ch3_addr;
   ch3buf_din  <= ch3_din;
   ch3buf_rnw  <= ch3_rnw;
   ch3buf_be   <= ch3_be;
	
	if (ch1_ready) ch1_ready_ramclock <= 0;
	if (ch2_ready) ch2_ready_ramclock <= 0;
	if (ch3_ready) ch3_ready_ramclock <= 0;
	
	if (dma_ack) dma_done <= 0;

	if (dma_reqprocessed) dma_reqprocessed_ramclock <= 0;

	dmafifo_read <= 0;

	refreshForce_1 <= refreshForce;
	refreshForce_req <= refreshForce_req | (refreshForce & ~refreshForce_1);

	refresh_count <= refresh_count+1'b1;

	data_ready_delay1 <= data_ready_delay1>>1;
	data_ready_delay2 <= data_ready_delay2>>1;
	data_ready_delay3 <= data_ready_delay3>>1;

   
   cache_wr     <= 0;
   cache_done_0 <= 0;
   cache_done_1 <= 0;
   cache_done_2 <= 0;
   cache_done_3 <= 0;
   if (cache_done_0) begin cache_data <= ch1_dout[ 31: 0]; cache_wr <= cache_wr_next; cache_wr_next <= { cache_wr_next[2:0], 1'b0 }; end
   if (cache_done_1) begin cache_data <= ch1_dout[ 63:32]; cache_wr <= cache_wr_next; cache_wr_next <= { cache_wr_next[2:0], 1'b0 }; end
   if (cache_done_2) begin cache_data <= ch1_dout[ 95:64]; cache_wr <= cache_wr_next; cache_wr_next <= { cache_wr_next[2:0], 1'b0 }; end
   if (cache_done_3) begin cache_data <= ch1_dout[127:96]; cache_wr <= cache_wr_next; cache_wr_next <= { cache_wr_next[2:0], 1'b0 }; end
      
   if(data_ready_delay1[7]) ch1_dout[ 15: 00]  <= dq_reg;
   if(data_ready_delay1[6]) ch1_dout[ 31: 16]  <= dq_reg;
   if(data_ready_delay1[5]) ch1_dout[ 47: 32]  <= dq_reg;
   if(data_ready_delay1[4]) ch1_dout[ 63: 48]  <= dq_reg;
   if(data_ready_delay1[3]) ch1_dout[ 79: 64]  <= dq_reg;
   if(data_ready_delay1[2]) ch1_dout[ 95: 80]  <= dq_reg;
   if(data_ready_delay1[1]) ch1_dout[111: 96]  <= dq_reg;
   if(data_ready_delay1[0]) ch1_dout[127:112]  <= dq_reg;
   if(data_ready_delay1[6] && ~dma_buffer && ~cache_buffer_next) ch1_ready_ramclock <= 1;
   if(data_ready_delay1[4] && cache_buffer_next)                 ch1_ready_ramclock <= 1;
   if(data_ready_delay1[6] && dma_buffer)                        dma_done <= 1;

   if(data_ready_delay1[7]) cache_buffer_next <= cache_buffer;
   if(data_ready_delay1[6] && cache_buffer_next) cache_done_0 <= 1;
   if(data_ready_delay1[4] && cache_buffer_next) cache_done_1 <= 1;
   if(data_ready_delay1[2] && cache_buffer_next) cache_done_2 <= 1;
   if(data_ready_delay1[0] && cache_buffer_next) cache_done_3 <= 1;

	if(data_ready_delay2[7]) ch2_dout[15:00]    <= dq_reg;
	if(data_ready_delay2[6]) ch2_dout[31:16]    <= dq_reg;
	if(data_ready_delay2[2]) ch2_ready_ramclock <= 1;

	if(data_ready_delay3[7]) ch3_dout[15:00]    <= dq_reg;
	if(data_ready_delay3[6]) ch3_dout[31:16]    <= dq_reg;
	if(data_ready_delay3[2]) ch3_ready_ramclock <= 1;

	// DQ is ignored whenever output enable is low. Avoid a hold-feedback
	// mux so the write-data register can pack into the pin's output cell.
	dq_out <= 0;
	dq_oe <= 0;
   
   if (SDRAM_EN) begin
   
      command <= CMD_NOP;
      if (state == STATE_PRECHARGE_1) dbg_pm_pre <= 1'b1;   // B-pm-probe: page-mode PRECHARGE fired
      case (state)
         STATE_STARTUP: begin
            address_out    <= 0;
            bank_out   <= 0;
   
            if (refresh_count == (startup_refresh_max-64)) chip <= 0;
            if (refresh_count == (startup_refresh_max-32)) chip <= 1;
   
            // All the commands during the startup are NOPS, except these
            if (refresh_count == startup_refresh_max-63 || refresh_count == startup_refresh_max-31) begin
               // ensure all rows are closed
               command     <= CMD_PRECHARGE;
               address_out[10] <= 1;  // all banks
               bank_out    <= 2'b00;
            end
            if (refresh_count == startup_refresh_max-55 || refresh_count == startup_refresh_max-23) begin
               // these refreshes need to be at least tREF (66ns) apart
               command     <= CMD_AUTO_REFRESH;
            end
            if (refresh_count == startup_refresh_max-47 || refresh_count == startup_refresh_max-15) begin
               command     <= CMD_AUTO_REFRESH;
            end
            if (refresh_count == startup_refresh_max-39 || refresh_count == startup_refresh_max-7) begin
               // Now load the mode register
               command     <= CMD_LOAD_MODE;
               address_out     <= MODE;
            end
   
            if (!refresh_count) begin
               state   <= STATE_IDLE;
               refresh_count <= 0;
            end
         end
   
         // Retire the final pipelined beat without changing BL=2 READ spacing.
         STATE_READ_DRAIN: state <= STATE_IDLE;
         STATE_IDLE_9: begin
            state <= STATE_IDLE_8;
            if (saved_128read) begin
               cas_addr[8:0] <= cas_addr[8:0] + 2'd2;
            end
         end
         
         STATE_IDLE_8: begin
            state   <= STATE_IDLE_7;
            if (saved_128read) begin
               command <= CMD_READ;
               address_out <= cas_addr;
               address_out[10] <= 1'b0;
            end
         end
         
         STATE_IDLE_7: begin
            state <= STATE_IDLE_6;
            if (saved_128read) begin
               cas_addr[8:0] <= cas_addr[8:0] + 2'd2;
            end
         end
         
         STATE_IDLE_6: begin
            state <= STATE_IDLE_5;
            if (saved_128read) begin
               command <= CMD_READ;
               address_out <= cas_addr;
               address_out[10] <= 1'b0;
            end
         end
         
         STATE_IDLE_5: begin 
            state <= STATE_IDLE_4;
            if (saved_128read) begin
               cas_addr[8:0] <= cas_addr[8:0] + 2'd2;
            end
         end
         
         STATE_IDLE_4: begin
            state <= STATE_IDLE_3;
            if (saved_128read) begin
               command       <= CMD_READ;
               address_out       <= cas_addr;
               saved_128read <= 0;
            end
         end
         
         STATE_IDLE_3: begin
            state <= STATE_IDLE_2;
         end
         
         STATE_IDLE_2: begin
            state <= STATE_IDLE_1;
         end
         
         STATE_IDLE_1: begin
            // A cache line's final BL=2 READ is only three SDRAM clocks
            // behind this state. Defer refresh to IDLE so auto-precharge
            // gets the burst interval plus two tRP clocks before REFRESH.
            // IDLE also handles explicit precharge for a page-mode row.
            state <= saved_wr ? STATE_IDLE : STATE_READ_DRAIN;
         end

         STATE_RFSH: begin
            state    <= STATE_IDLE_5;
            command  <= CMD_AUTO_REFRESH;
            chip     <= 1;
         end
   
         STATE_IDLE: begin
            saved_128read <= 0;
            if (refreshForce_req || refresh_count > cycles_per_refresh) begin
               // PRECHARGE first if a page-mode row is open.
               if (lastbank_ch1_valid) begin
                  command            <= CMD_PRECHARGE;
                  address_out[10]        <= 1'b1;
                  bank_out           <= 2'b00;
                  chip               <= lastbank_ch1_chip;
                  state              <= STATE_PRECHARGE_1;
                  lastbank_ch1_valid <= 0;
               end else begin
                  state            <= STATE_RFSH;
                  command          <= CMD_AUTO_REFRESH;
                  chip             <= 0;
                  refreshForce_req <= 0;
                  if (refresh_count > cycles_per_refresh)
                     refresh_count <= refresh_count - cycles_per_refresh + 1'd1;
                  else
                     refresh_count <= 14'd0;
               end

            // A page-mode row stays open across the idle gap between CPU
            // requests.  The previous condition precharged whenever ch1 was
            // momentarily idle, so the BIOS delay loop paid ACTIVE+tRCD for
            // every load even when the next load hit the same row.  A same-row
            // ch2 access can use the already-open row as well; all other
            // channels or row changes must precharge before taking the pins.
            // Only compare an address when its request is pending: the other
            // channel address buses are otherwise stale.
            end else if (lastbank_ch1_valid &&
                         (~dmafifo_empty ||
                          (ch3_req | ch3_rq) ||
                          !pagemode_en ||
                          (ch1_rq && !ch1_page_match) ||
                          (ch2_rq && !ch2_page_match))) begin
               command            <= CMD_PRECHARGE;
               address_out[10]    <= 1'b1;
               bank_out           <= 2'b00;
               chip               <= lastbank_ch1_chip;
               state              <= STATE_PRECHARGE_1;
               lastbank_ch1_valid <= 0;

            end else if(~dmafifo_empty) begin
                dmafifo_adr_stage  <= dmafifo_adr;
                dmafifo_data_stage <= dmafifo_data;
                state              <= STATE_DMA_LOAD;

            end else if(ch1_rq) begin
               // HIT path — only reachable when pagemode_en=1 (because the tracker
               // is only set to 1 in the no-tracker branch when pagemode_en=1).
               if (ch1_page_match) begin
                  cas_addr[8:0] <= ch1buf_addr[9:1];
                  bank_out      <= ch1buf_addr[24:23];
                  chip          <= ch1buf_addr[26];
                  saved_data    <= ch1buf_din;
                  saved_wr      <= ~ch1buf_rnw;
                  ch            <= 0;
                  ch1_rq        <= 0;
                  state         <= STATE_RW1;
                  dbg_pm_hit    <= 1'b1;   // B-pm-probe: HIT path taken

                   cache_buffer <= ch1buf_cache;
                   cache_addr   <= ch1buf_addr[11:4];
                   if (ch1buf_addr[3:2] == 2'b00) cache_wr_next <= 4'b0001;
                   if (ch1buf_addr[3:2] == 2'b01) cache_wr_next <= 4'b0010;
                   if (ch1buf_addr[3:2] == 2'b10) cache_wr_next <= 4'b0100;
                   if (ch1buf_addr[3:2] == 2'b11) cache_wr_next <= 4'b1000;

                   dma_buffer                <= ch1buf_dma;
                   dma_reqprocessed_ramclock <= ch1buf_dma;
                   dma_count_3x              <= ch1buf_cntDMA;

                   saved_128read <= ch1buf_dma | ch1buf_cache;

               // Row-mismatch PRECHARGE — fires when a page-mode row is open but
               // doesn't match the request (or when user toggled pagemode_en off
               // mid-flight, leaving a residual open row). Closes the row, then
               // STATE_IDLE re-evaluates and falls into the ACTIVE branch.
               end else if (lastbank_ch1_valid) begin
                  command            <= CMD_PRECHARGE;
                  address_out[10]        <= 1'b1;
                  state              <= STATE_PRECHARGE_1;
                  lastbank_ch1_valid <= 0;
                  // ch1_rq preserved — the pending request still needs servicing.

               // Normal ACTIVE path. cas_addr[10] depends on pagemode_en:
               //   pagemode OFF → 1 = auto-precharge (baseline; row closes after burst)
               //   pagemode ON  → 0 = no auto-precharge (row stays open for HIT)
               end else begin
                   {cas_addr[12:9],bank_out,address_out,cas_addr[8:0]} <= {2'b00, ~pagemode_en, ch1buf_addr[25:1]};
                   chip         <= ch1buf_addr[26];
                   saved_data   <= ch1buf_din;
                   saved_wr     <= ~ch1buf_rnw;
                  ch           <= 0;
                  ch1_rq       <= 0;
                  command      <= CMD_ACTIVE;
                  state        <= STATE_WAIT;

                   cache_buffer <= ch1buf_cache;
                   cache_addr   <= ch1buf_addr[11:4];
                   if (ch1buf_addr[3:2] == 2'b00) cache_wr_next <= 4'b0001;
                   if (ch1buf_addr[3:2] == 2'b01) cache_wr_next <= 4'b0010;
                   if (ch1buf_addr[3:2] == 2'b10) cache_wr_next <= 4'b0100;
                   if (ch1buf_addr[3:2] == 2'b11) cache_wr_next <= 4'b1000;

                   dma_buffer                <= ch1buf_dma;
                   dma_reqprocessed_ramclock <= ch1buf_dma;
                   dma_count_3x              <= ch1buf_cntDMA;

                   saved_128read <= ch1buf_dma | ch1buf_cache;

                  // Tracker valid only when page-mode opted in.
                   lastbank_ch1_chip  <= ch1buf_addr[26];
                   lastbank_ch1_bank  <= ch1buf_addr[24:23];
                   lastbank_ch1_row   <= ch1buf_addr[22:10];
                  lastbank_ch1_valid <= pagemode_en;
                  if (pagemode_en) dbg_pm_open <= 1'b1;   // B-pm-probe: row left open
               end

            end else if(ch2_rq) begin
               // A same-row ch2 transfer can issue directly against the
               // active page opened by ch1.  This removes the two-cycle tRP
               // bubble before each BIOS stack store.  The normal ch2 path
               // below still uses ACTIVE when no compatible page is open.
               if (ch2_page_match) begin
                  cas_addr[12:9] <= {~ch2buf_be[1:0], ch2buf_rnw, ch2buf_addr[25]};
                  cas_addr[8:0] <= ch2buf_addr[9:1];
                  bank_out      <= ch2buf_addr[24:23];
                  chip          <= ch2buf_addr[26];
                  saved_data    <= ch2buf_din;
                  saved_wr      <= ~ch2buf_rnw;
                  saved_be      <= ch2buf_be;
                  ch            <= 1;
                  ch2_rq        <= 0;
                  state         <= STATE_RW1;
                  ch2_ready_ramclock <= 1;
                  // ch2 writes auto-precharge on their high halfword in
                  // STATE_RW2, so the ch1 row tracker is no longer valid.
                  lastbank_ch1_valid <= 0;
               end else begin
                  {cas_addr[12:9],bank_out,address_out,cas_addr[8:0]} <= {~ch2buf_be[1:0], ch2buf_rnw, ch2buf_addr[25:1]};
                  chip       <= ch2buf_addr[26];
                  saved_data <= ch2buf_din;
                  saved_wr   <= ~ch2buf_rnw;
                  saved_be   <= ch2buf_be;
                  ch         <= 1;
                  ch2_rq     <= 0;
                  command    <= CMD_ACTIVE;
                  state      <= STATE_WAIT;
                  ch2_ready_ramclock <= 1;
                  lastbank_ch1_valid <= 0;
               end
            end else if(ch3_rq) begin
               {cas_addr[12:9],bank_out,address_out,cas_addr[8:0]} <= {~ch3buf_be[1:0], ch3buf_rnw, ch3buf_addr[25:1]};
               chip       <= ch3buf_addr[26];
               saved_data <= ch3buf_din;
               saved_wr   <= ~ch3buf_rnw;
               saved_be   <= ch3buf_be;
               ch         <= 2;
               ch3_rq     <= 0;
               command    <= CMD_ACTIVE;
               state      <= STATE_WAIT;
               lastbank_ch1_valid <= 0;
            end
          end

         STATE_DMA_LOAD: begin
            {cas_addr[12:9],bank_out,address_out,cas_addr[8:0]} <= {2'b00, 1'b0, dmafifo_adr_stage[25:1]};
            chip         <= dmafifo_adr_stage[26];
            saved_data   <= dmafifo_data_stage;
            saved_wr     <= 1'b1;
            saved_be     <= 4'b1111;
            ch           <= 1;
            command      <= CMD_ACTIVE;
            state        <= STATE_WAIT;
            dmafifo_read <= 1'b1;
            lastbank     <= dmafifo_adr_stage[20:10];
            // DMA touches the bus; invalidate ch1 tracker.
            lastbank_ch1_valid <= 0;
         end

         // 2-cycle tRP wait before STATE_IDLE re-evaluates request / refresh.
         STATE_PRECHARGE_1: state <= STATE_PRECHARGE_2;
         STATE_PRECHARGE_2: state <= STATE_IDLE;

         STATE_WAIT: state <= STATE_RW1;
         STATE_RW1: begin
            address_out <= cas_addr;
            if(saved_wr) begin
               command  <= CMD_WRITE;
               dq_out <= saved_data[15:0];
               dq_oe <= 1;
               if(!ch) begin
                  ch1_ready_ramclock  <= 1;
                  state <= STATE_IDLE_2;
               end
               else begin
                  state <= STATE_RW2;
               end
            end
            else begin
               command <= CMD_READ;
               // A cache/DMA line consists of four BL=2 reads to one row.
               // Auto-precharge forbids another access to that bank until
               // it completes. Keep the row open through the first three
               // reads; STATE_IDLE_4 applies cas_addr[10] on the final read.
               if (saved_128read) address_out[10] <= 1'b0;
               state   <= STATE_IDLE_9;
                  if(ch == 0) data_ready_delay1[CAS_LATENCY+BURST_LENGTH+READ_CAPTURE_STAGES] <= 1;
               else if(ch == 1) data_ready_delay2[CAS_LATENCY+BURST_LENGTH+READ_CAPTURE_STAGES] <= 1;
               else             data_ready_delay3[CAS_LATENCY+BURST_LENGTH+READ_CAPTURE_STAGES] <= 1;
            end
         end
   
         STATE_RW2: begin
            if(ch == 1) begin
               address_out[0]           <= 1;
               command              <= CMD_WRITE;
               dq_out               <= saved_data[31:16];
               dq_oe                <= 1;
               address_out[12:11]       <= ~saved_be[3:2];
               if(~dmafifo_empty && (lastbank == dmafifo_adr[20:10])) begin
                  cas_addr[8:0]     <= dmafifo_adr[9:1];
                  saved_data        <= dmafifo_data;
                  state             <= STATE_RW1;
                  dmafifo_read      <= 1'b1;
               end else begin
                  state             <= STATE_IDLE_2;
                  address_out[10]       <= 1;
               end
            end
            else begin
               state                <= STATE_IDLE_2;
               address_out[10]          <= 1;
               address_out[0]           <= 1;
               command              <= CMD_WRITE;
               dq_out               <= saved_data[31:16];
               dq_oe                <= 1;
               address_out[12:11]       <= ~saved_be[3:2];
               ch3_ready_ramclock   <= 1;
            end
         end
      endcase
   
       if (init) begin
          state <= STATE_STARTUP;
          refresh_count <= startup_refresh_max - sdram_startup_cycles;
          address_out <= 13'b0;
          bank_out <= 2'b0;
          command <= CMD_NOP;
          chip <= 1'b0;
          clk1xToggle3X <= 1'b0;
          clk1xToggle3X_1 <= 1'b0;
          clk3xIndex <= 1'b0;
          lastbank <= 11'b0;
          lastbank_ch1_chip <= 1'b0;
          lastbank_ch1_bank <= 2'b0;
          lastbank_ch1_row <= 13'b0;
          lastbank_ch1_valid <= 1'b0;
          ch1_rq <= 1'b0;
          ch2_rq <= 1'b0;
          ch3_rq <= 1'b0;
          ch1buf_addr <= 27'b0;
          ch1buf_din <= 16'b0;
          ch1buf_rnw <= 1'b0;
          ch1buf_dma <= 1'b0;
          ch1buf_cntDMA <= 2'b0;
          ch1buf_cache <= 1'b0;
          ch2buf_addr <= 27'b0;
          ch2buf_din <= 32'b0;
          ch2buf_rnw <= 1'b0;
          ch2buf_be <= 4'b0;
          ch1_page_match <= 1'b0;
          ch2_page_match <= 1'b0;
          ch3buf_addr <= 27'b0;
          ch3buf_din <= 32'b0;
          ch3buf_rnw <= 1'b0;
          ch3buf_be <= 4'b0;
          ch1_ready_ramclock <= 1'b0;
          ch2_ready_ramclock <= 1'b0;
          ch3_ready_ramclock <= 1'b0;
          refreshForce_1 <= 1'b0;
          refreshForce_req <= 1'b0;
          cache_buffer <= 1'b0;
          cache_buffer_next <= 1'b0;
          cache_done_0 <= 1'b0;
          cache_done_1 <= 1'b0;
          cache_done_2 <= 1'b0;
          cache_done_3 <= 1'b0;
          cache_wr_next <= 4'b0;
          dma_buffer <= 1'b0;
          dma_done <= 1'b0;
          dma_count_3x <= 2'b0;
          dma_reqprocessed_ramclock <= 1'b0;
          saved_wr <= 1'b0;
          saved_128read <= 1'b0;
          cas_addr <= 13'b0;
          dmafifo_adr_stage <= 27'b0;
          dmafifo_data_stage <= 32'b0;
          saved_data <= 32'b0;
          saved_be <= 4'b0;
          dq_out <= 16'b0;
          dq_oe <= 1'b0;
          ch <= 2'b0;
          data_ready_delay1 <= '0;
          data_ready_delay2 <= '0;
          data_ready_delay3 <= '0;
       end
   end
end

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
	.outclock(clk),
	.dataout(SDRAM_CLK),
	.aclr(1'b0),
	.aset(1'b0),
	.oe(SDRAM_EN),
	.outclocken(1'b1),
	.sclr(1'b0),
	.sset(1'b0)
);

endmodule
