// SPDX-License-Identifier: GPL-3.0-or-later
// Core logic and download memory boundary. Clock enables and physical SDRAM
// controller initialization are provided by the platform and require their
// own timing qualification.
module spinal_machine #(parameter bit INTERNAL_ENABLES=0) (
    input logic clk,reset,user_reset,sound_hold,phi1,phi2,sound_ce,ym_ce,pause_request,
    input logic score_request,score_write,input logic [23:0] score_address,input logic [7:0] score_data_in,
    output wire score_ready,output wire [7:0] score_data_out,
    input logic ioctl_download,ioctl_wr,input logic [15:0] ioctl_index,input logic [26:0] ioctl_addr,input logic [7:0] ioctl_data,
    output wire ioctl_wait,game_reset,download_error,fence_fault,paused,
    input logic [6:0] player1,player2,input logic coin1,coin2,start1,start2,service_credit,test_switch,input logic [15:0] dip_switches,
    output wire [2:0] physical_req,physical_write,output wire [74:0] physical_addr,output wire [47:0] physical_data,
    input logic [2:0] physical_ack,input logic [191:0] physical_reply,
    output wire ce_pixel,hs,vs,de,output wire [4:0] red,green,blue,output wire [8:0] pixel_x,pixel_y,
    output wire pixel_valid,output wire [31:0] underruns,output wire signed [15:0] sound_l,sound_r,output wire sound_sample,
    output wire main_video_error,sound_program_error,adpcma_overflow,adpcma_late,halted_n
);
    wire memory_reset,invalidate,mreq,sreq,areq,mready,sready,aready;
    wire [24:0] ma,sa,aa;wire [63:0] md,sd,ad;
    assign game_reset=memory_reset || user_reset;
    wire bus_as_n,bus_uds_n,bus_lds_n,bus_dtack_n,bus_rom_wait;wire use_phi1,use_phi2,use_sound_ce,use_ym_ce,use_sound_hold;
    wire freeze_cpu,freeze_sound,sound_bus_request,sound_bus_ack;
    wire cpu_path_idle,sound_path_idle,sample_path_idle,port0_idle,port1_idle,port2_idle;
    logic cpu_drained,sound_drained,sample_drained;
    always_ff @(posedge clk) begin
        if(game_reset || !pause_request)begin cpu_drained<=0;sound_drained<=0;sample_drained<=0;end
        else begin
            if(freeze_cpu && cpu_path_idle && port0_idle)cpu_drained<=1;
            if(freeze_sound && sound_path_idle && port1_idle)sound_drained<=1;
            if(freeze_sound && sample_path_idle && port2_idle)sample_drained<=1;
        end
    end
    generate if(INTERNAL_ENABLES)begin:gen_internal
        spinal_pause_control pause(.clk(clk),.reset(game_reset),.request(pause_request),.cpu_idle(bus_as_n),.sound_bus_ack(sound_bus_ack),
            .cpu_drained(cpu_drained),.sound_drained(sound_drained),.sample_drained(sample_drained),
            .sound_bus_request(sound_bus_request),.freeze_cpu(freeze_cpu),.freeze_sound(freeze_sound),.paused(paused));
        spinal_enable_service enables(.clk(clk),.platform_reset(reset),.game_reset(game_reset),.freeze_cpu(freeze_cpu),.freeze_sound(freeze_sound),.as_n(bus_as_n),.uds_n(bus_uds_n),.lds_n(bus_lds_n),.dtack_n(bus_dtack_n),.rom_wait(bus_rom_wait),.phi1(use_phi1),.phi2(use_phi2),.sound_ce(use_sound_ce),.ym_ce(use_ym_ce),.sound_hold(use_sound_hold),.cpu_debt_overflow(),.cpu_debt());
    end else begin:gen_external
        assign freeze_cpu=1'b0;assign freeze_sound=1'b0;assign sound_bus_request=1'b0;assign paused=1'b0;
        assign use_phi1=phi1;assign use_phi2=phi2;assign use_sound_ce=sound_ce;assign use_ym_ce=ym_ce;assign use_sound_hold=sound_hold;
    end endgenerate
    spinal_platform_memory memory(.clk(clk),.reset(reset),.ioctl_download(ioctl_download),.ioctl_wr(ioctl_wr),
        .ioctl_index(ioctl_index),.ioctl_addr(ioctl_addr),.ioctl_data(ioctl_data),.ioctl_wait(ioctl_wait),
        .game_reset(memory_reset),.invalidate(invalidate),.download_error(download_error),.fence_fault(fence_fault),.image_acknowledged(),.port0_idle(port0_idle),.port1_idle(port1_idle),.port2_idle(port2_idle),
        .main_req(mreq && !user_reset),.sound_req(sreq && !user_reset),.sample_req(areq && !user_reset),
        .main_addr(ma),.sound_addr(sa),.sample_addr(aa),.main_ready(mready),.sound_ready(sready),.sample_ready(aready),
        .main_data(md),.sound_data(sd),.sample_data(ad),.physical_req(physical_req),.physical_write(physical_write),
        .physical_addr(physical_addr),.physical_data(physical_data),.physical_ack(physical_ack),.physical_reply(physical_reply));
    spinal_game game(.clk(clk),.main_reset(game_reset),.video_reset(reset),.game_reset(game_reset),.sound_reset(game_reset || use_sound_hold),
        .score_request(score_request && score_address>=24'hff8000 && score_address<24'hffc000),.score_paused(paused),.score_write(score_write),.score_address(score_address[13:0]),.score_data_in(score_data_in),.score_ready(score_ready),.score_data_out(score_data_out),
        .phi1(use_phi1),.phi2(use_phi2),.sound_ce(use_sound_ce),.ym_ce(use_ym_ce),.invalidate(invalidate),.sound_bus_request(sound_bus_request),
        .player1(player1),.player2(player2),.coin1(coin1),.coin2(coin2),.start1(start1),.start2(start2),
        .service_credit(service_credit),.test_switch(test_switch),.dip_switches(dip_switches),
        .main_video_request(mreq),.main_video_address(ma),.main_video_error(main_video_error),.main_video_ready(mready),.main_video_data(md),
        .sound_request(sreq),.sound_address(sa),.sound_ready(sready),.sound_data(sd),.sound_program_error(sound_program_error),
        .adpcma_request(areq),.adpcma_rom_address(aa),.adpcma_ready(aready),.adpcma_rom_data(ad),.adpcma_overflow(adpcma_overflow),
        .adpcma_late(adpcma_late),.adpcma_address(),.adpcma_bank(),.adpcma_roe_n(),.sound_l(sound_l),.sound_r(sound_r),.sound_sample(sound_sample),
        .ce_pixel(ce_pixel),.hs(hs),.vs(vs),.de(de),.red(red),.green(green),.blue(blue),.pixel_x(pixel_x),.pixel_y(pixel_y),
        .pixel_valid(pixel_valid),.underruns(underruns),.halted_n(halted_n),.cpu_as_n(bus_as_n),.cpu_uds_n(bus_uds_n),.cpu_lds_n(bus_lds_n),.cpu_dtack_n(bus_dtack_n),.cpu_rom_wait(bus_rom_wait),.sound_bus_ack(sound_bus_ack),.cpu_path_idle(cpu_path_idle),.sound_path_idle(sound_path_idle),.sample_path_idle(sample_path_idle));
endmodule
