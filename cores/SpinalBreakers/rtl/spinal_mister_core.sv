// SPDX-License-Identifier: GPL-3.0-or-later
// MiSTer-facing logic boundary. Physical SDRAM controller, clock forwarding,
// HPS transport, external pause policy and video processing are platform responsibilities.
module spinal_mister_core #(parameter bit WITH_HISCORE=0,USE_IOCTL_DIPS=0,WITH_VIDEO_OUTPUT=0,WITH_CRT=0) (
    input logic clk,reset,user_reset,ioctl_download,ioctl_wr,pause_request,
    input logic score_request,score_write,input logic [23:0] score_address,input logic [7:0] score_data_in,
    output wire score_ready,output wire [7:0] score_data_out,
    input logic ioctl_upload,osd_status,hiscore_autosave,
    output wire hiscore_upload_req,hiscore_configured,output wire [7:0] hiscore_ioctl_data,
    input logic [15:0] ioctl_index,input logic [26:0] ioctl_addr,input logic [7:0] ioctl_data,
    output wire ioctl_wait,game_reset,download_error,fence_fault,
    input logic [31:0] joystick_0,joystick_1,input logic service_in,test_in,input logic [15:0] dip_switches,
    output wire pause_button,paused,
    output wire [2:0] physical_req,physical_write,output wire [74:0] physical_addr,output wire [47:0] physical_data,
    input logic [2:0] physical_ack,input logic [191:0] physical_reply,
    output wire ce_pixel,hs,vs,de,output wire [4:0] red,green,blue,output wire [8:0] pixel_x,pixel_y,
    input logic [2:0] video_effects,input logic forced_scandoubler,
    input logic crt_enable,input logic [2:0] crt_size,input logic signed [4:0] crt_hpos,crt_vpos,inout wire [21:0] gamma_bus,
    output wire video_clk,video_ce,video_hs,video_vs,video_de,output wire [7:0] video_r,video_g,video_b,output wire [1:0] video_scanlines,output wire video_hq2x_unavailable,
    output wire pixel_valid,output wire [31:0] underruns,output wire signed [15:0] sound_l,sound_r,output wire sound_sample,
    output wire main_video_error,sound_program_error,adpcma_overflow,adpcma_late,halted_n
);
    wire [6:0] p1,p2;wire c1,c2,s1,s2,service_credit,test_switch;
    spinal_mister_inputs inputs(.joystick_0(joystick_0),.joystick_1(joystick_1),.service_in(service_in),.test_in(test_in),
        .player1(p1),.player2(p2),.coin1(c1),.coin2(c2),.start1(s1),.start2(s2),.service_credit(service_credit),
        .test_switch(test_switch),.pause_button(pause_button));
    wire effective_pause,hs_pause,hs_request,hs_write,mem_score_ready;
    wire [15:0] effective_dips;
    generate if(USE_IOCTL_DIPS)begin:gen_ioctl_dips
        spinal_mister_dips dips(.clk(clk),.cold_reset(reset),.ioctl_download(ioctl_download),.ioctl_wr(ioctl_wr),
            .ioctl_index(ioctl_index),.ioctl_addr(ioctl_addr),.ioctl_data(ioctl_data),.dips(effective_dips));
    end else begin:gen_external_dips
        assign effective_dips=dip_switches;
    end endgenerate
    wire [23:0] hs_address;wire [7:0] hs_data,mem_score_data;
    assign score_ready=WITH_HISCORE ? 1'b0 : mem_score_ready;
    assign score_data_out=mem_score_data;
    generate if(WITH_HISCORE)begin:gen_hiscore
        spinal_hiscore_service service(.clk(clk),.reset(game_reset),.paused(paused),.autosave(hiscore_autosave),.osd_status(osd_status),.v_sync(vs),
            .ioctl_upload(ioctl_upload),.ioctl_download(ioctl_download),.ioctl_wr(ioctl_wr),.ioctl_index(ioctl_index),.ioctl_addr(ioctl_addr[24:0]),.ioctl_data(ioctl_data),
            .ioctl_upload_req(hiscore_upload_req),.ioctl_read_data(hiscore_ioctl_data),.configured(hiscore_configured),.pause_request(hs_pause),
            .score_request(hs_request),.score_write(hs_write),.score_address(hs_address),.score_data_out(hs_data),.score_data_in(mem_score_data),.score_ready(mem_score_ready));
    end else begin:gen_no_hiscore
        assign hs_pause=1'b0;assign hs_request=1'b0;assign hs_write=1'b0;assign hs_address=24'b0;assign hs_data=8'b0;
        assign hiscore_upload_req=1'b0;assign hiscore_configured=1'b0;assign hiscore_ioctl_data=8'b0;
    end endgenerate
    spinal_pause_policy pause_policy(.clk(clk),.reset(game_reset),.button(pause_button),.external_request(pause_request || hs_pause),.request(effective_pause));
    generate if(WITH_VIDEO_OUTPUT)begin:gen_video_output
        spinal_video_output #(.WITH_CRT(WITH_CRT)) output_path(.clk(clk),.reset(reset),.raw_ce(ce_pixel),.raw_hs(hs),.raw_vs(vs),.raw_x(pixel_x),.raw_y(pixel_y),
            .raw_r(red),.raw_g(green),.raw_b(blue),.effects(video_effects),.forced_scandoubler(forced_scandoubler),
            .crt_enable(crt_enable),.crt_size(crt_size),.crt_hpos(crt_hpos),.crt_vpos(crt_vpos),.gamma_bus(gamma_bus),
            .clk_video(video_clk),.ce_pixel(video_ce),.red(video_r),.green(video_g),.blue(video_b),.hs(video_hs),.vs(video_vs),.de(video_de),.scanlines(video_scanlines),.hq2x_unavailable(video_hq2x_unavailable));
    end else begin:gen_raw_video
        assign video_clk=clk;assign video_ce=ce_pixel;assign video_hs=hs;assign video_vs=vs;assign video_de=de;
        assign video_r={red,red[4:2]};assign video_g={green,green[4:2]};assign video_b={blue,blue[4:2]};assign video_scanlines=0;assign video_hq2x_unavailable=0;
    end endgenerate
    spinal_machine #(.INTERNAL_ENABLES(1)) machine(.clk(clk),.reset(reset),.user_reset(user_reset),.sound_hold(1'b0),
        .score_request(WITH_HISCORE ? hs_request : score_request),.score_write(WITH_HISCORE ? hs_write : score_write),
        .score_address(WITH_HISCORE ? hs_address : score_address),.score_data_in(WITH_HISCORE ? hs_data : score_data_in),.score_ready(mem_score_ready),.score_data_out(mem_score_data),
        .phi1(1'b0),.phi2(1'b0),.sound_ce(1'b0),.ym_ce(1'b0),.pause_request(effective_pause),.paused(paused),.ioctl_download(ioctl_download),.ioctl_wr(ioctl_wr),
        .ioctl_index(ioctl_index),.ioctl_addr(ioctl_addr),.ioctl_data(ioctl_data),.ioctl_wait(ioctl_wait),
        .game_reset(game_reset),.download_error(download_error),.fence_fault(fence_fault),
        .player1(p1),.player2(p2),.coin1(c1),.coin2(c2),.start1(s1),.start2(s2),.service_credit(service_credit),
        .test_switch(test_switch),.dip_switches(effective_dips),.physical_req(physical_req),.physical_write(physical_write),
        .physical_addr(physical_addr),.physical_data(physical_data),.physical_ack(physical_ack),.physical_reply(physical_reply),
        .ce_pixel(ce_pixel),.hs(hs),.vs(vs),.de(de),.red(red),.green(green),.blue(blue),.pixel_x(pixel_x),.pixel_y(pixel_y),
        .pixel_valid(pixel_valid),.underruns(underruns),.sound_l(sound_l),.sound_r(sound_r),.sound_sample(sound_sample),
        .main_video_error(main_video_error),.sound_program_error(sound_program_error),.adpcma_overflow(adpcma_overflow),
        .adpcma_late(adpcma_late),.halted_n(halted_n));
endmodule
