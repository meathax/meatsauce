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

// Heavy Unit adaptation: 48 MHz profile, explicit initialization and reset,
// split DQ at the pin boundary for a common synthesis/simulation controller.
module airbustr_sdram_controller #(parameter integer CLK_HZ = 48000000)
(
    input             init,        // reset to initialize RAM
    input             clk,         // one master memory clock
   
    input             doRefresh,

    input      [15:0] dq_in,       // sampled physical DQ
    output reg [15:0] dq_out,
    output reg        dq_oe,
    output reg        initialized,
    output reg [12:0] SDRAM_A,     // 13 bit multiplexed address bus
    output            SDRAM_DQML,  // two byte masks
    output            SDRAM_DQMH,  // 
    output reg  [1:0] SDRAM_BA,    // two banks
    output            SDRAM_nCS,   // a single chip select
    output            SDRAM_nWE,   // write enable
    output            SDRAM_nRAS,  // row address select
    output            SDRAM_nCAS,  // columns address select
    output            SDRAM_CKE,   // clock enable
    output            SDRAM_CLK,   // clock for chip

    input      [26:1] ch1_addr,    // 25 bit address for 8bit mode. addr[0] = 0 for 16bit mode for correct operations.
    output reg [31:0] ch1_dout,    // data output to cpu
    input             ch1_req,     // request
    output reg        ch1_ready,
    
    input      [26:1] ch2_addr,    
    output reg [63:0] ch2_dout,    
    input             ch2_req,
    input             ch2_stream,
    output reg        ch2_beat_valid,ch2_beat_last,
    output reg        trace_object_long,     
    output reg        ch2_ready,

    input      [26:1] ch3_addr,
    output reg [63:0] ch3_dout,
    input      [15:0] ch3_din,
    input      [ 1:0] ch3_be,
    input             ch3_req,
    input             ch3_rnw,     // 1 - read, 0 - write
    output reg        ch3_ready,

    input      [26:1] ch4_addr,
    output reg [63:0] ch4_dout,
    input             ch4_req,
    output reg        ch4_ready,
    output reg [3:0] trace_pending,trace_state,
    output reg [1:0] trace_grant_client,
    output reg trace_grant_valid
);

assign SDRAM_nCS  = chip;
assign SDRAM_nRAS = command[2];
assign SDRAM_nCAS = command[1];
assign SDRAM_nWE  = command[0];
assign SDRAM_CKE  = 1;
assign {SDRAM_DQMH,SDRAM_DQML} = SDRAM_A[12:11];


// Burst length = 4
localparam BURST_LENGTH        = 4;
localparam BURST_CODE          = (BURST_LENGTH == 8) ? 3'b011 : (BURST_LENGTH == 4) ? 3'b010 : (BURST_LENGTH == 2) ? 3'b001 : 3'b000;  // 000=1, 001=2, 010=4, 011=8
localparam ACCESS_TYPE         = 1'b0;     // 0=sequential, 1=interleaved
localparam CAS_LATENCY         = 3'd3;     // 2 for < 100MHz, 3 for >100MHz
localparam OP_MODE             = 2'b00;    // only 00 (standard operation) allowed
localparam NO_WRITE_BURST      = 1'b1;     // 0= write burst enabled, 1=only single access write
localparam MODE                = {3'b000, NO_WRITE_BURST, OP_MODE, CAS_LATENCY, ACCESS_TYPE, BURST_CODE};

localparam [13:0] sdram_startup_cycles= 14'((CLK_HZ/5000)+64); // >=200us before first PRECHARGE
localparam [13:0] cycles_per_refresh  = 14'((CLK_HZ/128000)-3); // 372 @48MHz; reserve for 200us reinitialization
localparam startup_refresh_max = 14'b11111111111111;

// SDRAM commands
wire [2:0] CMD_NOP             = 3'b111;
wire [2:0] CMD_ACTIVE          = 3'b011;
wire [2:0] CMD_READ            = 3'b101;
wire [2:0] CMD_WRITE           = 3'b100;
wire [2:0] CMD_PRECHARGE       = 3'b010;
wire [2:0] CMD_AUTO_REFRESH    = 3'b001;
wire [2:0] CMD_LOAD_MODE       = 3'b000;

reg [13:0] refresh_count;
reg  [2:0] command;
reg        chip;

localparam STATE_STARTUP = 0;
localparam STATE_WAIT    = 1;
localparam STATE_RW1     = 2;
localparam STATE_IDLE    = 4;
localparam STATE_IDLE_1  = 5;
localparam STATE_IDLE_2  = 6;
localparam STATE_IDLE_3  = 7;
localparam STATE_IDLE_4  = 8;
localparam STATE_IDLE_5  = 9;
localparam STATE_RFSH    = 10;


always @(posedge clk) begin
    reg [CAS_LATENCY+BURST_LENGTH+1:0] data_ready_delay1, data_ready_delay2, data_ready_delay3, data_ready_delay4;

    reg        saved_wr;
    reg [12:0] cas_addr;
    reg [15:0] saved_data;
    reg [15:0] dq_reg;
    reg  [3:0] state;

    reg       ch1_req_1, ch2_req_1, ch3_req_1, ch4_req_1;
    reg       ch1_rq, ch2_rq, ch3_rq, ch4_rq;
    reg [1:0] ch;

    reg        ch3_rnw_1;
    reg [26:1] ch3_addr_1;
    reg [15:0] ch3_din_1;
    reg [ 1:0] ch3_be_1;
    
    reg        doRefresh_1;
    reg [4:0] object_issue_left,object_response_left;
    reg [3:0] object_quantum_left;
    reg [26:1] object_next_addr;
    reg object_resume,object_long;
    reg [1:0] runtime_next,choice;
    reg choice_valid;
    // Private8-beat/64-byte service quantum. Close rows before rotating clients.
    choice_valid = ch1_rq || ch2_rq || object_resume || ch4_rq;
    // Tile (ch4) lines must be ready by the next raster line, so a waiting
    // tile request is granted first. Under heavy object streaming, plain
    // round robin let tile reads queue behind 8-beat object quanta and the
    // raster blanked the late line (black line through big sprites).
    if(ch4_rq) choice=3;
    else case(runtime_next)
      1: if(ch2_rq || object_resume) choice=1; else choice=0;
      default: if(ch1_rq) choice=0; else choice=1;
    endcase
    trace_object_long <= object_long;
    ch2_beat_valid <= 0;
    ch2_beat_last <= 0;
    
    trace_pending <= {ch4_rq,ch3_rq,(ch2_rq || object_resume),ch1_rq};
    trace_state <= state;
    trace_grant_valid <= 1'b0;
    ch1_req_1 <= ch1_req;
    ch2_req_1 <= ch2_req;
    ch3_req_1 <= ch3_req;
    ch4_req_1 <= ch4_req;
    
    ch3_rnw_1  <= ch3_rnw;
    ch3_addr_1 <= ch3_addr;
    ch3_din_1  <= ch3_din;
    ch3_be_1   <= ch3_be;
    
    doRefresh_1 <= doRefresh;

    if (ch1_req & ~ch1_req_1) ch1_rq <= 1;
    if (ch2_req & ~ch2_req_1) begin
        ch2_rq <= 1;object_long <= ch2_stream;object_next_addr <= ch2_addr;
        object_issue_left <= ch2_stream ? 5'd16 : 5'd1;
        object_response_left <= ch2_stream ? 5'd16 : 5'd1;
    end
    if (ch3_req & ~ch3_req_1) ch3_rq <= 1;
    if (ch4_req & ~ch4_req_1) ch4_rq <= 1;

    ch1_ready <= 0;
    ch2_ready <= 0;
    ch3_ready <= 0;
    ch4_ready <= 0;

    refresh_count <= refresh_count+1'b1;

    data_ready_delay1 <= data_ready_delay1>>1;
    data_ready_delay2 <= data_ready_delay2>>1;
    data_ready_delay3 <= data_ready_delay3>>1;
    data_ready_delay4 <= data_ready_delay4>>1;

    dq_reg <= dq_in;

    // Capture taps: READ issues on core edge E0; the forwarded SDRAM clock
    // (+6.25 ns, CL3) puts beat n on DQ for the core edge E3+n that dq_reg
    // samples. The donor taps assumed ~100 MHz and read beat n+1 here.
    if(data_ready_delay1[5]) ch1_dout[15:00] <= dq_reg;
    if(data_ready_delay1[4]) ch1_dout[31:16] <= dq_reg;
    if(data_ready_delay1[4]) ch1_ready <= 1;

    if(data_ready_delay2[5]) ch2_dout[15:00] <= dq_reg;
    if(data_ready_delay2[4]) ch2_dout[31:16] <= dq_reg;
    if(data_ready_delay2[3]) ch2_dout[47:32] <= dq_reg;
    if(data_ready_delay2[2]) ch2_dout[63:48] <= dq_reg;
    if(data_ready_delay2[2]) begin
        ch2_beat_valid <= 1;ch2_beat_last <= object_response_left==1;
        object_response_left <= object_response_left-5'd1;
        if(object_response_left==1) ch2_ready <= 1;
    end

    if(data_ready_delay3[5]) ch3_dout[15:00] <= dq_reg;
    if(data_ready_delay3[4]) ch3_dout[31:16] <= dq_reg;
    if(data_ready_delay3[3]) ch3_dout[47:32] <= dq_reg;
    if(data_ready_delay3[2]) ch3_dout[63:48] <= dq_reg;
    if(data_ready_delay3[2]) ch3_ready <= 1;

    if(data_ready_delay4[5]) ch4_dout[15:00] <= dq_reg;
    if(data_ready_delay4[4]) ch4_dout[31:16] <= dq_reg;
    if(data_ready_delay4[3]) ch4_dout[47:32] <= dq_reg;
    if(data_ready_delay4[2]) ch4_dout[63:48] <= dq_reg;
    if(data_ready_delay4[2]) ch4_ready <= 1;

    dq_oe <= 1'b0;

    command <= CMD_NOP;
    case (state)
        STATE_STARTUP: begin
            SDRAM_A    <= 13'h1800; // DQM high during startup/settling
            SDRAM_BA   <= 0;

            if (refresh_count == (startup_refresh_max-64)) chip <= 0;
            if (refresh_count == (startup_refresh_max-32)) chip <= 1;

            // All the commands during the startup are NOPS, except these
            if (refresh_count == startup_refresh_max-63 || refresh_count == startup_refresh_max-31) begin
                // ensure all rows are closed
                command     <= CMD_PRECHARGE;
                SDRAM_A[10] <= 1;  // all banks
                SDRAM_BA    <= 2'b00;
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
                SDRAM_A     <= MODE;
            end

            if (refresh_count == 14'd0) begin
                state   <= STATE_IDLE;
                initialized <= 1'b1;
                refresh_count <= 0;
            end
        end

        STATE_IDLE_5: state <= STATE_IDLE_4;
        STATE_IDLE_4: state <= STATE_IDLE_3;
        STATE_IDLE_3: state <= STATE_IDLE_2;
        STATE_IDLE_2: begin
            if(ch==1 && object_quantum_left!=0) begin
                SDRAM_A <= cas_addr;SDRAM_A[10] <= object_quantum_left==1;
                command <= CMD_READ;state <= STATE_IDLE_5;
                data_ready_delay2[CAS_LATENCY+BURST_LENGTH+1] <= 1;
                cas_addr[8:0] <= cas_addr[8:0]+9'd4;
                object_next_addr <= object_next_addr+26'd4;
                object_issue_left <= object_issue_left-5'd1;
                object_quantum_left <= object_quantum_left-4'd1;
                if(object_quantum_left==1 && object_issue_left>1) object_resume<=1;
            end else state <= STATE_IDLE_1;
        end
        STATE_IDLE_1: state <= STATE_IDLE;

        STATE_RFSH: begin
            state    <= STATE_IDLE_5;
            command  <= CMD_AUTO_REFRESH;
            chip     <= 1;
        end

        STATE_IDLE: begin
            // Reserve the full retained-row quantum before refresh is due.
            if(refresh_count>cycles_per_refresh ||
               (choice_valid && choice==1 && object_issue_left>1 && refresh_count+14'd40>cycles_per_refresh)) begin
                state<=STATE_RFSH;command<=CMD_AUTO_REFRESH;chip<=0;
                refresh_count<=refresh_count>cycles_per_refresh ? refresh_count-cycles_per_refresh+1'd1 : 14'd0;
            end else if(ch3_rq) begin
                chip<=ch3_addr_1[26];saved_data<=ch3_din_1;saved_wr<=~ch3_rnw_1;ch<=2;ch3_rq<=0;
                if(ch3_rnw_1) {cas_addr[12:9],SDRAM_BA,SDRAM_A,cas_addr[8:0]}<={2'b00,1'b1,ch3_addr_1[25:1]};
                else {cas_addr[12:9],SDRAM_BA,SDRAM_A,cas_addr[8:0]}<={~ch3_be_1,1'b1,ch3_addr_1[25:1]};
                command<=CMD_ACTIVE;state<=STATE_WAIT;trace_grant_valid<=1;trace_grant_client<=2;
            end else if(choice_valid) begin
                saved_wr<=0;ch<=choice;command<=CMD_ACTIVE;state<=STATE_WAIT;
                trace_grant_valid<=1;trace_grant_client<=choice;
                runtime_next<=choice==0 ? 1 : choice==1 ? 2 : 0;
                case(choice)
                    0: begin
                        {cas_addr[12:9],SDRAM_BA,SDRAM_A,cas_addr[8:0]}<={2'b00,1'b1,ch1_addr[25:1]};
                        chip<=ch1_addr[26];ch1_rq<=0;
                    end
                    1: begin
                        {cas_addr[12:9],SDRAM_BA,SDRAM_A,cas_addr[8:0]}<={2'b00,1'b0,object_next_addr[25:1]};
                        chip<=object_next_addr[26];ch2_rq<=0;object_resume<=0;
                        object_quantum_left<=object_issue_left>8 ? 4'd8 : object_issue_left[3:0];
                    end
                    default: begin
                        {cas_addr[12:9],SDRAM_BA,SDRAM_A,cas_addr[8:0]}<={2'b00,1'b1,ch4_addr[25:1]};
                        chip<=ch4_addr[26];ch4_rq<=0;
                    end
                endcase
            end else if(doRefresh_1) begin
                state<=STATE_RFSH;command<=CMD_AUTO_REFRESH;refresh_count<=0;chip<=0;
            end
        end

        STATE_WAIT: state <= STATE_RW1;
        STATE_RW1: begin
            SDRAM_A <= cas_addr;
            if(saved_wr) begin
                command  <= CMD_WRITE;
                dq_out <= saved_data;
                dq_oe <= 1'b1;
                if(ch == 0) ch1_ready  <= 1;
                if(ch == 1) ch2_ready  <= 1;
                if(ch == 2) ch3_ready  <= 1;
                if(ch == 3) ch4_ready  <= 1;
                state <= STATE_IDLE_2;
            end
            else begin
                command <= CMD_READ;
                state   <= STATE_IDLE_5;
                if(ch==1) begin
                    SDRAM_A[10] <= object_quantum_left==1;
                    cas_addr[8:0] <= cas_addr[8:0]+9'd4;
                    object_next_addr <= object_next_addr+26'd4;
                    object_issue_left <= object_issue_left-5'd1;
                    object_quantum_left <= object_quantum_left-4'd1;
                    if(object_quantum_left==1 && object_issue_left>1) object_resume<=1;
                end
                     if(ch == 0) data_ready_delay1[CAS_LATENCY+BURST_LENGTH+1] <= 1;
                else if(ch == 1) data_ready_delay2[CAS_LATENCY+BURST_LENGTH+1] <= 1;
                else if(ch == 2) data_ready_delay3[CAS_LATENCY+BURST_LENGTH+1] <= 1;
                else             data_ready_delay4[CAS_LATENCY+BURST_LENGTH+1] <= 1;
            end
        end
      
    endcase

    if (init) begin
        object_issue_left<=0;object_response_left<=0;object_quantum_left<=0;object_next_addr<=0;
        object_resume<=0;object_long<=0;runtime_next<=0;choice<=0;choice_valid<=0;
        ch2_beat_valid<=0;ch2_beat_last<=0;trace_object_long<=0;
        trace_pending <= 0;trace_state <= STATE_STARTUP;trace_grant_client <= 0;trace_grant_valid <= 0;
        state <= STATE_STARTUP;
        refresh_count <= startup_refresh_max - sdram_startup_cycles;
        initialized <= 1'b0;
        chip <= 1'b0;
        command <= CMD_NOP;
        SDRAM_A <= 13'h1800; SDRAM_BA <= 2'd0;
        dq_out <= 16'd0; dq_oe <= 1'b0;
        dq_reg <= 16'd0; saved_data <= 16'd0; saved_wr <= 1'b0; cas_addr <= 13'd0;
        ch1_req_1 <= 0; ch2_req_1 <= 0; ch3_req_1 <= 0; ch4_req_1 <= 0;
        ch1_rq <= 0; ch2_rq <= 0; ch3_rq <= 0; ch4_rq <= 0; ch <= 0;
        ch3_rnw_1 <= 1; ch3_addr_1 <= 0; ch3_din_1 <= 0; ch3_be_1 <= 0;
        doRefresh_1 <= 0;
        data_ready_delay1 <= 0; data_ready_delay2 <= 0;
        data_ready_delay3 <= 0; data_ready_delay4 <= 0;
        ch1_dout <= 0; ch2_dout <= 0; ch3_dout <= 0; ch4_dout <= 0;
        ch1_ready <= 0; ch2_ready <= 0; ch3_ready <= 0; ch4_ready <= 0;
    end
end

`ifdef VERILATOR
assign SDRAM_CLK = ~clk; // functional model of the unchanged DDR clock primitive
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
    .outclock(clk),
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
