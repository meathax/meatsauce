// SPDX-License-Identifier: GPL-3.0-or-later
// Real sound CPU and ES5505 feeding the qualified native gain/pump/device path.
// CPU/sampler32MHz, audio device/cache96MHz, shared DDR service64MHz. CPU reset
// is separate from audio reset so initial physical RAM clear can finish before
// CPU boot is released. Complete board coupling/timing remains to be qualified.
module gs_sound_devices_full #(parameter integer SYS_HZ=32000000)(
    input wire clk,dsp_clk,ram_clk,cold_reset,reset,audio_reset,pause,
    output wire mem_req,mem_write,output wire [23:0] mem_addr,
    output wire [15:0] mem_wdata,output wire [1:0] mem_be,
    input wire mem_ack,input wire [15:0] mem_rdata,
    output wire sm_req,output wire [22:3] sm_addr,
    input wire [63:0] sm_line,input wire sm_valid,sm_busy,
    output wire dsp_halt,running,
    output wire debug_req,debug_ack,debug_write,debug_fetch,
    output wire [31:0] debug_addr,output wire [15:0] debug_wdata,
    output wire [1:0] debug_be,output wire [2:0] debug_fc,output wire debug_irq,
    output wire sample_valid,pcm_valid,output wire signed [15:0] pcm_l,pcm_r,
    output wire [15:0] sampler_overrun,sampler_drop,input_overrun,output_underrun,max_sample_cycles,
    output wire startup_ready,audio_fault,
    input wire DDRAM_BUSY,output wire [7:0] DDRAM_BURSTCNT,output wire [28:0] DDRAM_ADDR,
    input wire [63:0] DDRAM_DOUT,input wire DDRAM_DOUT_READY,output wire DDRAM_RD,
    output wire [63:0] DDRAM_DIN,output wire [7:0] DDRAM_BE,output wire DDRAM_WE
);
    (* altera_attribute="-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *) reg [1:0] audio_start_s;
    always @(posedge clk)begin
        audio_start_s<={audio_start_s[0],startup_ready};
        if(cold_reset || reset)audio_start_s<=0;
    end
    wire board_reset=reset || !audio_start_s[1];
    wire chip_req,chip_write,chip_ack;wire [23:0] chip_addr;
    wire [15:0] chip_wdata,chip_rdata;wire [1:0] chip_be;
    wire board_mem_req;
    // The sound bootstrap holds COPY_READ while reset is asserted. Its memory
    // request must not escape that reset and consume the one held-bus response
    // before initial audio RAM clear releases CPU boot.
    assign mem_req=board_mem_req && !board_reset;
    gs_sound #(.SYS_HZ(SYS_HZ)) board(
        .clk(clk),.reset(board_reset),.pause(pause),
        .mem_req(board_mem_req),.mem_write(mem_write),.mem_addr(mem_addr),.mem_wdata(mem_wdata),.mem_be(mem_be),.mem_ack(mem_ack && !board_reset),.mem_rdata(mem_rdata),
        .chip_req(chip_req),.chip_write(chip_write),.chip_addr(chip_addr),.chip_wdata(chip_wdata),.chip_be(chip_be),.chip_ack(chip_ack),.chip_rdata(chip_rdata),
        .dsp_halt(dsp_halt),.running(running),
        .debug_req(debug_req),.debug_ack(debug_ack),.debug_write(debug_write),.debug_fetch(debug_fetch),.debug_addr(debug_addr),.debug_wdata(debug_wdata),.debug_be(debug_be),.debug_fc(debug_fc),.debug_irq(debug_irq));
    reg seen;
    wire accept=chip_req && !seen;
    always @(posedge clk)begin
        if(board_reset || !chip_req)seen<=0;else seen<=1;
    end
    wire es_sel=chip_addr[23:5]==19'h10000;
    wire host_sel=chip_addr[23:9]==15'h1300;
    wire bank_sel=chip_addr[23:6]==18'hc000;
    wire volume_sel=chip_addr[23:2]==22'hd0000;
    wire [15:0] es_rdata;wire es_valid;wire [7:0] irqv,host_rdata;
    wire [4:0] active;wire [159:0] channels;
    reg [31:0] phase;reg [8:0] sample_div;reg sample_tick;
    wire [32:0] phase_next={1'b0,phase}+33'd15238090;
    wire crystal_ce=phase_next>=33'(SYS_HZ);
    wire [9:0] sample_period=({5'd0,active}+10'd1)<<4;
    always @(posedge clk)begin
        sample_tick<=0;
        if(board_reset)begin phase<=0;sample_div<=0;end
        else if(!pause)begin
            phase<=crystal_ce?32'(phase_next-33'(SYS_HZ)):phase_next[31:0];
            if(crystal_ce)begin
                if({1'b0,sample_div}+10'd1>=sample_period)begin sample_div<=0;sample_tick<=1;end
                else sample_div<=sample_div+1'b1;
            end
        end
    end
    rf_es5505 sampler(
        .clk(clk),.reset(board_reset),
        .es_we(accept && chip_write && es_sel),.es_reg(chip_addr[4:1]),.es_data(chip_wdata),.es_be(chip_be),
        .bk_we(accept && chip_write && bank_sel),.bk_voice(chip_addr[5:1]),.bk_data(chip_wdata[2:0]),.bank_mask(3'd7),
        .sm_req(sm_req),.sm_addr(sm_addr),.sm_line(sm_line),.sm_valid(sm_valid),.sm_busy(sm_busy),
        .tick(sample_tick),.out_valid(sample_valid),.out_ch(channels),.out_active(active),.irqv_out(irqv),
        .rd_req(chip_req && !chip_write && es_sel),.rd_reg(chip_addr[4:1]),.rd_data(es_rdata),.rd_valid(es_valid),
        .irqv_ack(accept && !chip_write && es_sel && chip_addr[4:1]==4'he),
        .dbg_overrun(sampler_overrun),.dbg_miss(),.dbg_wqdrop(sampler_drop));
    wire [6:0] gain_l,gain_r;wire [7:0] volume_rdata;
    gs_mb87078 volume(
        .clk(clk),.cold_reset(cold_reset),.reset(board_reset),.we(accept && chip_write && volume_sel && chip_be[1]),
        .offset(~chip_addr[1]),.data(chip_wdata[15:8]),.rdata(volume_rdata),.gain_l(gain_l),.gain_r(gain_r),.inspect_channel(2'b0),.inspect_gain());
    wire host_ack,engine_fault,reply_overflow;
    wire audio_busy,audio_ready,audio_rd,audio_we;wire [7:0] audio_burst,audio_be;
    wire [28:0] audio_addr;wire [63:0] audio_din,audio_dout;
    gs_audio_engine engine(
        .cpu_clk(clk),.dsp_clk(dsp_clk),.cold_reset(cold_reset),.reset(audio_reset),.pause(pause),.esp_halted(dsp_halt),
        .host_req(chip_req && host_sel && chip_be[0]),.host_write(chip_write),.host_addr(chip_addr[8:1]),.host_wdata(chip_wdata[7:0]),.host_ack(host_ack),.host_rdata(host_rdata),
        .sample_event(sample_valid),.sample_tick(sample_tick),.channels(channels),.gain_l(gain_l),.gain_r(gain_r),
        .startup_ready(startup_ready),.pcm_valid(pcm_valid),.pcm_l(pcm_l),.pcm_r(pcm_r),.input_overrun(input_overrun),.output_underrun(output_underrun),
        .fault(engine_fault),.max_sample_cycles(max_sample_cycles),.inspect_reg(8'b0),.inspect_data(),
        .DDRAM_BUSY(audio_busy),.DDRAM_DOUT_READY(audio_ready),.DDRAM_DOUT(audio_dout),
        .DDRAM_BURSTCNT(audio_burst),.DDRAM_ADDR(audio_addr),.DDRAM_RD(audio_rd),.DDRAM_WE(audio_we),.DDRAM_DIN(audio_din),.DDRAM_BE(audio_be));
    gs_ddr_cdc bridge(
        .client_clk(dsp_clk),.ram_clk(ram_clk),.cold_reset(cold_reset),
        .client_rd(audio_rd),.client_we(audio_we),.client_burstcnt(audio_burst),.client_addr(audio_addr),.client_din(audio_din),.client_be(audio_be),
        .client_busy(audio_busy),.client_dout_ready(audio_ready),.client_dout(audio_dout),.reply_overflow(reply_overflow),
        .DDRAM_BUSY(DDRAM_BUSY),.DDRAM_DOUT_READY(DDRAM_DOUT_READY),.DDRAM_DOUT(DDRAM_DOUT),
        .DDRAM_BURSTCNT(DDRAM_BURSTCNT),.DDRAM_ADDR(DDRAM_ADDR),.DDRAM_RD(DDRAM_RD),.DDRAM_WE(DDRAM_WE),.DDRAM_DIN(DDRAM_DIN),.DDRAM_BE(DDRAM_BE));
    assign audio_fault=engine_fault || reply_overflow;
    assign chip_ack=host_sel && chip_be[0]?host_ack:es_sel && !chip_write?es_valid:chip_req;
    assign chip_rdata=host_sel && chip_be[0]?{8'hff,host_rdata}:es_sel && !chip_write?es_rdata:16'hffff;
endmodule
