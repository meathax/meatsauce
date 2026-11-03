// SPDX-License-Identifier: GPL-3.0-or-later
// Actual processors, Mermaid, Yamaha and renderer over the shared board/storage.
// Raster events are inputs: PCB timing is never invented by this composition.
module airbustr_game (
    input logic clk, reset, soft_reset, pause, rotate_180,
    input logic [7:0] system_inputs_n, player1_inputs_n, player2_inputs_n, dsw1, dsw2,
    input logic ioctl_download, ioctl_upload, ioctl_wr, ioctl_rd,
    input logic osd_open, autosave,
    output logic [15:0] ioctl_din,
    output logic ioctl_upload_req,
    output logic [7:0] ioctl_upload_index,
    output logic score_pause, score_reset_blocked, feature_error,
    input logic ddram_busy, ddram_data_ready,
    input logic [63:0] ddram_data,
    output logic ddram_rd, ddram_we,
    output logic [28:0] ddram_addr,
    output logic [7:0] ddram_burstcnt, ddram_be,
    output logic [63:0] ddram_writedata,
    input logic rotate_we, rotation_quiescent,
    input logic [28:0] rotate_addr,
    input logic [63:0] rotate_data,
    input logic [7:0] rotate_be,
    output logic rotation_pause, rotation_busy,
    input logic [15:0] ioctl_index,
    input logic [26:0] ioctl_addr,
    input logic [15:0] ioctl_dout,
    output logic ioctl_wait,
    input logic [2:0] selected_set,
    output logic [2:0] loaded_set,
    output logic ram_ready, game_ready, game_reset, memory_idle,
    output logic initialized, drained, transfer_active, rom_loaded,
    output logic [2:0] error_code,
    input logic main_event_64, main_event_240, sub_vblank,
    input logic eof, vis_start, prepare_line, line_commit,
    input logic [7:0] prepare_y, scan_x, scan_y,
    input logic scan_valid,
    output logic pixel_valid,
    output logic [23:0] rgb,
    output logic signed [15:0] audio,
    output logic audio_sample, audio_ready,
    output logic [47:0] cpu_addr,
    output logic [23:0] cpu_data,
    output logic [2:0] m1_n, mreq_n, iorq_n, rd_n, wr_n, rfsh_n, halt_n, wait_n,
    output logic [2:0] cpu_req_valid, cpu_req_ready, cpu_req_io, cpu_req_write,
    output logic [47:0] cpu_req_addr,
    output logic [23:0] cpu_req_data,
    output logic [2:0] cpu_rsp_valid,
    output logic [23:0] cpu_rsp_data,
    output logic main_irq, main_irq_ack, sub_irq, sub_nmi, sound_irq, sound_nmi,
    output logic [7:0] main_vector,
    output logic [3:0] coin_outputs,
    output logic line_ready, line_pending, tile_busy, object_busy, object_hold,
    output logic object_completed,
    output logic [31:0] object_pass_cycles,
    output logic [15:0] object_late_swaps,
    output logic [9:0] objects_done,
    output logic graphics_protocol_error,
    input logic [15:0] dq_in,
    output logic [15:0] dq_out,
    output logic dq_oe,
    output logic [12:0] sdram_addr,
    output logic [1:0] sdram_bank,
    output logic sdram_dqml, sdram_dqmh, sdram_ncs, sdram_nwe,
    output logic sdram_nras, sdram_ncas, sdram_cke, sdram_clk,
    output wire rotation_writes_drained
);
    logic cpu_cen, sub_irq_ack;
    logic [2:0] cpu_rom_quiesce,cpu_rom_pending,cpu_bus_idle,cpu_bus_loan_safe;
    logic object_rsp_last,storage_object_rsp_last,storage_object_req_full_tile;
    logic [7:0] sub_control, scroll_x0, scroll_y0, scroll_x1, scroll_y1, scroll_high_n;
    logic [8:0] object_addr;
    logic [63:0] object_data;
    logic [9:0] bg_tile_addr, fg_tile_addr, palette_addr;
    logic [7:0] bg_tile_code, bg_tile_attr, fg_tile_code, fg_tile_attr;
    logic [15:0] palette_data;
    logic snd_req_valid, snd_req_oki, snd_req_write, snd_req_addr, snd_rsp_valid, ym_irq_n;
    logic [7:0] snd_req_data, snd_rsp_data;
    logic [17:0] oki_rom_addr;
    logic oki_rom_req, oki_rom_ok;
    logic [7:0] oki_rom_data;
    // airbustrb has no CALC1 (main_map without main_prot_map).
    wire calc1_present = loaded_set != 3'd2;
    logic object_req_valid, object_req_ready, object_rsp_valid;
    logic tile_req_valid, tile_req_ready, tile_rsp_valid;
    logic [20:0] object_req_addr;
    logic [18:0] tile_req_addr;
    logic [63:0] object_rsp_data, tile_rsp_data;
    logic storage_object_req_valid, storage_object_req_ready, storage_object_rsp_valid;
    logic storage_tile_req_valid, storage_tile_req_ready, storage_tile_rsp_valid;
    logic [21:0] storage_object_req_addr, storage_tile_req_addr;
    logic [63:0] storage_object_rsp_data, storage_tile_rsp_data;
    logic [1:0] graphics_pending;
    logic [2:0] machine_req_valid, machine_req_ready, score_board_valid, score_board_io, score_board_write;
    logic [47:0] score_board_addr;
    logic [23:0] score_board_data, machine_rsp_data;
    logic [2:0] machine_rsp_valid, score_board_ready;
    logic machine_game_ready, machine_game_reset, score_reset_applied;
    logic score_selected, score_wait, score_fault;
    logic reader_wait, reader_download, reader_wr, loader_wait;
    logic [15:0] reader_index, reader_data;
    logic [26:0] reader_addr;
    logic reader_claim, reader_drained, image_valid, reader_error;
    logic owner_grant, owner_busy, owner_data_ready, owner_drained, owner_error;
    logic [63:0] owner_data;
    // count decrements on external DDR acceptance; exclude a new offered pulse.
    assign rotation_writes_drained=owner_drained && !rotate_we && !ddram_we;
    logic reader_rd;
    logic [28:0] reader_ddr_addr;
    logic [7:0] reader_burst;
    logic loader_download_last=0, image_generation_seen=0, delivery_admitted=0;
    logic reader_copy_done,reader_copy_active,reader_fast_selected,owner_rotation_pause;
    logic user_warm_requested=0,machine_warm_pending=0,machine_warm_reset=0;
    wire accepted_user_warm=score_reset_applied && (soft_reset || user_warm_requested);
    wire idle_storage=memory_idle && drained && graphics_pending==0;
    wire video_quiet=rotation_quiescent && (owner_drained || owner_grant);
    wire delivery_safe=!image_generation_seen || delivery_admitted;
    wire warm_video_safe=rotation_quiescent && owner_drained && idle_storage;
    wire warm_pause=accepted_user_warm || machine_warm_pending || machine_warm_reset ||
                    (user_warm_requested && !score_reset_blocked);
    wire effective_pause=pause || score_pause || reader_copy_active || warm_pause;
    assign rotation_pause=owner_rotation_pause || reader_copy_active || warm_pause;
    // Delay ROM delivery while score ownership is live. The normal FIFO
    // accepts only bounded already-issued words; pending normal fallback must retry scores before ROM begin.
    wire score_blocks_replacement=score_reset_blocked && image_generation_seen;
    wire machine_loader_download=reader_download && !score_blocks_replacement && delivery_safe;
    wire machine_loader_wr=reader_wr && !score_blocks_replacement && delivery_safe;
    wire generation_reset_request=soft_reset ||
        (machine_loader_download && !loader_download_last && image_generation_seen);
    always_ff @(posedge clk)begin
        if(reset)begin
            loader_download_last<=0;image_generation_seen<=0;delivery_admitted<=0;
            user_warm_requested<=0;machine_warm_pending<=0;machine_warm_reset<=0;
        end
        else begin
            loader_download_last<=machine_loader_download;
            if(reader_copy_done)image_generation_seen<=1;
            if(!reader_copy_active)delivery_admitted<=0;
            else if(video_quiet && idle_storage && !score_blocks_replacement)delivery_admitted<=1;
            if(soft_reset)user_warm_requested<=1;
            if(accepted_user_warm)user_warm_requested<=0;
            machine_warm_reset<=0;
            if((accepted_user_warm || machine_warm_pending) && warm_video_safe)begin
                machine_warm_reset<=1;machine_warm_pending<=0;
            end else if(accepted_user_warm)machine_warm_pending<=1;
        end
    end
    assign game_ready=machine_game_ready && image_valid;
    // Preserve EOF progress for a pending score before a new image owns RAM.
    assign game_reset=machine_game_reset || (!image_valid && !score_blocks_replacement && delivery_safe);
    assign ioctl_wait=score_selected ? score_wait :
                      (ioctl_index==16'd0 ?
                       ((reader_fast_selected && score_blocks_replacement) ? 1'b0 :
                        (reader_wait || (reader_copy_active && (score_blocks_replacement || !delivery_safe)))) : 1'b0);
    assign feature_error=score_fault || reader_error || owner_error;
    logic pandora_bus_hold;
    // The renderer snapshots logical object RAM. Stall new main-CPU object
    // accesses during that copy, while already accepted responses still drain.
    assign pandora_bus_hold = object_hold && !score_board_io[0] &&
                              score_board_addr[15:12] == 4'hc;
    assign machine_req_valid = {score_board_valid[2:1],score_board_valid[0] && !pandora_bus_hold};
    assign score_board_ready = {machine_req_ready[2:1],machine_req_ready[0] && !pandora_bus_hold};

    airbustr_score_service scores (
        .clk,.platform_reset(reset),.game_reset(generation_reset_request),.v_sync(eof),
        .osd_open(osd_open && game_ready),.autosave,.pause_active(effective_pause),
        .host_download(ioctl_download),.host_upload(ioctl_upload),.host_wr(ioctl_wr),.host_rd(ioctl_rd),
        .host_index(ioctl_index),.host_dout(ioctl_dout),.host_addr(ioctl_addr),.host_din(ioctl_din),
        .host_wait(score_wait),.host_selected(score_selected),.host_upload_req(ioctl_upload_req),
        .host_upload_index(ioctl_upload_index),.pause_request(score_pause),.reset_blocked(score_reset_blocked),
        .game_reset_applied(score_reset_applied),.configured(),.table_initialized(),.save_pending(),.upload_ready(),
        .upload_transfer_complete(),.transferred_bytes(),.drained(),.paused_quiet(),.owned(),
        .fault(score_fault),.protocol_error(),.error_code(),
        .memory_idle(memory_idle && cpu_rom_pending==0 && (&cpu_bus_loan_safe)),.storage_drained(drained && graphics_pending==0),
        .cpu_req_valid,.cpu_req_io,.cpu_req_write,.cpu_wait_n(wait_n),.cpu_req_addr,.cpu_req_data,
        .cpu_req_ready,.cpu_rsp_valid,.cpu_rsp_data,
        .board_req_valid(score_board_valid),.board_req_io(score_board_io),.board_req_write(score_board_write),
        .board_req_addr(score_board_addr),.board_req_data(score_board_data),
        .board_req_ready(score_board_ready),.board_rsp_valid(machine_rsp_valid),.board_rsp_data(machine_rsp_data)
    );
    airbustr_ddr_image_reader image_reader (
        .clk,.reset,.host_download(ioctl_download),.host_wr(ioctl_wr),.host_index(ioctl_index),
        .host_dout(ioctl_dout),.host_addr(ioctl_addr),.host_wait(reader_wait),
        .loader_download(reader_download),.loader_wr(reader_wr),.loader_index(reader_index),
        .loader_dout(reader_data),.loader_addr(reader_addr),
        .loader_wait(loader_wait || score_blocks_replacement || !delivery_safe),.loader_initialized(initialized),
        .loader_rom_loaded(rom_loaded),.loader_drained(drained),.loader_transfer_active(transfer_active),
        .loader_error(error_code),.load_claim(reader_claim),.rotation_pause(),.fast_selected(reader_fast_selected),
        .copy_active(reader_copy_active),.reader_drained,.image_valid,.copy_done(reader_copy_done),.protocol_error(reader_error),
        .error_code(),.copied_bytes(),.ddr_grant(owner_grant),.ddr_busy(owner_busy),
        .ddr_data_ready(owner_data_ready),.ddr_data(owner_data),.ddr_addr(reader_ddr_addr),
        .ddr_burstcnt(reader_burst),.ddr_rd(reader_rd)
    );
    airbustr_ddr_owner ddr_owner (
        .clk,.reset,.load_claim(reader_claim && !score_blocks_replacement),.rotation_quiescent,
        .load_grant(owner_grant),.rotation_pause(owner_rotation_pause),.drained(owner_drained),
        .load_rd(reader_rd),.load_addr(reader_ddr_addr),.load_burstcnt(reader_burst),
        .load_busy(owner_busy),.load_data_ready(owner_data_ready),.load_data(owner_data),
        .rotate_we,.rotate_addr,.rotate_data,.rotate_be,.rotate_busy(rotation_busy),
        .ram_busy(ddram_busy),.ram_data_ready(ddram_data_ready),.ram_data(ddram_data),
        .ram_rd(ddram_rd),.ram_we(ddram_we),.ram_addr(ddram_addr),.ram_burstcnt(ddram_burstcnt),
        .ram_be(ddram_be),.ram_writedata(ddram_writedata),.protocol_error(owner_error),
        .queued_writes(),.accepted_writes(),.accepted_reads(),.queue_level()
    );

    airbustr_cpus cpus (
        .cpu_rom_quiesce,.cpu_rom_pending,.cpu_bus_idle,.cpu_bus_loan_safe,
        .clk, .reset(game_reset || !audio_ready), .sub_reset(1'b0), .cpu_cen, .pause(effective_pause),
        .main_irq, .main_vector, .main_irq_ack, .sub_irq_ack, .sub_irq, .sub_nmi, .sound_irq, .sound_nmi,
        .cpu_req_valid, .cpu_req_ready, .cpu_req_io, .cpu_req_write, .cpu_req_addr,
        .cpu_req_data, .cpu_rsp_valid, .cpu_rsp_data,
        .cpu_addr, .cpu_data, .m1_n, .mreq_n, .iorq_n, .rd_n, .wr_n, .rfsh_n, .halt_n, .wait_n
    );
    airbustr_audio sound (
        .clk, .reset(game_reset), .mute(effective_pause),
        .req(snd_req_valid), .oki_sel(snd_req_oki), .write(snd_req_write), .addr(snd_req_addr), .din(snd_req_data),
        .ack(snd_rsp_valid), .dout(snd_rsp_data), .dsw1, .dsw2, .irq_n(ym_irq_n),
        .oki_rom_addr, .oki_rom_req, .oki_rom_ok, .oki_rom_data,
        .audio, .sample(audio_sample), .cen_3m(), .ready(audio_ready)
    );
    // Scroll/flip are sampled once per frame when the first visible line is
    // prepared. The sub CPU rewrites them from its vblank IRQ; MAME draws the
    // whole frame at vblank start from the values written during the previous
    // vblank, so a write landing mid-scan must not tear the lines after it.
    logic [7:0] f_x0, f_y0, f_x1, f_y1, f_hi;
    logic f_flip;
    wire frame_scroll_load = prepare_line && prepare_y == 8'd16;
    always_ff @(posedge clk) begin
        if(game_reset || frame_scroll_load) begin
            f_x0 <= scroll_x0; f_y0 <= scroll_y0; f_x1 <= scroll_x1; f_y1 <= scroll_y1;
            f_hi <= scroll_high_n; f_flip <= sub_control[4];
        end
    end
    airbustr_video video (
        .clk, .reset(game_reset), .eof, .vis_start, .prepare_line, .line_commit, .prepare_y,
        .scroll_x0(frame_scroll_load ? scroll_x0 : f_x0), .scroll_y0(frame_scroll_load ? scroll_y0 : f_y0),
        .scroll_x1(frame_scroll_load ? scroll_x1 : f_x1), .scroll_y1(frame_scroll_load ? scroll_y1 : f_y1),
        .scroll_high_n(frame_scroll_load ? scroll_high_n : f_hi),
        .game_flip(frame_scroll_load ? sub_control[4] : f_flip), .sprite_clear(sub_control[5]),
        .rotate_180, .scan_x, .scan_y, .scan_valid, .pixel_valid, .rgb,
        .line_ready, .line_pending, .tile_busy, .object_busy, .object_hold,
        .object_completed, .object_pass_cycles, .object_late_swaps, .objects_done,
        .object_addr, .object_data, .bg_tile_addr, .fg_tile_addr,
        .bg_tile_code, .bg_tile_attr, .fg_tile_code, .fg_tile_attr,
        .palette_addr, .palette_data,
        .object_req_valid, .object_req_ready, .object_req_addr, .object_rsp_valid, .object_rsp_last, .object_rsp_data,
        .tile_req_valid, .tile_req_ready, .tile_req_addr, .tile_rsp_valid, .tile_rsp_data
    );
    airbustr_video_adapter graphics_bridge (
        .clk, .reset(game_reset),
        .object_req_full_tile(1'b1),.storage_object_req_full_tile,
        .object_req_valid, .object_req_ready, .object_req_addr, .object_rsp_valid, .object_rsp_last, .object_rsp_data,
        .tile_req_valid, .tile_req_ready, .tile_req_addr, .tile_rsp_valid, .tile_rsp_data,
        .storage_object_req_valid, .storage_object_req_ready, .storage_object_req_addr,
        .storage_object_rsp_valid, .storage_object_rsp_last, .storage_object_rsp_data,
        .storage_tile_req_valid, .storage_tile_req_ready, .storage_tile_req_addr,
        .storage_tile_rsp_valid, .storage_tile_rsp_data,
        .pending(graphics_pending), .protocol_error(graphics_protocol_error)
    );
    airbustr_machine machine (
        .cpu_rom_quiesce,.cpu_rom_pending,
        .clk, .reset, .soft_reset(machine_warm_reset), .calc1_present, .wd_freeze(effective_pause), .wd_limit(28'd144000000), .wd_reset(), .ram_ready,
        .game_ready(machine_game_ready), .game_reset(machine_game_reset), .memory_idle, .cpu_cen,
        .cpu_req_valid(machine_req_valid), .cpu_req_ready(machine_req_ready),
        .cpu_req_io(score_board_io), .cpu_req_write(score_board_write), .cpu_req_addr(score_board_addr),
        .cpu_req_data(score_board_data), .cpu_rsp_valid(machine_rsp_valid), .cpu_rsp_data(machine_rsp_data),
        .sub_control, .scroll_x0, .scroll_y0, .scroll_x1, .scroll_y1, .scroll_high_n, .coin_outputs,
        .system_inputs_n, .player1_inputs_n, .player2_inputs_n,
        .main_event_64, .main_event_240, .main_irq_ack, .sub_irq_ack, .sub_vblank, .ym_irq(!ym_irq_n),
        .main_irq, .main_vector, .sub_irq, .sub_nmi, .sound_irq, .sound_nmi,
        .snd_req_valid, .snd_req_ready(audio_ready), .snd_req_oki, .snd_req_write, .snd_req_addr,
        .snd_req_data, .snd_rsp_valid, .snd_rsp_data,
        .oki_rom_addr, .oki_rom_req, .oki_rom_ok, .oki_rom_data,
        .object_addr, .object_data, .bg_tile_addr, .fg_tile_addr,
        .bg_tile_code, .bg_tile_attr, .fg_tile_code, .fg_tile_attr, .palette_addr, .palette_data,
        .ioctl_download(machine_loader_download), .ioctl_wr(machine_loader_wr), .ioctl_index(reader_index[7:0]),
        .ioctl_addr(reader_addr), .ioctl_dout(reader_data), .ioctl_wait(loader_wait),
        .selected_set, .loaded_set, .initialized, .drained, .transfer_active, .rom_loaded, .error_code,
        .object_req_valid(storage_object_req_valid), .object_req_ready(storage_object_req_ready),
        .object_req_addr(storage_object_req_addr), .object_rsp_valid(storage_object_rsp_valid),
        .object_req_full_tile(storage_object_req_full_tile),.object_rsp_last(storage_object_rsp_last),
        .object_rsp_data(storage_object_rsp_data),
        .tile_req_valid(storage_tile_req_valid), .tile_req_ready(storage_tile_req_ready),
        .tile_req_addr(storage_tile_req_addr), .tile_rsp_valid(storage_tile_rsp_valid),
        .tile_rsp_data(storage_tile_rsp_data),
        .dq_in, .dq_out, .dq_oe, .sdram_addr, .sdram_bank, .sdram_dqml, .sdram_dqmh, .sdram_ncs,
        .sdram_nwe, .sdram_nras, .sdram_ncas, .sdram_cke, .sdram_clk
    );
endmodule
