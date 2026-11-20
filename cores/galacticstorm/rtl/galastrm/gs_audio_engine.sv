// SPDX-License-Identifier: BSD-3-Clause
// Native sound CPU host bridge, queued raw sampler routes, actual ES5510
// execution/physical delay RAM, and fixed-rate PCM playout. No sample skipping
// or substitute dry sum. Startup is held until physical native RAM clear ends.
module gs_audio_engine(
    input wire cpu_clk,dsp_clk,cold_reset,reset,pause,esp_halted,
    input wire host_req,host_write,input wire [7:0] host_addr,host_wdata,
    output wire host_ack,output wire [7:0] host_rdata,
    input wire sample_event,sample_tick,input wire [159:0] channels,
    input wire [6:0] gain_l,gain_r,
    output wire startup_ready,output reg pcm_valid,output reg signed [15:0] pcm_l,pcm_r,
    output reg [15:0] input_overrun,output reg [15:0] output_underrun,
    output wire fault,output wire [15:0] max_sample_cycles,
    input wire [7:0] inspect_reg,output wire [31:0] inspect_data,
    input wire DDRAM_BUSY,output wire [7:0] DDRAM_BURSTCNT,output wire [28:0] DDRAM_ADDR,
    input wire [63:0] DDRAM_DOUT,input wire DDRAM_DOUT_READY,output wire DDRAM_RD,
    output wire [63:0] DDRAM_DIN,output wire [7:0] DDRAM_BE,output wire DDRAM_WE
);
    // Board reset/ROM-ready holds span multiple DSP clocks. Capture their
    // combined level locally before the DSP release chain, giving its recovery
    // path a full DSP period. Cold reset remains distinct for DDR draining.
    wire reset_request=reset || cold_reset;
    (* preserve *) reg dsp_reset_request=1'b1;
    always @(posedge dsp_clk) dsp_reset_request<=reset_request;
    (* preserve, altera_attribute="-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *) reg [1:0] dsp_reset_s=2'b11,dsp_cold_s=2'b11;
    always @(posedge dsp_clk or posedge dsp_reset_request)
        if(dsp_reset_request)dsp_reset_s<=2'b11;else dsp_reset_s<={dsp_reset_s[0],1'b0};
    always @(posedge dsp_clk or posedge cold_reset)
        if(cold_reset)dsp_cold_s<=2'b11;else dsp_cold_s<={dsp_cold_s[0],1'b0};
    wire dsp_reset=dsp_reset_s[1],dsp_cold_reset=dsp_cold_s[1];
    wire clear_busy,pump_busy,pump_ack,pump_valid;
    // The delay clear starts on the reset edge and may finish while reset is
    // still held (the MiSTer ROM download outlasts it). Forget an older clear
    // only at that edge, so a clear completed inside reset still releases.
    reg clear_seen=0,started_dsp=0,dsp_reset_q=0;
    assign startup_ready=started_dsp;
    always @(posedge dsp_clk)begin
        dsp_reset_q<=dsp_reset;
        if(clear_busy)clear_seen<=1;
        if(dsp_reset && !dsp_reset_q)clear_seen<=0;
        if(clear_seen && !clear_busy && !dsp_reset)started_dsp<=1;
        if(dsp_reset)started_dsp<=0;
    end
    wire dsp_host_req,dsp_host_write,dsp_host_ack;
    wire [24:0] dsp_host_addr;
    wire [15:0] dsp_host_wdata,cpu_host_rdata;
    wire [1:0] dsp_host_bytes;
    wire [7:0] dsp_host_rdata;
    assign host_rdata=cpu_host_rdata[7:0];
    gs_bus_cdc host_bridge(
        .cpu_clk(cpu_clk),.ram_clk(dsp_clk),.reset(dsp_reset_request),
        .cpu_req(host_req),.cpu_write(host_write),.cpu_addr({17'b0,host_addr}),
        .cpu_wdata({8'b0,host_wdata}),.cpu_bytes(2'b01),.cpu_ack(host_ack),.cpu_idle(),.cpu_rdata(cpu_host_rdata),
        .ram_req(dsp_host_req),.ram_write(dsp_host_write),.ram_addr(dsp_host_addr),.ram_wdata(dsp_host_wdata),
        .ram_bytes(dsp_host_bytes),.ram_ack(dsp_host_ack),.ram_rdata({8'b0,dsp_host_rdata}));
    (* altera_attribute="-name SYNCHRONIZER_IDENTIFICATION FORCED" *) reg [1:0] start_s,pause_s;
    always @(posedge cpu_clk)begin start_s<={start_s[0],started_dsp};if(reset || cold_reset)start_s<=0;end
    always @(posedge dsp_clk)begin pause_s<={pause_s[0],pause};if(dsp_reset)pause_s<=0;end
    wire raw_full,raw_empty,raw_pop;
    wire [174:0] raw_word;
    gs_async_fifo #(.DW(175),.AW(3),.RAMSTYLE("M10K, no_rw_check")) input_queue(
        .wr_clk(cpu_clk),.wr_reset(reset || cold_reset),.wr_en(sample_event && start_s[1]),.wr_data({esp_halted,gain_r,gain_l,channels}),.full(raw_full),
        .rd_clk(dsp_clk),.rd_reset(dsp_reset),.rd_en(raw_pop),.rd_data(raw_word),.empty(raw_empty),.rd_level());
    always @(posedge cpu_clk)begin
        if(sample_event && start_s[1] && raw_full && input_overrun!=16'hffff)input_overrun<=input_overrun+1'b1;
        if(reset || cold_reset)input_overrun<=0;
    end
    localparam IDLE=0,SCALE=1,PUMP_START=2,PUMP=3,MIX_START=4,MIX=5,PUSH=6;
    reg [2:0] state;
    reg scaler_req,pump_req,mix_req;
    reg [159:0] saved_channels;
    reg [6:0] saved_gain_l,saved_gain_r;
    reg saved_halted;
    wire scaler_ack,scaler_valid,scaler_busy;
    wire [127:0] routed_serial;
    wire [31:0] routed_aux_l,routed_aux_r;
    reg [127:0] saved_serial;
    reg [31:0] saved_aux_l,saved_aux_r;
    wire signed [15:0] processed_l,processed_r;
    reg signed [15:0] saved_processed_l,saved_processed_r;
    wire mixer_ack,mixer_valid,mixer_busy;
    wire signed [15:0] mixed_l,mixed_r;
    reg [31:0] mixed_word;
    wire pcm_full,pcm_empty,pcm_pop;
    wire [31:0] pcm_word;
    wire [3:0] pcm_level;
    reg playing;
    assign raw_pop=state==IDLE && !raw_empty && !pause_s[1] && started_dsp;
    gs_audio_input input_routes(.clk(dsp_clk),.reset(dsp_reset),.req(scaler_req),.channels(saved_channels),
        .gain_l(saved_gain_l),.gain_r(saved_gain_r),.ack(scaler_ack),.valid(scaler_valid),.busy(scaler_busy),
        .serial_input(routed_serial),.aux_l(routed_aux_l),.aux_r(routed_aux_r));
    gs_es5510_physical dsp(
        .clk(dsp_clk),.cold_reset(dsp_cold_reset),.reset(dsp_reset),.pause(1'b0),.esp_halted(saved_halted),
        .host_req(dsp_host_req),.host_write(dsp_host_write),.host_addr(dsp_host_addr[7:0]),.host_wdata(dsp_host_wdata[7:0]),
        .host_ack(dsp_host_ack),.host_rdata(dsp_host_rdata),
        .sample_req(pump_req),.sample_input(saved_serial),.sample_ack(pump_ack),.output_valid(pump_valid),
        .processed_l(processed_l),.processed_r(processed_r),.aux_l(),.aux_r(),.fault(fault),.busy(pump_busy),.clear_busy(clear_busy),
        .sample_cycles(),.max_sample_cycles(max_sample_cycles),.inspect_reg(inspect_reg),.inspect_data(inspect_data),
        .DDRAM_BUSY(DDRAM_BUSY),.DDRAM_BURSTCNT(DDRAM_BURSTCNT),.DDRAM_ADDR(DDRAM_ADDR),
        .DDRAM_DOUT(DDRAM_DOUT),.DDRAM_DOUT_READY(DDRAM_DOUT_READY),.DDRAM_RD(DDRAM_RD),
        .DDRAM_DIN(DDRAM_DIN),.DDRAM_BE(DDRAM_BE),.DDRAM_WE(DDRAM_WE));
    gs_audio_output output_routes(.clk(dsp_clk),.reset(dsp_reset),.req(mix_req),
        .processed_l(saved_processed_l),.processed_r(saved_processed_r),.aux_l(saved_aux_l),.aux_r(saved_aux_r),
        .gain_l(saved_gain_l),.gain_r(saved_gain_r),.ack(mixer_ack),.valid(mixer_valid),.busy(mixer_busy),.pcm_l(mixed_l),.pcm_r(mixed_r));
    always @(posedge dsp_clk)begin
        if(scaler_ack)scaler_req<=0;if(pump_ack)pump_req<=0;if(mixer_ack)mix_req<=0;
        case(state)
        IDLE:if(raw_pop)begin
            {saved_halted,saved_gain_r,saved_gain_l,saved_channels}<=raw_word;scaler_req<=1;state<=SCALE;
        end
        SCALE:if(scaler_valid)begin saved_serial<=routed_serial;saved_aux_l<=routed_aux_l;saved_aux_r<=routed_aux_r;pump_req<=1;state<=PUMP_START;end
        PUMP_START:if(pump_ack)state<=PUMP;
        PUMP:if(pump_valid)begin saved_processed_l<=processed_l;saved_processed_r<=processed_r;mix_req<=1;state<=MIX_START;end
        MIX_START:if(mixer_ack)state<=MIX;
        MIX:if(mixer_valid)begin mixed_word<={mixed_r,mixed_l};state<=PUSH;end
        PUSH:if(!pcm_full)state<=IDLE;
        endcase
        if(dsp_reset)begin state<=IDLE;scaler_req<=0;pump_req<=0;mix_req<=0;saved_halted<=1;end
    end
    gs_async_fifo #(.DW(32),.AW(3)) output_queue(
        .wr_clk(dsp_clk),.wr_reset(dsp_reset),.wr_en(state==PUSH),.wr_data(mixed_word),.full(pcm_full),
        .rd_clk(cpu_clk),.rd_reset(reset || cold_reset),.rd_en(pcm_pop),.rd_data(pcm_word),.empty(pcm_empty),.rd_level(pcm_level));
    assign pcm_pop=sample_tick && playing && !pause && !pcm_empty;
    always @(posedge cpu_clk)begin
        pcm_valid<=0;
        if(!playing && pcm_level>=4)playing<=1;
        if(pcm_pop)begin pcm_l<=pcm_word[15:0];pcm_r<=pcm_word[31:16];pcm_valid<=1;end
        if(sample_tick && playing && !pause && pcm_empty && output_underrun!=16'hffff)output_underrun<=output_underrun+1'b1;
        if(reset || cold_reset)begin pcm_valid<=0;pcm_l<=0;pcm_r<=0;playing<=0;output_underrun<=0;end
    end
endmodule
