// SPDX-License-Identifier: GPL-3.0-or-later
// Composed game logic. Clock enables, resets and memory services are supplied
// by the platform; sound/sample and main/video backends are separate clients.
module spinal_game (
    input logic clk,main_reset,video_reset,game_reset,sound_reset,
    input logic phi1,phi2,sound_ce,ym_ce,invalidate,sound_bus_request,
    input logic score_request,score_paused,score_write,input logic [13:0] score_address,input logic [7:0] score_data_in,
    output wire score_ready,output wire [7:0] score_data_out,
    input logic [6:0] player1,player2,
    input logic coin1,coin2,start1,start2,service_credit,test_switch,input logic [15:0] dip_switches,
    output wire main_video_request,output wire [24:0] main_video_address,output wire main_video_error,
    input logic main_video_ready,input logic [63:0] main_video_data,
    output wire sound_request,output wire [24:0] sound_address,
    input logic sound_ready,input logic [63:0] sound_data,output wire sound_program_error,
    output wire adpcma_request,output wire [24:0] adpcma_rom_address,
    input logic adpcma_ready,input logic [63:0] adpcma_rom_data,output wire adpcma_overflow,adpcma_late,
    output wire [19:0] adpcma_address,output wire [4:0] adpcma_bank,output wire adpcma_roe_n,
    output wire signed [15:0] sound_l,sound_r,output wire sound_sample,
    output wire ce_pixel,hs,vs,de,output wire [4:0] red,green,blue,
    output wire [8:0] pixel_x,pixel_y,output wire pixel_valid,output wire [31:0] underruns,
    output wire halted_n,output wire cpu_as_n,cpu_uds_n,cpu_lds_n,cpu_dtack_n,cpu_rom_wait,
    output wire sound_bus_idle,sound_bus_ack,cpu_path_idle,sound_path_idle,sample_path_idle
);
    wire [15:0] in0,in1,dips;
    wire video_urgent;
    spinal_inputs inputs(.player1(player1),.player2(player2),.coin1(coin1),.coin2(coin2),
        .start1(start1),.start2(start2),.service_credit(service_credit),.test_switch(test_switch),
        .dip_switches(dip_switches),.in0(in0),.in1(in1),.dips(dips));
    assign cpu_as_n=as_n;assign cpu_uds_n=uds_n;assign cpu_lds_n=lds_n;assign cpu_dtack_n=dtack_n;assign cpu_rom_wait=main_req;
    wire [23:1] cpu_a;wire [23:0] cpu_address={cpu_a,1'b0};wire as_n,uds_n,lds_n,rw_n,dtack_n,vpa_n;
    wire [2:0] fc;wire [15:0] cpu_out,cpu_in;wire ignored_e,ignored_vma,ignored_bg,ignored_reset;
    logic irq1_pending;wire irq_vblank_start;
    always_ff @(posedge clk) begin
        if(main_reset)irq1_pending<=0;
        else if(irq_vblank_start)irq1_pending<=1;
        else if(!as_n && fc==3'b111)irq1_pending<=0;
    end
    fx68k cpu(.clk(clk),.HALTn(1'b1),.extReset(main_reset),.pwrUp(main_reset),.enPhi1(phi1),.enPhi2(phi2),
        .eRWn(rw_n),.ASn(as_n),.LDSn(lds_n),.UDSn(uds_n),.E(ignored_e),.VMAn(ignored_vma),
        .FC0(fc[0]),.FC1(fc[1]),.FC2(fc[2]),.BGn(ignored_bg),.oRESETn(ignored_reset),.oHALTEDn(halted_n),
        .DTACKn(dtack_n),.VPAn(vpa_n),.BERRn(1'b1),.BRn(1'b1),.BGACKn(1'b1),
        .IPL0n(!irq1_pending),.IPL1n(1'b1),.IPL2n(1'b1),.iEdb(cpu_in),.oEdb(cpu_out),.eab(cpu_a));
    wire main_req,main_ready,video_req,video_ready;wire [17:1] main_addr;wire [15:0] main_word;
    wire [3:0] video_space;wire [21:0] video_addr;wire [63:0] video_word;
    wire [7:0] command;wire command_write;
    spinal_video_subsystem video(.clk(clk),.bus_reset(main_reset),.cold_reset(video_reset),.game_reset(game_reset),
        .render_urgent(video_urgent),
        .score_request(score_request),.score_paused(score_paused),.score_write(score_write),.score_address(score_address),.score_data_in(score_data_in),.score_ready(score_ready),.score_data_out(score_data_out),
        .cpu_address(cpu_address),.cpu_as_n(as_n),.cpu_uds_n(uds_n),.cpu_lds_n(lds_n),.cpu_read(rw_n),.cpu_fc(fc),
        .cpu_out(cpu_out),.cpu_in(cpu_in),.cpu_dtack_n(dtack_n),.cpu_vpa_n(vpa_n),
        .main_rom_request(main_req),.main_rom_address(main_addr),.main_rom_ready(main_ready),.main_rom_data(main_word),
        .in0(in0),.in1(in1),.dips(dips),.sound_command(command),.sound_write(command_write),
        .flip_screen(),.gfxbank(),.scrollx1(),.gga_index(),.gga_data(),.gga_write(),
        .video_rom_request(video_req),.video_rom_space(video_space),.video_rom_address(video_addr),
        .video_rom_ready(video_ready),.video_rom_data(video_word),.ce_pixel(ce_pixel),.hs(hs),.vs(vs),.de(de),
        .red(red),.green(green),.blue(blue),.pixel_x(pixel_x),.pixel_y(pixel_y),.pixel_valid(pixel_valid),.underruns(underruns),
        .raw_vblank_start(irq_vblank_start));
    wire cr,ca,vr,va,main_error,video_error,main_cache_idle,main_arbiter_idle;wire [24:0] caddr,vaddr;wire [63:0] cdata,vdata,main_reply;
    assign cpu_path_idle=main_cache_idle && main_arbiter_idle;
    spinal_rom_bridge #(.CACHE_ENABLE(1),.CACHE_LINES(64)) main_rom(.clk(clk),.reset(main_reset),.invalidate(invalidate),
        .request(main_req),.region(4'd0),.offset({4'b0,main_addr,1'b0}),.ready(main_ready),.error(main_error),.data(main_reply),
        .backend_request(cr),.backend_address(caddr),.backend_ready(ca),.backend_data(cdata),.idle(main_cache_idle));
    assign main_word=main_reply[15:0];
    spinal_rom_bridge #(.CACHE_ENABLE(1),.CACHE_LINES(16384),.SYNC_CACHE(1)) video_rom(.clk(clk),.reset(main_reset),.invalidate(invalidate),.request(video_req),
        .region(video_space),.offset(video_addr),.ready(video_ready),.error(video_error),.data(video_word),
        .backend_request(vr),.backend_address(vaddr),.backend_ready(va),.backend_data(vdata));
    assign main_video_error=(main_ready && main_error) || (video_ready && video_error);
    spinal_rom_arbiter #(.RESERVATION_ENABLE(1)) main_video_arbiter(.clk(clk),.reset(main_reset),.reserve0(video_urgent),.request0(vr),.request1(cr),
        .address0(vaddr),.address1(caddr),.ready0(va),.ready1(ca),.data0(vdata),.data1(cdata),
        .backend_request(main_video_request),.backend_address(main_video_address),.backend_ready(main_video_ready),.backend_data(main_video_data),.idle(main_arbiter_idle));
    wire [7:0] adpcma_data;
    spinal_adpcma_rom adpcm(.clk(clk),.reset(sound_reset),.ym_ce(ym_ce),.invalidate(invalidate),
        .roe_n(adpcma_roe_n),.sample_address(adpcma_address),.sample_bank(adpcma_bank),.sample_data(adpcma_data),
        .backend_request(adpcma_request),.backend_address(adpcma_rom_address),.backend_ready(adpcma_ready),
        .backend_data(adpcma_rom_data),.fault_overflow(adpcma_overflow),.fault_late(adpcma_late),.idle(sample_path_idle));
    spinal_sound_subsystem sound(.clk(clk),.reset(sound_reset),.cpu_ce(sound_ce),.ym_ce(ym_ce),.invalidate(invalidate),.bus_request(sound_bus_request),.bus_ack(sound_bus_ack),
        .command_write(command_write),.command_data(command),.backend_request(sound_request),.backend_address(sound_address),
        .backend_ready(sound_ready),.backend_data(sound_data),.program_error(sound_program_error),
        .adpcma_address(adpcma_address),.adpcma_bank(adpcma_bank),.adpcma_roe_n(adpcma_roe_n),.adpcma_data(adpcma_data),
        .sound_l(sound_l),.sound_r(sound_r),.sample(sound_sample),.cpu_bus_idle(sound_bus_idle),.program_idle(sound_path_idle));
endmodule
