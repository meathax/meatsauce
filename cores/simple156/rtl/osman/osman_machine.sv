// SPDX-License-Identifier: GPL-3.0-or-later
// Shared release machine: HPS byte stream, controls, persistence, physical
// memory, live video and actual dual OKI. Verilator instantiates this module.
module osman_machine #(
    parameter integer SYS_HZ=48820224,
    parameter integer CPU_HZ=28000000
)(
    input wire clk, global_reset, game_reset,
    input wire reset_release,
    input wire [31:0] joystick_0, joystick_1,
    input wire [15:0] analog_0, analog_1,
    input wire [10:0] ps2_key,
    input wire menu_pause, pause_osd, menu_service, menu_test, osd_open, autosave, global_flip,
    input wire [1:0] sfx_level, music_level,
    input wire audio_filter,
    input wire ioctl_download, ioctl_upload, ioctl_wr,
    input wire [26:0] ioctl_addr,
    input wire [15:0] ioctl_index,
    input wire [7:0] ioctl_dout,
    output wire [7:0] ioctl_din,
    output wire ioctl_wait, ioctl_upload_req,
    output wire core_reset, image_ready, initialized, load_error, nvram_ready, paused,
    output wire [7:0] profile,
    output wire [3:0] load_error_reason,
    output wire [23:0] accepted_words,memory_writes,
    output wire scores_configured, scores_valid, scores_restored, scores_dirty, scores_format_error, scores_save_busy,
    output wire [15:0] inputs_0, inputs_1,
    output wire video_ce, video_de, video_hs, video_vs,
    output wire [8:0] video_x,
    output wire [7:0] video_y, red, green, blue,
    output wire [31:0] raster_frame, rendered_lines, missed_lines, max_line_cycles,
    output wire signed [15:0] audio,
    output wire audio_sample,
    input wire [25:0] state_addr,
    output wire [31:0] state_data,
    input wire [4:0] cpu_state_index,
    output wire [31:0] cpu_state_data,
    output wire cpu_at_boundary, irq_ack, vblank,
    output wire commit_valid, commit_we,
    output wire [25:0] commit_addr,
    output wire [3:0] commit_be,
    output wire [31:0] commit_data, write_count, unmapped_count,
    inout wire [15:0] sdram_dq,
`ifdef VERILATOR
    output wire [15:0] sdram_din,
`endif
    output wire [12:0] sdram_a,
    output wire [1:0] sdram_ba,
    output wire sdram_dqml,sdram_dqmh,sdram_nwe,sdram_ncas,sdram_nras,sdram_ncs,sdram_cke
);
    wire download_start, download_finish, download_valid, download_ready;
    wire [23:0] download_addr;
    wire [15:0] download_data;
    wire download_wait, download_error, loader_error, restore_error, queue_overflow;
    wire eeprom_restore_en,eeprom_restore_ready,eeprom_busy;
    wire [5:0] eeprom_restore_addr,eeprom_read_addr;
    wire [15:0] eeprom_restore_data,eeprom_read_data;
    wire input_pause,nvram_pause,score_pause;
    wire [7:0] nvram_din,score_din,score_rdata;
    wire nvram_upload_req,score_upload_req,score_req,score_we,score_ram_valid;
    wire [25:0] score_addr;
    wire [7:0] score_wdata;
    wire [7:0] sfx_status,music_status,oki_data;
    wire sfx_wr,music_wr,sfx_req,sfx_valid,music_req,music_valid;
    wire [17:0] sfx_addr;
    wire [20:0] music_addr;
    wire [7:0] sfx_data,music_data;
    wire [2:0] music_bank;
    assign load_error = download_error || loader_error || restore_error || queue_overflow;
    assign load_error_reason = {queue_overflow,restore_error,loader_error,download_error};
    // After a failed ROM load the image never becomes ready: do not hold the HPS
    // inside the NVRAM file (it could never send its end-of-file command).
    assign ioctl_wait = download_wait ||
        (ioctl_download && ioctl_index == 4 && !eeprom_restore_ready && !loader_error && !download_error);
    // One per-set file: legacy EEPROM prefix followed by the checked score tail.
    assign ioctl_din = ioctl_addr < 27'd128 ? nvram_din : score_din;
    assign ioctl_upload_req = (nvram_upload_req || score_upload_req) && !scores_save_busy;

    osman_download u_download (
        .clk(clk),.reset(global_reset),.ioctl_download(ioctl_download),.ioctl_wr(ioctl_wr),
        .ioctl_index(ioctl_index),.ioctl_addr(ioctl_addr),.ioctl_dout(ioctl_dout),.ioctl_wait(download_wait),
        .start(download_start),.finish(download_finish),.valid(download_valid),.addr(download_addr),.data(download_data),
        .ready(download_ready),.loader_abort(loader_error),.error(download_error)
    );
    osman_inputs u_inputs (
        .clk(clk),.reset(global_reset),.game_reset(game_reset),
        .joystick_0(joystick_0),.joystick_1(joystick_1),.analog_0(analog_0),.analog_1(analog_1),
        .ps2_key(ps2_key),.menu_pause(menu_pause),.menu_service(menu_service),.menu_test(menu_test),
        .inputs_0(inputs_0),.inputs_1(inputs_1),.pause_request(input_pause)
    );
    wire score_file_complete, score_file_accepted;
    osman_nvram u_nvram (
        .clk(clk),.reset(global_reset),.image_start(download_start),.seed_ready(image_ready),.game_reset(game_reset),
        .paused(paused),.eeprom_busy(eeprom_busy),.osd_open(osd_open),.autosave(autosave),
        .ioctl_download(ioctl_download),.ioctl_upload(ioctl_upload),
        .ioctl_wr(ioctl_wr),
        .profile(profile),.score_file_complete(score_file_complete),.score_file_accepted(score_file_accepted),
        .eeprom_restore_ready(eeprom_restore_ready),
        .ioctl_addr(ioctl_addr),.ioctl_index(ioctl_index),.ioctl_dout(ioctl_dout),.ioctl_din(nvram_din),
        .ioctl_upload_req(nvram_upload_req),.ready(nvram_ready),.restore_error(restore_error),.pause_request(nvram_pause),
        .eeprom_restore_en(eeprom_restore_en),.eeprom_restore_addr(eeprom_restore_addr),.eeprom_restore_data(eeprom_restore_data),
        .eeprom_read_addr(eeprom_read_addr),.eeprom_read_data(eeprom_read_data)
    );
    // The adapter owns per-profile qualification; include Charlie in its run gate.
    osman_scores u_scores (
        .clk(clk),.reset(global_reset),.image_start(download_start),.game_reset(game_reset),.profile(profile),.enabled(profile < 8'd4),
        .paused(paused),.osd_open(osd_open),.autosave(autosave),
        .ioctl_download(ioctl_download),.ioctl_upload(ioctl_upload),.ioctl_wr(ioctl_wr),
        .ioctl_addr(ioctl_addr),.ioctl_index(ioctl_index),.ioctl_dout(ioctl_dout),.ioctl_din(score_din),
        .ioctl_upload_req(score_upload_req),.pause_request(score_pause),.save_busy(scores_save_busy),.configured(scores_configured),
        .file_complete(score_file_complete),.file_accepted(score_file_accepted),
        .score_valid(scores_valid),.restored(scores_restored),.dirty(scores_dirty),.format_error(scores_format_error),.restore_pending(),
        .ram_req(score_req),.ram_we(score_we),.ram_addr(score_addr),.ram_wdata(score_wdata),
        .ram_valid(score_ram_valid),.ram_rdata(score_rdata)
    );
    osman_pause u_pause (
        .clk(clk),.reset(core_reset),
        .request(input_pause || nvram_pause || score_pause || (pause_osd && osd_open)),
        .cpu_at_boundary(cpu_at_boundary),.paused(paused)
    );
    osman_audio #(.SYSTEM_HZ(SYS_HZ)) u_audio (
        .clk(clk),.reset(core_reset),.pause(paused),.profile(profile),.sfx_wr(sfx_wr),.music_wr(music_wr),.command_data(oki_data),
        .music_bank(music_bank),.sfx_level(sfx_level),.music_level(music_level),.filter(audio_filter),
        .sfx_status(sfx_status),.music_status(music_status),.audio(audio),.sample(audio_sample),
        .sfx_req(sfx_req),.sfx_addr(sfx_addr),.sfx_valid(sfx_valid),.sfx_data(sfx_data),
        .music_req(music_req),.music_addr(music_addr),.music_valid(music_valid),.music_data(music_data)
    );
    osman_system #(.SYS_HZ(SYS_HZ),.CPU_HZ(CPU_HZ),.ENABLE_DEBUG_PORTS(0)) u_system (
        .clk(clk),.global_reset(global_reset),.game_reset(game_reset),.reset_release(reset_release),.pause(paused),.video_enable(1'b1),.global_flip(global_flip),
        .inputs_0(inputs_0),.inputs_1(inputs_1),.nvram_ready(nvram_ready && !download_error && !restore_error),
        .download_start(download_start),.download_finish(download_finish),.download_valid(download_valid),
        .download_addr(download_addr),.download_data(download_data),.download_ready(download_ready),
        .eeprom_restore_en(eeprom_restore_en),.eeprom_restore_addr(eeprom_restore_addr),.eeprom_restore_data(eeprom_restore_data),
        .eeprom_restore_ready(eeprom_restore_ready),.eeprom_state_addr(eeprom_read_addr),.eeprom_state_data(eeprom_read_data),.eeprom_busy(eeprom_busy),
        // Prefix commit/validation holds both CPU and score writes.
        .score_req(score_req && nvram_ready),.score_we(score_we),.score_paused(paused),.score_addr(score_addr),.score_wdata(score_wdata),
        .score_valid(score_ram_valid),.score_rdata(score_rdata),
        .core_reset(core_reset),.image_ready(image_ready),.loader_error(loader_error),.initialized(initialized),.profile(profile),
        .accepted_words(accepted_words),.memory_writes(memory_writes),.queue_overflow(queue_overflow),
        .tiles_req(1'b0),.tiles_addr(20'd0),.tiles_valid(),.tiles_data(),
        .sprites_req(1'b0),.sprites_addr(22'd0),.sprites_valid(),.sprites_data(),
        .video_req(1'b0),.video_addr(26'd0),.video_valid(),.video_data(),
        .sfx_req(sfx_req),.sfx_addr(sfx_addr),.sfx_valid(sfx_valid),.sfx_data(sfx_data),
        .music_req(music_req),.music_addr(music_addr),.music_valid(music_valid),.music_data(music_data),
        .oki_sfx_status(sfx_status),.oki_music_status(music_status),.oki_sfx_wr(sfx_wr),.oki_music_wr(music_wr),.oki_data(oki_data),.music_bank(music_bank),
        .video_ce(video_ce),.video_de(video_de),.video_hs(video_hs),.video_vs(video_vs),.video_x(video_x),.video_y(video_y),
        .red(red),.green(green),.blue(blue),.raster_frame(raster_frame),.rendered_lines(rendered_lines),.missed_lines(missed_lines),.max_line_cycles(max_line_cycles),
        .irq_line(),.vblank(vblank),.irq_ack(irq_ack),.cpu_at_boundary(cpu_at_boundary),
        .state_addr(state_addr),.state_data(state_data),.cpu_state_index(cpu_state_index),.cpu_state_data(cpu_state_data),
        .commit_valid(commit_valid),.commit_we(commit_we),.commit_addr(commit_addr),.commit_be(commit_be),.commit_data(commit_data),
        .write_count(write_count),.unmapped_count(unmapped_count),
        .sdram_dq(sdram_dq),
`ifdef VERILATOR
        .sdram_din(sdram_din),
`endif
        .sdram_a(sdram_a),.sdram_ba(sdram_ba),.sdram_dqml(sdram_dqml),.sdram_dqmh(sdram_dqmh),
        .sdram_nwe(sdram_nwe),.sdram_ncas(sdram_ncas),.sdram_nras(sdram_nras),.sdram_ncs(sdram_ncs),.sdram_cke(sdram_cke)
    );
endmodule
