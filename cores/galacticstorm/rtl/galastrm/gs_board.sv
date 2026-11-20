// SPDX-License-Identifier: GPL-3.0-or-later
// Paired real CPU board frontend with selectable native full sound integration.
// The legacy diagnostic profile remains available for focused CPU/GPU checks.
module gs_board #(parameter integer SYS_HZ=32000000,parameter FULL_AUDIO=0,parameter SAMPLE_LINES=0,parameter LINE_WRITES=0)(
    input logic clk,reset,pause,vblank,
    input wire dsp_clk,ram_clk,cold_reset,audio_reset,
    input wire main_bus_pause,main_cpu_turbo,
    output wire main_bus_idle,
    input logic [7:0] in0,in2,stick_x,stick_y,
    input logic nvram_ld_wr,input logic [5:0] nvram_ld_addr,nvram_sv_addr,
    input logic [15:0] nvram_ld_data,output wire [15:0] nvram_sv_data,output wire nvram_dirty,
    input logic pixel_ce,input logic [11:0] pixel_index,output wire [23:0] pixel_rgb,
    output wire [383:0] scp_controls,output wire [127:0] scn_controls,
    output wire [255:0] affine_controls,
    output logic mem_req,mem_write,output logic [24:0] mem_addr,
    output logic [15:0] mem_wdata,output logic [1:0] mem_be,
    output wire mem_write_line,output wire [63:0] mem_wline,
    input logic mem_ack,input logic [15:0] mem_rdata,input wire [63:0] mem_rline,
    output wire main_debug_req,main_debug_ack,main_debug_write,main_debug_fetch,
    output wire [31:0] main_debug_addr,output wire [15:0] main_debug_wdata,
    output wire [1:0] main_debug_be,output wire [2:0] main_debug_fc,main_debug_irq_n,
    output wire sound_debug_req,sound_debug_ack,sound_debug_write,sound_debug_fetch,
    output wire [31:0] sound_debug_addr,output wire [15:0] sound_debug_wdata,
    output wire [1:0] sound_debug_be,output wire [2:0] sound_debug_fc,
    output wire sound_debug_irq,sound_running,sample_valid,dsp_halt,
    output wire signed [15:0] dry_l,dry_r,
    output wire [15:0] sampler_drop,sampler_overrun,
    output wire pcm_valid,output wire signed [15:0] pcm_l,pcm_r,
    output wire audio_startup_ready,audio_fault,
    output wire [15:0] audio_input_overrun,audio_output_underrun,audio_max_sample_cycles,
    input wire AUDIO_DDRAM_BUSY,output wire [7:0] AUDIO_DDRAM_BURSTCNT,output wire [28:0] AUDIO_DDRAM_ADDR,
    input wire [63:0] AUDIO_DDRAM_DOUT,input wire AUDIO_DDRAM_DOUT_READY,output wire AUDIO_DDRAM_RD,
    output wire [63:0] AUDIO_DDRAM_DIN,output wire [7:0] AUDIO_DDRAM_BE,output wire AUDIO_DDRAM_WE
);
    wire m_req,m_write,m_ack,s_req,s_write,s_ack;
    wire m_write_line;wire [63:0] m_wline;
    wire [23:0] m_addr,s_addr;
    wire [15:0] m_wdata,m_rdata,s_wdata,s_rdata;
    wire [1:0] m_be,s_be;
    wire m_mail=m_addr[23:11]==13'hc00;
    wire s_mail=s_addr[23:12]==12'h140;
    wire m_mail_ack,s_mail_ack,m_ext_ack,s_ext_ack;
    wire [15:0] m_mail_data,s_mail_data,m_ext_data,s_ext_data;
    wire sm_req,sm_busy,sm_valid;
    wire [22:3] sm_addr;
    wire [63:0] sm_line;
    gs_main #(.SYS_HZ(SYS_HZ),.LINE_WRITES(LINE_WRITES)) main_cpu(
        .clk(clk),.reset(reset),.pause(pause),.bus_pause(main_bus_pause),.cpu_turbo(main_cpu_turbo),.bus_idle(main_bus_idle),.vblank(vblank),.in0(in0),.in2(in2),.stick_x(stick_x),.stick_y(stick_y),
        .mem_req(m_req),.mem_addr(m_addr),.mem_wdata(m_wdata),.mem_be(m_be),.mem_write(m_write),.mem_write_line(m_write_line),.mem_wline(m_wline),.mem_ack(m_ack),.mem_rdata(m_rdata),.mem_rline(mem_rline),
        .nvram_ld_wr(nvram_ld_wr),.nvram_ld_addr(nvram_ld_addr),.nvram_ld_data(nvram_ld_data),
        .nvram_sv_addr(nvram_sv_addr),.nvram_sv_data(nvram_sv_data),.nvram_dirty(nvram_dirty),
        .pixel_ce(pixel_ce),.pixel_index(pixel_index),.pixel_rgb(pixel_rgb),
        .scp_controls(scp_controls),.scn_controls(scn_controls),.affine_controls(affine_controls),
        .debug_req(main_debug_req),.debug_ack(main_debug_ack),.debug_addr(main_debug_addr),
        .debug_wdata(main_debug_wdata),.debug_be(main_debug_be),.debug_write(main_debug_write),
        .debug_fetch(main_debug_fetch),.debug_fc(main_debug_fc),.debug_irq_n(main_debug_irq_n),
        .frame_counter(),.watchdog_kick(),.coin_control()
    );
    generate if(FULL_AUDIO)begin: native_sound
    gs_sound_devices_full #(.SYS_HZ(SYS_HZ)) sound_cpu(
        .clk(clk),.dsp_clk(dsp_clk),.ram_clk(ram_clk),.cold_reset(cold_reset),
        .reset(reset),.audio_reset(audio_reset),.pause(pause),
        .mem_req(s_req),.mem_addr(s_addr),.mem_wdata(s_wdata),.mem_be(s_be),.mem_write(s_write),.mem_ack(s_ack),.mem_rdata(s_rdata),
        .sm_req(sm_req),.sm_addr(sm_addr),.sm_line(sm_line),.sm_valid(sm_valid),.sm_busy(sm_busy),
        .running(sound_running),.dsp_halt(dsp_halt),.sample_valid(sample_valid),.pcm_valid(pcm_valid),.pcm_l(pcm_l),.pcm_r(pcm_r),
        .sampler_overrun(sampler_overrun),.sampler_drop(sampler_drop),
        .startup_ready(audio_startup_ready),.audio_fault(audio_fault),
        .input_overrun(audio_input_overrun),.output_underrun(audio_output_underrun),.max_sample_cycles(audio_max_sample_cycles),
        .debug_req(sound_debug_req),.debug_ack(sound_debug_ack),.debug_addr(sound_debug_addr),
        .debug_wdata(sound_debug_wdata),.debug_be(sound_debug_be),.debug_write(sound_debug_write),
        .debug_fetch(sound_debug_fetch),.debug_fc(sound_debug_fc),.debug_irq(sound_debug_irq),
        .DDRAM_BUSY(AUDIO_DDRAM_BUSY),.DDRAM_BURSTCNT(AUDIO_DDRAM_BURSTCNT),.DDRAM_ADDR(AUDIO_DDRAM_ADDR),
        .DDRAM_DOUT(AUDIO_DDRAM_DOUT),.DDRAM_DOUT_READY(AUDIO_DDRAM_DOUT_READY),.DDRAM_RD(AUDIO_DDRAM_RD),
        .DDRAM_DIN(AUDIO_DDRAM_DIN),.DDRAM_BE(AUDIO_DDRAM_BE),.DDRAM_WE(AUDIO_DDRAM_WE));
    assign dry_l=pcm_l;assign dry_r=pcm_r;
    end else begin: diagnostic_sound
    gs_sound_devices #(.SYS_HZ(SYS_HZ)) sound_cpu(
        .clk(clk),.reset(reset),.pause(pause),
        .mem_req(s_req),.mem_addr(s_addr),.mem_wdata(s_wdata),.mem_be(s_be),.mem_write(s_write),.mem_ack(s_ack),.mem_rdata(s_rdata),
        .sm_req(sm_req),.sm_addr(sm_addr),.sm_line(sm_line),.sm_valid(sm_valid),.sm_busy(sm_busy),
        .running(sound_running),.dsp_halt(dsp_halt),.sample_valid(sample_valid),.dry_l(dry_l),.dry_r(dry_r),
        .sampler_overrun(sampler_overrun),.sampler_drop(sampler_drop),
        .debug_req(sound_debug_req),.debug_ack(sound_debug_ack),.debug_addr(sound_debug_addr),
        .debug_wdata(sound_debug_wdata),.debug_be(sound_debug_be),.debug_write(sound_debug_write),
        .debug_fetch(sound_debug_fetch),.debug_fc(sound_debug_fc),.debug_irq(sound_debug_irq)
    );
    assign pcm_valid=0;assign pcm_l=0;assign pcm_r=0;
    assign audio_startup_ready=1;assign audio_fault=0;
    assign audio_input_overrun=0;assign audio_output_underrun=0;assign audio_max_sample_cycles=0;
    assign AUDIO_DDRAM_RD=0;assign AUDIO_DDRAM_WE=0;assign AUDIO_DDRAM_BURSTCNT=0;
    assign AUDIO_DDRAM_ADDR=0;assign AUDIO_DDRAM_DIN=0;assign AUDIO_DDRAM_BE=0;
    end endgenerate
    gs_mailbox communication(
        .clk(clk),.reset(reset),
        .main_req(m_req && m_mail),.main_write(m_write),.main_byte_addr(m_addr[10:0]),
        .main_wdata(m_wdata),.main_be(m_be),.main_ack(m_mail_ack),.main_rdata(m_mail_data),
        .sound_req(s_req && s_mail),.sound_write(s_write),.sound_byte_addr(s_addr[11:1]),
        .sound_wdata(s_wdata),.sound_uds(s_be[1]),.sound_ack(s_mail_ack),.sound_rdata(s_mail_data)
    );
    assign m_ack=m_mail ? m_mail_ack : m_ext_ack;
    assign s_ack=s_mail ? s_mail_ack : s_ext_ack;
    assign m_rdata=m_mail ? m_mail_data : m_ext_data;
    assign s_rdata=s_mail ? s_mail_data : s_ext_data;
    gs_frontend_arb #(.SAMPLE_LINES(SAMPLE_LINES),.LINE_WRITES(LINE_WRITES)) memory(
        .clk(clk),.reset(reset),
        .main_req(m_req && !m_mail),.main_write(m_write),.main_addr(m_addr),
        .main_wdata(m_wdata),.main_be(m_be),.main_write_line(m_write_line),.main_wline(m_wline),.main_ack(m_ext_ack),.main_rdata(m_ext_data),
        .sound_req(s_req && !s_mail),.sound_write(s_write),.sound_addr(s_addr),
        .sound_wdata(s_wdata),.sound_be(s_be),.sound_ack(s_ext_ack),.sound_rdata(s_ext_data),
        .sample_req(sm_req),.sample_addr(sm_addr),.sample_busy(sm_busy),.sample_valid(sm_valid),.sample_line(sm_line),
        .mem_req(mem_req),.mem_write(mem_write),.mem_addr(mem_addr),.mem_wdata(mem_wdata),.mem_be(mem_be),.mem_write_line(mem_write_line),.mem_wline(mem_wline),
        .mem_ack(mem_ack),.mem_rdata(mem_rdata),.mem_rline(mem_rline)
    );
endmodule
