// SPDX-License-Identifier: GPL-3.0-or-later
// Candidate MiSTer HPS/game composition. SDRAM controller and pins remain an
// explicit external boundary until their physical timing is qualified.
module spinal_mister_system #(
    parameter CONF_STR="SpinalBreakers;;",
    parameter bit WITH_VIDEO_OUTPUT=1,WITH_ROTATION=1,WITH_MENU=0,WITH_CRT=0
) (
    input wire clk,reset,user_reset,pause_request,service_in,test_in,osd_status,hiscore_autosave,
    input wire new_vmode,input wire [15:0] status_menumask,input wire [2:0] video_effects,
    input wire [11:0] hdmi_width,hdmi_height,input wire [1:0] aspect_choice,scale_choice,
    input wire rotation_request,rotation_ccw,fb_vblank,ddram_busy,
    inout wire [45:0] HPS_BUS,
    output wire [127:0] status,output wire [1:0] buttons,output wire direct_video,
    output wire ioctl_wait,game_reset,download_error,fence_fault,pause_button,paused,hiscore_configured,
    output wire [2:0] physical_req,physical_write,output wire [74:0] physical_addr,output wire [47:0] physical_data,
    input wire [2:0] physical_ack,input wire [191:0] physical_reply,
    output wire ce_pixel,hs,vs,de,output wire [4:0] red,green,blue,output wire [8:0] pixel_x,pixel_y,
    output wire video_clk,video_ce,video_hs,video_vs,video_de,output wire [7:0] video_r,video_g,video_b,
    output wire [1:0] video_scanlines,output wire video_hq2x_unavailable,
    output wire [12:0] video_arx,video_ary,
    output wire video_rotated,fb_enable,output wire [4:0] fb_format,output wire [11:0] fb_width,fb_height,
    output wire [31:0] fb_base,output wire [13:0] fb_stride,
    output wire ddram_clk,ddram_we,ddram_rd,output wire [28:0] ddram_address,output wire [63:0] ddram_data,
    output wire [7:0] ddram_byteenable,ddram_burstcount,output wire rotation_overflow,
    output wire pixel_valid,output wire [31:0] underruns,output wire signed [15:0] sound_l,sound_r,output wire sound_sample,
    output wire main_video_error,sound_program_error,adpcma_overflow,adpcma_late,halted_n
);
    tri [21:0] gamma_bus;
    wire [31:0] joy0,joy1;wire forced_scandoubler;
    wire menu_reset,menu_pause,menu_service,menu_test,menu_autosave,menu_rotation,menu_ccw;
    wire [2:0] menu_effects;wire [1:0] menu_aspect,menu_scale;wire [15:0] menu_mask;
    spinal_mister_menu #(.CRT_SUPPORTED(WITH_CRT)) menu(.status(status),.direct_video(direct_video),.user_reset(menu_reset),
        .pause_request(menu_pause),.service_in(menu_service),.test_in(menu_test),.hiscore_autosave(menu_autosave),
        .video_effects(menu_effects),.aspect_choice(menu_aspect),.scale_choice(menu_scale),
        .rotation_request(menu_rotation),.rotation_ccw(menu_ccw),.status_menumask(menu_mask));
    wire download,upload,wr,rd,upload_req;wire [15:0] index;wire [26:0] address;wire [7:0] data,upload_data;
    spinal_hps_io #(.CONF_STR(CONF_STR)) transport(.clk(clk),.HPS_BUS(HPS_BUS),.gamma_bus(gamma_bus),
        .status(status),.joystick_0(joy0),.joystick_1(joy1),.buttons(buttons),.forced_scandoubler(forced_scandoubler),
        .direct_video(direct_video),.video_rotated(video_rotated),.new_vmode(new_vmode),.status_menumask(WITH_MENU ? menu_mask : status_menumask),
        .ioctl_download(download),.ioctl_upload(upload),.ioctl_wr(wr),.ioctl_rd(rd),.ioctl_index(index),.ioctl_addr(address),
        .ioctl_data(data),.ioctl_wait(ioctl_wait),.hiscore_upload_req(upload_req),.hiscore_ioctl_data(upload_data));
    spinal_mister_core #(.WITH_HISCORE(1),.USE_IOCTL_DIPS(1),.WITH_VIDEO_OUTPUT(WITH_VIDEO_OUTPUT),.WITH_CRT(WITH_CRT)) core(
        .clk(clk),.reset(reset),.user_reset(user_reset | (WITH_MENU && menu_reset)),.pause_request(pause_request | (WITH_MENU && menu_pause)),
        .score_request(1'b0),.score_write(1'b0),.score_address(24'b0),.score_data_in(8'b0),.score_ready(),.score_data_out(),
        .ioctl_download(download),.ioctl_upload(upload),.ioctl_wr(wr),.ioctl_index(index),.ioctl_addr(address),.ioctl_data(data),
        .ioctl_wait(ioctl_wait),.osd_status(osd_status),.hiscore_autosave(WITH_MENU ? menu_autosave : hiscore_autosave),
        .hiscore_upload_req(upload_req),.hiscore_configured(hiscore_configured),.hiscore_ioctl_data(upload_data),
        .game_reset(game_reset),.download_error(download_error),.fence_fault(fence_fault),
        .joystick_0(joy0),.joystick_1(joy1),.service_in(service_in | (WITH_MENU && menu_service)),.test_in(test_in | (WITH_MENU && menu_test)),.dip_switches(16'hffff),
        .pause_button(pause_button),.paused(paused),.physical_req(physical_req),.physical_write(physical_write),
        .physical_addr(physical_addr),.physical_data(physical_data),.physical_ack(physical_ack),.physical_reply(physical_reply),
        .ce_pixel(ce_pixel),.hs(hs),.vs(vs),.de(de),.red(red),.green(green),.blue(blue),.pixel_x(pixel_x),.pixel_y(pixel_y),
        .video_effects(WITH_MENU ? menu_effects : video_effects),.forced_scandoubler(forced_scandoubler),
        .crt_enable(status[54]),.crt_size(status[57:55]),.crt_hpos(status[62:58]),.crt_vpos(status[67:63]),.gamma_bus(gamma_bus),
        .video_clk(video_clk),.video_ce(video_ce),.video_hs(video_hs),.video_vs(video_vs),.video_de(video_de),
        .video_r(video_r),.video_g(video_g),.video_b(video_b),.video_scanlines(video_scanlines),.video_hq2x_unavailable(video_hq2x_unavailable),
        .pixel_valid(pixel_valid),.underruns(underruns),.sound_l(sound_l),.sound_r(sound_r),.sound_sample(sound_sample),
        .main_video_error(main_video_error),.sound_program_error(sound_program_error),.adpcma_overflow(adpcma_overflow),
        .adpcma_late(adpcma_late),.halted_n(halted_n));
    generate if(WITH_ROTATION)begin:gen_rotation
        spinal_video_rotation rotation(.clk(clk),.reset(reset),.request(WITH_MENU ? menu_rotation : rotation_request),.ccw(WITH_MENU ? menu_ccw : rotation_ccw),.direct_video(direct_video),
            .ce(video_ce),.de(video_de),.vs(video_vs),.red(video_r),.green(video_g),.blue(video_b),
            .fb_vblank(fb_vblank),.ddram_busy(ddram_busy),.fb_enable(fb_enable),.fb_format(fb_format),
            .fb_width(fb_width),.fb_height(fb_height),.fb_base(fb_base),.fb_stride(fb_stride),
            .ddram_clk(ddram_clk),.ddram_we(ddram_we),.ddram_rd(ddram_rd),.ddram_address(ddram_address),
            .ddram_data(ddram_data),.ddram_byteenable(ddram_byteenable),.ddram_burstcount(ddram_burstcount),
            .overflow(rotation_overflow),.completed_frames(),.dropped_frames());
    end else begin:gen_no_rotation
        assign fb_enable=0;assign fb_format=0;assign fb_width=0;assign fb_height=0;assign fb_base=0;assign fb_stride=0;
        assign ddram_clk=clk;assign ddram_we=0;assign ddram_rd=0;assign ddram_address=0;assign ddram_data=0;
        assign ddram_byteenable=0;assign ddram_burstcount=0;assign rotation_overflow=0;
    end endgenerate
    assign video_rotated=fb_enable;
    spinal_video_scaler scaler(.clk(clk),.reset(reset),.direct_video(direct_video),.fb_enable(fb_enable),
        .fb_width(fb_width),.fb_height(fb_height),.hdmi_width(hdmi_width),.hdmi_height(hdmi_height),
        .aspect_choice(WITH_MENU ? menu_aspect : aspect_choice),.scale_choice(WITH_MENU ? menu_scale : scale_choice),.video_arx(video_arx),.video_ary(video_ary));
endmodule
