// SPDX-License-Identifier: GPL-3.0-or-later
// Pinned JTFRAME SDRAM64 adapter: four-word reads and single-word downloads.
// One root clock. The external forwarded-clock/pin envelope needs separate
// qualification; SHIFTED selects controller flags, never a timing exception.
module madmotor_sdram #(
    parameter integer SHIFTED=1,
    parameter integer SYS_HZ=48000000,
    parameter integer HF=(SYS_HZ>48000000)
)(
    input wire clk,reset,host_reset,
    output wire initializing,
    input wire mem_req,
    input wire [23:0] mem_addr,
    output wire mem_ok,
    output reg [63:0] mem_data,
    input wire load_mode,load_req,
    input wire [23:0] load_addr,
    input wire [15:0] load_data,
    input wire [1:0] load_mask, // active-high byte masks, not byte enables
    output wire load_ok,
    inout wire [15:0] sdram_dq,
`ifdef VERILATOR
    output wire [15:0] sdram_din,
`endif
    output wire [12:0] sdram_a,
    output wire [1:0] sdram_ba,
    output wire sdram_dqml,sdram_dqmh,
    output wire sdram_nwe,sdram_ncas,sdram_nras,sdram_ncs,sdram_cke
);
    localparam [2:0] IDLE=0,READ_ISSUE=1,READ_DATA=2,READ_REPLY=3,
        LOAD_ISSUE=4,LOAD_WAIT=5,LOAD_REPLY=6;
    reg [2:0] state;
    reg [23:0] address;
    reg [15:0] download_data;
    reg [1:0] download_mask,beat;
    reg cancelled;
    reg [63:0] assembly;
    wire [3:0] ack,dok,rdy;
    wire [15:0] read_word;
    wire prog_ack,prog_rdy;
    wire programming=state==LOAD_ISSUE||state==LOAD_WAIT||state==LOAD_REPLY||
        (state==IDLE&&load_mode);
    wire [3:0] rd=state==READ_ISSUE ? (4'b0001<<address[23:22]) : 4'b0000;
    assign mem_ok=state==READ_REPLY&&!cancelled&&!host_reset&&mem_req;
    assign load_ok=state==LOAD_REPLY;
    localparam integer REFRESH_ROOTS=(64'(SYS_HZ)*3)/400000;
    localparam integer REFRESH_WIDTH=$clog2(REFRESH_ROOTS);
    reg [REFRESH_WIDTH-1:0] refresh_count;
    reg refresh;
    // 8192 refreshes in61.44ms, independent of pause/video/download.
    always @(posedge clk)begin
        if(reset||initializing)begin refresh_count<=0;refresh<=0;end
        else begin
            refresh<=refresh_count==REFRESH_WIDTH'(REFRESH_ROOTS-1);
            refresh_count<=refresh_count==REFRESH_WIDTH'(REFRESH_ROOTS-1)?
                           {REFRESH_WIDTH{1'b0}}:refresh_count+1'b1;
        end
    end
    // The pinned LF/HF controller waits5000/10000roots. Extend its reset only
    // if that wait would shorten the existing5000/48MHz initial interval.
    // This preserves the baseline, not an unidentified SDRAM part's tINIT.
    localparam integer CONTROLLER_INIT_ROOTS=HF?10000:5000;
    localparam integer MIN_INIT_ROOTS=(64'(SYS_HZ)*5000+47999999)/48000000;
    localparam integer EXTRA_INIT_ROOTS=MIN_INIT_ROOTS>CONTROLLER_INIT_ROOTS?
        MIN_INIT_ROOTS-CONTROLLER_INIT_ROOTS:0;
    wire controller_reset;
    generate if(EXTRA_INIT_ROOTS==0) begin: original_init
        assign controller_reset=reset;
    end else begin: extended_init
        localparam integer INIT_WIDTH=$clog2(EXTRA_INIT_ROOTS+1);
        reg [INIT_WIDTH-1:0] initial_reset_count;
        always @(posedge clk) begin
            if(reset)initial_reset_count<=0;
            else if(initial_reset_count!=INIT_WIDTH'(EXTRA_INIT_ROOTS))
                initial_reset_count<=initial_reset_count+1'b1;
        end
        assign controller_reset=reset||
            initial_reset_count!=INIT_WIDTH'(EXTRA_INIT_ROOTS);
    end endgenerate
    // At60MHz a single command gap is16.667ns; HF inserts the idle slots
    // required by the explicit20ns pin-model tRP/tRCD envelope. Read-beat
    // alignment and physical target timing require their own qualification.
    jtframe_sdram64 #(.AW(22),.HF(HF),.SHIFTED(SHIFTED),
        .BA0_LEN(64),.BA1_LEN(64),.BA2_LEN(64),.BA3_LEN(64),.PROG_LEN(16),
        .BA0_WEN(0),.BA1_WEN(0),.BA2_WEN(0),.BA3_WEN(0),.RFSHCNT(1)) controller(
        .rst(controller_reset),.clk(clk),.init(initializing),
        .ba0_addr(address[21:0]),.ba1_addr(address[21:0]),
        .ba2_addr(address[21:0]),.ba3_addr(address[21:0]),.rd(rd),.wr(4'd0),
        .ba0_din(16'd0),.ba1_din(16'd0),.ba2_din(16'd0),.ba3_din(16'd0),
        .ba0_dsn(2'd3),.ba1_dsn(2'd3),.ba2_dsn(2'd3),.ba3_dsn(2'd3),
        .prog_en(programming),.prog_addr(address[21:0]),.prog_rd(1'b0),
        .prog_wr(state==LOAD_ISSUE),.prog_din(download_data),.prog_dsn(download_mask),
        .prog_ba(address[23:22]),.prog_ack(prog_ack),.prog_rdy(prog_rdy),
        .prog_dst(),.prog_dok(),.rfsh(refresh),.ack(ack),.dst(),.dok(dok),.rdy(rdy),.dout(read_word),
        .sdram_dq(sdram_dq),
`ifdef VERILATOR
        .sdram_din(sdram_din),
`endif
        .sdram_a(sdram_a),.sdram_ba(sdram_ba),.sdram_dqml(sdram_dqml),.sdram_dqmh(sdram_dqmh),
        .sdram_nwe(sdram_nwe),.sdram_ncas(sdram_ncas),.sdram_nras(sdram_nras),
        .sdram_ncs(sdram_ncs),.sdram_cke(sdram_cke)
    );
    always @(posedge clk)begin
        if(reset||initializing)begin
            state<=IDLE;address<=0;download_data<=0;download_mask<=3;
            beat<=0;cancelled<=0;assembly<=0;mem_data<=0;
        end else begin
            if(state==READ_ISSUE||state==READ_DATA||state==READ_REPLY)
                if(host_reset||!mem_req)cancelled<=1;
            case(state)
                IDLE:begin
                    cancelled<=0;beat<=0;
                    if(load_mode&&load_req)begin
                        address<=load_addr;download_data<=load_data;download_mask<=load_mask;state<=LOAD_ISSUE;
                    end else if(!load_mode&&!host_reset&&mem_req)begin
                        address<=mem_addr;state<=READ_ISSUE;
                    end
                end
                READ_ISSUE:if(ack[address[23:22]])state<=READ_DATA;
                READ_DATA:if(dok[address[23:22]])begin
                    assembly[16*beat+:16]<=read_word;beat<=beat+2'd1;
                    if(beat==3)begin
                        mem_data<={read_word,assembly[47:0]};
                        state<=cancelled||host_reset||!mem_req?IDLE:READ_REPLY;
                    end
                end
                READ_REPLY:if(cancelled||host_reset||!mem_req)state<=IDLE;
                LOAD_ISSUE:if(prog_ack)state<=prog_rdy?LOAD_REPLY:LOAD_WAIT;
                LOAD_WAIT:if(prog_rdy)state<=LOAD_REPLY;
                LOAD_REPLY:if(!load_req)state<=IDLE;
                default:state<=IDLE;
            endcase
        end
    end
endmodule
