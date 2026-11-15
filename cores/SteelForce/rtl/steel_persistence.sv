// SPDX-License-Identifier: GPL-3.0-or-later
// Production EEPROM and score transport; one firmware index-2 file.
module steel_persistence #(
    parameter [26:0] OSD_REOPEN_HOLD=27'd45_600_000
)(
    input wire clk,reset,new_image,mortalr,cpu_reset,paused,osd_status,sprite_busy,
    input wire autosave,save_button,
    input wire ioctl_download,ioctl_upload,ioctl_wr,ioctl_rd,
    input wire [15:0] ioctl_index,
    input wire [26:0] ioctl_addr,
    input wire [7:0] ioctl_din,
    output wire [7:0] ioctl_dout,
    output wire ioctl_wait,ioctl_upload_req,
    output wire cpu_hold,pause_request,initialized,dirty,error,hs_configured,
    output wire [5:0] nv_addr,
    output wire nv_we,
    output wire [15:0] nv_din,
    input wire [15:0] nv_dout,
    output wire hs_en,hs_write,
    output wire [23:0] hs_addr,
    output wire [7:0] hs_din,
    input wire [7:0] hs_dout
);
    wire nv_hold,nv_pause,nv_wait,nv_request,nv_error;
    wire score_pause,score_request;
    // One save per OSD opening. sys/osd.v rewrites osd_status on every OSD enable command, and Main
    // re-issues those while it changes OSD pages, browses files or shows message/info boxes, so the raw
    // signal drops and rises again while the menu stays open; every rise retriggered the EEPROM autosave
    // and the score dump. osd_open passes a rise only after the OSD has been closed for OSD_REOPEN_HOLD
    // clocks (1 s); quick re-openings are ignored. It still falls with the raw signal, so the score
    // donor's CPU pause is released as soon as the OSD closes. CPU pause itself uses the raw signal.
    reg osd_q=0,osd_open=0;
    reg [26:0] osd_closed=OSD_REOPEN_HOLD;
    wire osd_quiet=osd_closed==OSD_REOPEN_HOLD;
    always @(posedge clk)begin
        osd_q<=osd_status;
        if(osd_status)osd_closed<=0;
        else if(!osd_quiet)osd_closed<=osd_closed+1'b1;
        if(reset)begin osd_open<=0;osd_closed<=OSD_REOPEN_HOLD;end
        else if(!osd_status)osd_open<=0;
        else if(!osd_q && osd_quiet)osd_open<=1;
    end
    // One save per OSD opening, at the opening. MiSTer Main looks for a save request only when it
    // (re)draws the core's main menu (MENU_GENERIC_MAIN1 -> MENU_SAVE_CHECK in menu.cpp): right after
    // the OSD opens and again after every setting change or submenu exit, saving whenever hps_io latched
    // a new rising edge of ioctl_upload_req since the previous check. The request is therefore raised
    // while the OSD is closed (armed after OSD_REOPEN_HOLD closed clocks), so the check made as the OSD
    // opens finds it and saves at once; it is withdrawn when that upload starts and is not raised again
    // until the OSD has been closed for the hold, so menu navigation never sees another edge. The upload
    // captures fresh data itself: steel_nvram captures the EEPROM when an upload starts unprepared, and
    // byte 128 waits (score_hold) until the score extraction started by this opening has finished.
    // The manual Save NVRAM button re-arms it inside a session.
    reg save_armed=0,save_button_q=0,uploading_q=0;
    wire upload_start=ioctl_upload && ioctl_index==16'd2 && !uploading_q;
    always @(posedge clk)begin
        save_button_q<=save_button;uploading_q<=ioctl_upload && ioctl_index==16'd2;
        if(reset || new_image)begin save_armed<=0;save_button_q<=0;uploading_q<=0;end
        else if(upload_start)save_armed<=0;
        else if((autosave && osd_quiet && initialized && !cpu_hold && !error) || (save_button && !save_button_q))save_armed<=1;
    end
    assign ioctl_upload_req=save_armed && !ioctl_upload && !ioctl_download;
    // Score extraction is started once per opening (the donor triggers on a rising OSD edge; the
    // previous osd_open && !sprite_busy gate rose again every frame). byte 128 is held until that
    // extraction has paused and released the CPU and stayed quiet for 1 ms, or 0.3 s at most (the
    // donor ignores the edge while it is still restoring a loaded dump; its buffer is then current).
    reg donor_osd=0,hold_active=0,hold_saw_pause=0,osd_open_q=0;
    reg [23:0] hold_timer=0;
    reg [16:0] hold_quiet=0;
    always @(posedge clk)begin
        osd_open_q<=osd_open;
        if(reset || !osd_open)donor_osd<=0;
        else if(!sprite_busy)donor_osd<=1;
        if(reset || new_image || mortalr)begin hold_active<=0;hold_saw_pause<=0;hold_timer<=0;hold_quiet<=0;end
        else if(osd_open && !osd_open_q)begin hold_active<=1;hold_saw_pause<=0;hold_timer<=0;hold_quiet<=0;end
        else if(hold_active)begin
            hold_timer<=hold_timer+1'b1;
            if(score_pause)begin hold_saw_pause<=1;hold_quiet<=0;end
            else if(hold_saw_pause)hold_quiet<=hold_quiet+1'b1;
            if(hold_timer==24'd13_680_000 || (hold_saw_pause && hold_quiet==17'd45_600))hold_active<=0;
        end
    end
    wire [7:0] nv_bytes,score_bytes;
    wire load_nv_download,load_nv_wr,load_score_download,load_score_wr;
    wire load_wait,load_hold,load_error,load_commit,loaded_score_valid;
    wire [7:0] load_addr,load_data;
    wire uploading,score_uploading,upload_wait,upload_pause,complete_upload;
    reg score_valid=0,score_request_last=0;
    always @(posedge clk)begin
        score_request_last<=score_request;
        if(reset || new_image)begin score_valid<=0;score_request_last<=0;end
        else begin
            if(score_request && !score_request_last && !mortalr)score_valid<=1;
            if(load_commit)score_valid<=loaded_score_valid;
        end
    end
    steel_save_load load_file(.clk(clk),.reset(reset || new_image),.mortalr(mortalr),
        .ioctl_download(ioctl_download),.ioctl_wr(ioctl_wr),.ioctl_index(ioctl_index),
        .ioctl_addr(ioctl_addr),.ioctl_din(ioctl_din),.nv_wait(nv_wait),.nv_hold(nv_hold),
        .ioctl_wait(load_wait),.cpu_hold(load_hold),.load_error(load_error),.load_commit(load_commit),
        .score_valid(loaded_score_valid),.nv_download(load_nv_download),.nv_wr(load_nv_wr),
        .score_download(load_score_download),.score_wr(load_score_wr),.replay_addr(load_addr),.replay_data(load_data));
    steel_save_upload save_file(.clk(clk),.reset(reset || new_image),.mortalr(mortalr),.score_valid(score_valid),
        .ioctl_upload(ioctl_upload),.ioctl_download(ioctl_download),.ioctl_rd(ioctl_rd),.ioctl_index(ioctl_index),
        .ioctl_addr(ioctl_addr),.nv_bytes(nv_bytes),.score_bytes(score_bytes),.nv_wait(nv_wait),
        .nv_request(nv_request),.score_request(score_request),.uploading(uploading),
        .score_uploading(score_uploading),.pause_upload(upload_pause),.complete_upload(complete_upload),
        .score_hold(hold_active),.ioctl_wait(upload_wait),.ioctl_upload_req(),.ioctl_dout(ioctl_dout));
    steel_nvram nvram(.clk(clk),.reset(reset),.new_image(new_image),.osd_status(osd_open),
        .autosave(1'b0),.save_button(save_button),.ioctl_download(load_nv_download),.ioctl_upload(uploading),
        .ioctl_wr(load_nv_wr),.ioctl_rd(ioctl_rd && ioctl_addr<128),.upload_commit(complete_upload),
        .ioctl_index(load_nv_download ? 16'd2 : ioctl_index),
        .ioctl_addr(load_nv_download ? {19'b0,load_addr} : ioctl_addr),.ioctl_din(load_data),
        .ioctl_dout(nv_bytes),.ioctl_wait(nv_wait),.upload_req(nv_request),.cpu_hold(nv_hold),
        .pause_request(nv_pause),.initialized(initialized),.dirty(dirty),.load_error(nv_error),
        .nv_addr(nv_addr),.nv_we(nv_we),.nv_din(nv_din),.nv_dout(nv_dout));
    steel_hiscore scores(.clk(clk),.reset(cpu_reset || mortalr),.image_reset(reset || new_image || mortalr),
        .paused(paused),.osd_status(donor_osd && !mortalr),
        .ioctl_upload(score_uploading),
        .ioctl_download(load_score_download || ioctl_download && ioctl_index==3 && !mortalr),
        .ioctl_wr(load_score_download ? load_score_wr : ioctl_wr && ioctl_addr[26:25]==0),
        .ioctl_addr(load_score_download ? {17'b0,load_addr} : ioctl_index==3 ? ioctl_addr[24:0] : ioctl_addr[24:0]-25'd129),
        .ioctl_index(!load_score_download && ioctl_index==3 ? 8'd3 : 8'd4),
        .ioctl_din(load_score_download ? load_data : ioctl_din),.ioctl_dout(score_bytes),
        .ioctl_upload_req(score_request),.configured(hs_configured),.pause_cpu(score_pause),
        .hs_en(hs_en),.hs_write(hs_write),.hs_addr(hs_addr),.hs_din(hs_din),.hs_dout(hs_dout));
    assign cpu_hold=nv_hold || load_hold;
    assign pause_request=nv_pause || upload_pause || (!mortalr && score_pause);
    assign ioctl_wait=load_wait || upload_wait;
    assign error=nv_error || load_error;
endmodule
