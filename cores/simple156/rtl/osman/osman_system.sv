// SPDX-License-Identifier: GPL-3.0-or-later
// Original-ROM loader, physical SDRAM transport and the actual shared board.
module osman_system #(
    parameter integer SYS_HZ=48820224,
    parameter integer CPU_HZ=28000000,
    parameter integer REFRESH_PERIOD_CLKS=SYS_HZ/15000,
    parameter integer ENABLE_DEBUG_PORTS=0
)(
    input wire clk, global_reset, game_reset, pause,
    // Raster-aligned reset release (osman_boot_video release_point). A held
    // reset ends only on a clock where it is high; tie high for an immediate release.
    input wire reset_release,
    input wire video_enable, global_flip,
    output wire irq_line, vblank,
    output wire [31:0] raster_frame,
    output wire video_ce, video_de, video_hs, video_vs,
    output wire [8:0] video_x,
    output wire [7:0] video_y, red, green, blue,
    output wire [31:0] rendered_lines, missed_lines, max_line_cycles,
    input wire [15:0] inputs_0, inputs_1,
    input wire download_start, download_finish, download_valid,
    input wire [23:0] download_addr,
    input wire [15:0] download_data,
    output wire download_ready,
    input wire nvram_ready,
    input wire eeprom_restore_en,
    input wire [5:0] eeprom_restore_addr,
    input wire [15:0] eeprom_restore_data,
    output wire eeprom_restore_ready,
    output wire core_reset, image_ready, loader_error, initialized,
    output wire [7:0] profile,
    output wire [23:0] accepted_words, memory_writes,
    input wire tiles_req,
    input wire [19:0] tiles_addr,
    output wire tiles_valid,
    output wire [15:0] tiles_data,
    input wire sprites_req,
    input wire [21:0] sprites_addr,
    output wire sprites_valid,
    output wire [15:0] sprites_data,
    input wire sfx_req,
    input wire [17:0] sfx_addr,
    output wire sfx_valid,
    output wire [7:0] sfx_data,
    input wire music_req,
    input wire [20:0] music_addr,
    output wire music_valid,
    output wire [7:0] music_data,
    output wire queue_overflow,
    output wire [31:0] cpu_cache_hits,cpu_cache_misses,tile_cache_hits,tile_cache_misses,sprite_cache_hits,sprite_cache_misses,
    input wire [7:0] oki_sfx_status, oki_music_status,
    output wire oki_sfx_wr, oki_music_wr,
    output wire [7:0] oki_data,
    output wire [2:0] music_bank,
    input wire [25:0] state_addr,
    output wire [31:0] state_data,
    input wire score_req,score_we,score_paused,
    input wire [25:0] score_addr,
    input wire [7:0] score_wdata,
    output wire score_valid,
    output wire [7:0] score_rdata,
    input wire video_req,
    input wire [25:0] video_addr,
    output wire video_valid,
    output wire [31:0] video_data,
    input wire [5:0] eeprom_state_addr,
    output wire [15:0] eeprom_state_data,
    output wire eeprom_busy,
    input wire [4:0] cpu_state_index,
    output wire [31:0] cpu_state_data,
    output wire cpu_at_boundary, irq_ack,
    output wire commit_valid, commit_we,
    output wire [25:0] commit_addr,
    output wire [3:0] commit_be,
    output wire [31:0] commit_data,
    output wire [31:0] write_count, unmapped_count,
    inout wire [15:0] sdram_dq,
`ifdef VERILATOR
    output wire [15:0] sdram_din,
`endif
    output wire [12:0] sdram_a,
    output wire [1:0] sdram_ba,
    output wire sdram_dqml,sdram_dqmh,sdram_nwe,sdram_ncas,sdram_nras,sdram_ncs,sdram_cke
);
    wire loader_valid,loader_ready,sdram_verify_failed;
    wire [23:0] loader_addr;
    wire [15:0] loader_data;
    wire [1:0] loader_be;
    wire eeprom_load_en;
    wire [5:0] eeprom_load_addr;
    wire [15:0] eeprom_load_data;
    wire loader_exclusive = !image_ready || download_start;
    wire reset_request = global_reset || game_reset || !image_ready || !initialized || !nvram_ready || loader_error || download_start;
    // The game raster restarts at x0/line248 when released. Releasing at an
    // arbitrary standby-raster position emitted one short frame, which changed
    // the measured DE line count; Main_MiSTer then re-ran its video mode set
    // (vsync_adjust) and the HDMI picture warped during the opening scene.
    // Hold the reset until the standby raster reaches the matching position.
    reg reset_hold = 1'b1;
    always @(posedge clk)
        if (reset_request) reset_hold <= 1'b1;
        else if (reset_release) reset_hold <= 1'b0;
    assign core_reset = reset_request || (reset_hold && !reset_release);
    // Seed loading always wins. HPS restore is permitted only after the image
    // has drained, while its NVRAM barrier still keeps the CPU in reset.
    assign eeprom_restore_ready = !global_reset && image_ready && core_reset && !download_start && !eeprom_load_en;
    wire restore_accept = eeprom_restore_en && eeprom_restore_ready;
    wire core_eeprom_load = eeprom_load_en || restore_accept;
    wire [5:0] core_eeprom_addr = eeprom_load_en ? eeprom_load_addr : eeprom_restore_addr;
    wire [15:0] core_eeprom_data = eeprom_load_en ? eeprom_load_data : eeprom_restore_data;
    wire raster_ce, raster_line_start, raster_de, raster_hs, raster_vs;
    wire [8:0] raster_x;
    wire [7:0] raster_y;
    osman_raster #(.SYS_HZ(SYS_HZ)) u_raster (
        .clk(clk),.reset(core_reset),.pause(1'b0),.ce_pixel(raster_ce),.x(raster_x),.y(raster_y),
        .display_enable(raster_de),.hblank(),.vblank(vblank),.hs(raster_hs),.vs(raster_vs),
        .line_start(raster_line_start),.frame_start(),.irq_event(),.irq_level(irq_line),.frame_count(raster_frame)
    );
    // MAME's Simple 156 vblank callback asserts HOLD_LINE on entry and
    // explicitly clears the source on exit. A one-clock event loses the level.
    wire render_board_req, render_board_valid;
    wire [25:0] render_board_addr;
    wire [31:0] render_board_data;
    wire render_tile_req, render_sprite_req, memory_tile_valid, memory_sprite_valid;
    wire [20:0] render_tile_addr;
    wire [22:0] render_sprite_addr;
    wire [15:0] memory_tile_data, memory_sprite_data;
    wire [63:0] memory_tile_data64, memory_sprite_data64;
    wire debug_route = ENABLE_DEBUG_PORTS != 0 && !video_enable;
    wire core_video_req = video_enable ? render_board_req : (debug_route && video_req);
    wire [25:0] profile_board_addr = profile == 8'd2
        ? render_board_addr - 26'h080000 : render_board_addr;
    wire [25:0] core_video_addr = video_enable ? profile_board_addr : video_addr;
    assign video_valid = debug_route && render_board_valid;
    assign video_data = render_board_data;
    assign tiles_valid = debug_route && memory_tile_valid;
    assign sprites_valid = debug_route && memory_sprite_valid;
    assign tiles_data = memory_tile_data;
    assign sprites_data = memory_sprite_data;
    wire render_urgent;
    osman_video u_video (
        .clk(clk),.reset(core_reset || !video_enable),.pause(1'b0),.profile(profile),.ce_pixel(raster_ce),.line_start(raster_line_start),
        .x(raster_x),.y(raster_y),.hs(raster_hs),.vs(raster_vs),.display_enable(raster_de),
        .frame_parity(raster_frame[0]),.global_flip(global_flip),
        .commit_valid(commit_valid),.commit_we(commit_we),.commit_addr(commit_addr),.commit_be(commit_be),.commit_data(commit_data),
        .board_req(render_board_req),.board_addr(render_board_addr),.board_valid(render_board_valid),.board_data(render_board_data),
        .tile_req(render_tile_req),.tile_byte_addr(render_tile_addr),.tile_valid(memory_tile_valid),.tile_data(memory_tile_data64),
        .sprite_req(render_sprite_req),.sprite_byte_addr(render_sprite_addr),.sprite_valid(memory_sprite_valid),.sprite_data(memory_sprite_data64),
        .video_ce(video_ce),.video_de(video_de),.video_hs(video_hs),.video_vs(video_vs),.video_x(video_x),.video_y(video_y),
        .red(red),.green(green),.blue(blue),.render_done(),.render_urgent(render_urgent),.render_y(),
        .rendered_lines(rendered_lines),.missed_lines(missed_lines),.max_line_cycles(max_line_cycles),.aborted_lines(),.late_lines()
    );
    osman_loader u_loader (
        .clk(clk),.reset(global_reset),.start(download_start),.finish(download_finish),
        .in_valid(download_valid),.in_ready(download_ready),.in_addr(download_addr),.in_data(download_data),
        .mem_valid(loader_valid),.mem_ready(loader_ready),.mem_error(sdram_verify_failed),.mem_addr(loader_addr),.mem_data(loader_data),.mem_be(loader_be),
        .eeprom_load_en(eeprom_load_en),.eeprom_load_addr(eeprom_load_addr),.eeprom_load_data(eeprom_load_data),
        .profile(profile),.image_ready(image_ready),.error(loader_error),.accepted_words(accepted_words),.memory_writes(memory_writes)
    );
    wire cpu_rom_req,cpu_rom_ready;
    wire [16:0] cpu_rom_addr;
    wire [31:0] cpu_rom_data;
    wire dram_req,dram_we,dram_ready;
    wire [24:0] dram_addr;
    wire [15:0] dram_wdata;
    wire [63:0] dram_rdata64;
    wire [1:0] dram_be;
    osman_memory u_memory (
        .clk(clk),.reset(global_reset),.profile(profile),.loader_exclusive(loader_exclusive),.graphics_urgent(render_urgent),
        .loader_valid(loader_valid),.loader_ready(loader_ready),.loader_addr(loader_addr),.loader_data(loader_data),.loader_be(loader_be),
        .cpu_req(cpu_rom_req),.cpu_word_addr(cpu_rom_addr),.cpu_ready(cpu_rom_ready),.cpu_data(cpu_rom_data),
        .tiles_req(video_enable ? render_tile_req : (debug_route && tiles_req)),
        .tiles_addr(video_enable ? render_tile_addr[20:1] : tiles_addr),.tiles_valid(memory_tile_valid),.tiles_data(memory_tile_data),.tiles_data64(memory_tile_data64),
        .sprites_req(video_enable ? render_sprite_req : (debug_route && sprites_req)),
        .sprites_addr(video_enable ? render_sprite_addr[22:1] : sprites_addr),.sprites_valid(memory_sprite_valid),.sprites_data(memory_sprite_data),.sprites_data64(memory_sprite_data64),
        .sfx_req(sfx_req),.sfx_addr(sfx_addr),.sfx_valid(sfx_valid),.sfx_data(sfx_data),
        .music_req(music_req),.music_addr(music_addr),.music_valid(music_valid),.music_data(music_data),
        .dram_req(dram_req),.dram_we(dram_we),.dram_addr(dram_addr),.dram_wdata(dram_wdata),.dram_be(dram_be),
        .dram_ready(dram_ready),.dram_rdata64(dram_rdata64),.queue_overflow(queue_overflow),
        .cpu_cache_hits(cpu_cache_hits),.cpu_cache_misses(cpu_cache_misses),.tile_cache_hits(tile_cache_hits),.tile_cache_misses(tile_cache_misses),
        .sprite_cache_hits(sprite_cache_hits),.sprite_cache_misses(sprite_cache_misses)
    );
    localparam integer REFRESH_BITS=REFRESH_PERIOD_CLKS>1?$clog2(REFRESH_PERIOD_CLKS):1;
    reg [REFRESH_BITS-1:0] refresh_count;
    wire refresh=initialized && refresh_count==REFRESH_BITS'(REFRESH_PERIOD_CLKS-1);
    always @(posedge clk) begin
        if(global_reset || !initialized || refresh)refresh_count<=0;
        else refresh_count<=refresh_count+1'b1;
    end
    // JTFRAME requests nine refresh commands per pulse; 15kHz supplies
    // 135000 refreshes/s, above 8192 rows / 64ms, including download/reset.
    // VERIFY_WRITES: each ROM-image write is read back and rewritten until
    // intact. Exhaustion aborts the loader; a new image resets the transport
    // and its sticky failure. BL1 group reads retain the hardware boot repair.
    // The fitted SDRAM clock samples new commands 5215ps after clk_sys.
    // CL2 DQ starts after chip edge +1 and is captured at core edge +2.
    // SHIFTED=1 aligns DOK with that registered word; 0 marks it a clock late.
    osman_sdram #(.SHIFTED(1),.EARLY_ISSUE(1),.VERIFY_WRITES(1),.GROUP_BURST(0)) u_sdram (.verify_mismatches(),.verify_failed(sdram_verify_failed),
        .clk(clk),.reset(global_reset || download_start),.refresh(refresh),.req(dram_req),.we(dram_we),
        .byte_addr(dram_addr),.wdata(dram_wdata),.be(dram_be),.ready(dram_ready),.rdata(),.rdata64(dram_rdata64),.initialized(initialized),
        .sdram_dq(sdram_dq),
`ifdef VERILATOR
        .sdram_din(sdram_din),
`endif
        .sdram_a(sdram_a),.sdram_ba(sdram_ba),.sdram_dqml(sdram_dqml),.sdram_dqmh(sdram_dqmh),
        .sdram_nwe(sdram_nwe),.sdram_ncas(sdram_ncas),.sdram_nras(sdram_nras),.sdram_ncs(sdram_ncs),.sdram_cke(sdram_cke)
    );
    osman_core #(.SYS_HZ(SYS_HZ),.CPU_HZ(CPU_HZ)) u_core (
        .clk(clk),.reset(core_reset),.pause(pause),.profile(profile),.irq_line(irq_line),.vblank(vblank),.irq_ack(irq_ack),
        .inputs_0(inputs_0),.inputs_1(inputs_1),
        .rom_req(cpu_rom_req),.rom_word_addr(cpu_rom_addr),.rom_ready(cpu_rom_ready),.rom_rdata(cpu_rom_data),
        .eeprom_load_en(core_eeprom_load),.eeprom_load_addr(core_eeprom_addr),.eeprom_load_data(core_eeprom_data),
        .eeprom_state_addr(eeprom_state_addr),.eeprom_state_data(eeprom_state_data),.eeprom_busy(eeprom_busy),
        .oki_sfx_status(oki_sfx_status),.oki_music_status(oki_music_status),
        .oki_sfx_wr(oki_sfx_wr),.oki_music_wr(oki_music_wr),.oki_data(oki_data),.music_bank(music_bank),
        .state_addr(state_addr),.state_data(state_data),.video_req(core_video_req),.video_addr(core_video_addr),
        .score_req(score_req),.score_we(score_we),.score_paused(score_paused),
        .score_addr(score_addr),.score_wdata(score_wdata),.score_valid(score_valid),.score_rdata(score_rdata),
        .video_valid(render_board_valid),.video_data(render_board_data),
        .cpu_state_index(cpu_state_index),.cpu_state_data(cpu_state_data),.cpu_at_boundary(cpu_at_boundary),
        .commit_valid(commit_valid),.commit_we(commit_we),.commit_addr(commit_addr),.commit_be(commit_be),.commit_data(commit_data),
        .write_count(write_count),.unmapped_count(unmapped_count)
    );
endmodule
