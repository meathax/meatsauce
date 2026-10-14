// Production composition: identical game RTL and physical SDRAM in sim/Quartus.
module argus_machine (
    input logic clk_sys, storage_reset, game_reset, pause_game,
    input logic [1:0] game_id, timing_profile,
    input logic [7:0] system_in, p1_in, p2_in, dip1, dip2,
    input logic user_flip_180,
    input logic ioctl_download, ioctl_wr,
    input logic [15:0] ioctl_index,
    input logic [24:0] ioctl_addr,
    input logic [7:0] ioctl_dout,
    output wire ioctl_wait, load_ready, bounds_error,
    input logic ram_req, ram_we, ram_grant,
    input logic [15:0] ram_addr,
    input logic [7:0] ram_wdata,
    output wire ram_ack,
    output wire [7:0] ram_rdata,
    output logic ce_pixel, active, hblank, vblank, hs, vs, line_start, frame_start,
    output logic [9:0] hpos, vpos,
    output wire [7:0] r, g, b,
    output wire pixel_valid,
    output wire signed [15:0] audio_l, audio_r,
    output wire sample_ce, deadline_miss,
    output wire [15:0] debug_pc,
    output wire [2:0] debug_bank,
    output wire debug_irq_n, debug_irq_ack,
    output wire [7:0] debug_irq_vector,
    output wire debug_sound_cmd_we,
    output wire [7:0] debug_sound_cmd,
    output wire debug_input_read,
    output wire [15:0] debug_input_addr,
    output wire [7:0] debug_input_data,
    output wire debug_bus_quiescent, debug_ram_busy,
    output wire debug_cpu_ram_write,
    output wire [15:0] debug_cpu_ram_addr,
    output wire [7:0] debug_cpu_ram_wdata,
`ifdef VERILATOR
    output wire [15:0] sim_sdram_dout,
`endif
    inout wire [15:0] SDRAM_DQ,
    output wire [12:0] SDRAM_A,
    output wire [1:0] SDRAM_BA,
    output wire SDRAM_DQML, SDRAM_DQMH,
    output wire SDRAM_nCS, SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE, SDRAM_CKE
);
    localparam integer SYS_HZ = 54000000;
    wire raw_ce, raw_active, raw_hblank, raw_vblank, raw_hs, raw_vs;
    wire raw_line_start, raw_frame_start;
    wire [9:0] raw_hpos, raw_vpos;
    wire [8:0] ref_scanline;
    wire ref_line_tick;
    argus_raster raster (
        .clk_sys(clk_sys), .storage_reset(storage_reset), .game_id(game_id),
        .ce_pixel(raw_ce), .active(raw_active), .hblank(raw_hblank),
        .vblank(raw_vblank), .hs(raw_hs), .vs(raw_vs),
        .line_start(raw_line_start), .frame_start(raw_frame_start),
        .hpos(raw_hpos), .vpos(raw_vpos), .ref_scanline(ref_scanline),
        .ref_line_tick(ref_line_tick)
    );
    // Game reset never resets SDRAM or stops sync. Release at a complete frame.
    logic machine_reset = 1'b1;
    logic [27:0] scan_tags;
    always_ff @(posedge clk_sys) begin
        if (storage_reset || game_reset || !load_ready || game_id == 3)
            machine_reset <= 1'b1;
        else if (raw_frame_start) machine_reset <= 1'b0;
        // Each renderer reads its synchronous scan RAM, then registers RGB and
        // valid on the following edge. Keep the coordinates, blanking and sync
        // with that same two-edge pipeline, including the first/last column.
        if(storage_reset) begin
            scan_tags <= {1'b0,1'b0,1'b1,1'b1,1'b1,1'b1,1'b0,1'b0,10'd0,10'd0};
            {ce_pixel,active,hblank,vblank,hs,vs,line_start,frame_start,hpos,vpos} <=
                {1'b0,1'b0,1'b1,1'b1,1'b1,1'b1,1'b0,1'b0,10'd0,10'd0};
        end else begin
            scan_tags <= {raw_ce,raw_active,raw_hblank,raw_vblank,raw_hs,raw_vs,
                          raw_line_start,raw_frame_start,raw_hpos,raw_vpos};
            {ce_pixel,active,hblank,vblank,hs,vs,line_start,frame_start,hpos,vpos} <= scan_tags;
        end
    end
    wire ce_main, ce_sound_cpu, ce_opn;
    // Raw chip enables continue through reset/pause; CPUs/chips gate their own
    // gameplay advances. This allows the 127-enable Yamaha reset flush to finish.
    argus_clock_enables #(.SYS_HZ(SYS_HZ)) enables (
        .clk_sys(clk_sys), .reset(storage_reset), .pause_game(1'b0),
        .game_id(game_id), .timing_profile(timing_profile),
        .ce_main(ce_main), .ce_sound_cpu(ce_sound_cpu), .ce_opn(ce_opn)
    );
    wire main_req, main_ready, sound_req, sound_ready;
    wire [23:0] main_addr, sound_addr;
    wire [7:0] main_rdata, sound_rdata;
    wire [2:0] gfx_req, gfx_ready, vready_all, valid_all, missed_all;
    wire [23:0] gfx_addr [0:2];
    wire [7:0] vrdata_all [0:2], red_all [0:2], green_all [0:2], blue_all [0:2];
    wire video_req = game_id == 0 ? gfx_req[0] : game_id == 1 ? gfx_req[1] :
                     game_id == 2 ? gfx_req[2] : 1'b0;
    wire [23:0] video_addr = game_id == 0 ? gfx_addr[0] :
                            game_id == 1 ? gfx_addr[1] : gfx_addr[2];
    wire video_ready;
    wire [63:0] video_rdata;
    assign gfx_ready[0] = video_ready && game_id == 0;
    assign gfx_ready[1] = video_ready && game_id == 1;
    assign gfx_ready[2] = video_ready && game_id == 2;
    wire mem_req, mem_we, mem_read_wide, mem_ready, mem_init_ready;
    wire [23:0] mem_addr;
    wire [7:0] mem_wdata, mem_rdata;
    wire [63:0] mem_rdata64;
    wire storage_wait,storage_image_ready,storage_bounds_error;
    wire sprite_byte_ready,sprite_image_ready,sprite_fault,sprite_region,sprite_ready;
    wire [63:0] storage_video_data,sprite_data;
    wire storage_video_ready;
    wire gpu_backing_req;
    wire [23:0] gpu_backing_addr;
    wire rom_transfer=ioctl_download && ioctl_index==16'd0;
    logic sprite_download_d=1'b0;
    always_ff @(posedge clk_sys) begin
        if(storage_reset) sprite_download_d<=1'b0;
        else sprite_download_d<=rom_transfer;
    end
    // Both stores consume each raw download byte on the same accepted edge.
    // Their readiness is independent, avoiding a combinational wait loop.
    // A dictionary fault invalidates the image while the raw transfer drains.
    wire sprite_loader_wait=rom_transfer && !sprite_fault && !sprite_byte_ready;
    assign ioctl_wait=storage_wait || sprite_loader_wait;
    assign load_ready=storage_image_ready && sprite_image_ready && !sprite_fault;
    assign bounds_error=storage_bounds_error || sprite_fault;
    assign video_ready=sprite_ready;
    assign video_rdata=sprite_data;
    argus_gpu_rom_store #(.ARGUS_AUX_ROMS(1'b1),.PREHEAT_BUTASAN_TEXT(1'b1)) sprites (
        .clk(clk_sys),.cold_reset(storage_reset),
        .start_load(rom_transfer && !sprite_download_d),.game_id(game_id),
        .load_valid(rom_transfer && ioctl_wr && !storage_wait && !sprite_fault),
        .load_addr(ioctl_addr),.load_data(ioctl_dout),.load_byte_ready(sprite_byte_ready),
        .load_end(!rom_transfer && sprite_download_d),
        .image_ready(sprite_image_ready),.fault(sprite_fault),.fault_code(),
        .read_abort(machine_reset),.read_req(video_req && load_ready),.read_addr(video_addr),
        .direct_region(sprite_region),.read_ready(sprite_ready),.read_data(sprite_data),
        .backing_req(gpu_backing_req),.backing_addr(gpu_backing_addr),
        .backing_ready(storage_video_ready),.backing_data(storage_video_data),
        .debug_words_loaded(),.debug_unique_words(),.debug_probes_total(),
        .debug_max_probes(),.debug_backpressure_cycles(),
        .debug_cache_hits(),.debug_cache_misses(),.debug_cache_discarded()
    );
    argus_rom_store rom_store (
        .clk_sys(clk_sys), .reset(storage_reset), .game_id(game_id),
        .ioctl_download(ioctl_download), .ioctl_wr(ioctl_wr && (!rom_transfer || sprite_byte_ready || sprite_fault)),
        .ioctl_index(ioctl_index), .ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout),
        .ioctl_wait(storage_wait), .load_ready(storage_image_ready), .bounds_error(storage_bounds_error),
        .main_req(main_req), .main_addr(main_addr),
        .main_ready(main_ready), .main_rdata(main_rdata),
        .video_req(gpu_backing_req), .video_addr(gpu_backing_addr),
        .video_ready(storage_video_ready), .video_rdata(storage_video_data),
        .sound_req(sound_req), .sound_addr(sound_addr),
        .sound_ready(sound_ready), .sound_rdata(sound_rdata),
        .mem_req(mem_req), .mem_we(mem_we), .mem_read_wide(mem_read_wide),
        .mem_addr(mem_addr), .mem_wdata(mem_wdata),
        .mem_ready(mem_ready), .mem_rdata(mem_rdata),
        .mem_rdata64(mem_rdata64), .mem_init_ready(mem_init_ready)
    );
    // The donor command pipeline is not initialized before its first reset edge.
    // Deselect the physical module throughout cold storage reset; soft game
    // resets leave SDRAM commands and refresh running.
    wire bridge_sdram_ncs;
    assign SDRAM_nCS = storage_reset ? 1'b1 : bridge_sdram_ncs;
    argus_sdram_bridge #(.SYS_HZ(SYS_HZ)) bridge (
        .clk_sys(clk_sys), .reset(storage_reset),
        .req(mem_req), .we(mem_we), .read_wide(mem_read_wide),
        .addr(mem_addr), .wdata(mem_wdata), .ready(mem_ready),
        .rdata(mem_rdata), .rdata64(mem_rdata64), .mem_init_ready(mem_init_ready),
        .SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A), .SDRAM_BA(SDRAM_BA),
        .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
        .SDRAM_nCS(bridge_sdram_ncs), .SDRAM_nRAS(SDRAM_nRAS),
        .SDRAM_nCAS(SDRAM_nCAS), .SDRAM_nWE(SDRAM_nWE), .SDRAM_CKE(SDRAM_CKE)
`ifdef VERILATOR
        , .sim_sdram_dout(sim_sdram_dout)
`endif
    );
    wire vreq, vwe;
    wire [15:0] vaddr;
    wire [7:0] vwdata;
    wire vready = game_id == 0 ? vready_all[0] : game_id == 1 ? vready_all[1] :
                  game_id == 2 ? vready_all[2] : 1'b0;
    wire [7:0] vrdata = game_id == 0 ? vrdata_all[0] :
                       game_id == 1 ? vrdata_all[1] : vrdata_all[2];
    argus_main_cpu main_cpu (
        .clk_sys(clk_sys), .reset(machine_reset), .ce_main(ce_main),
        .pause_game(pause_game), .game_id(game_id),
        .system_in(system_in), .p1_in(p1_in), .p2_in(p2_in), .dip1(dip1), .dip2(dip2),
        .ref_scanline(ref_scanline), .ref_line_tick(ref_line_tick && !pause_game),
        .rom_req(main_req), .rom_addr(main_addr), .rom_ready(main_ready), .rom_rdata(main_rdata),
        .vreq(vreq), .vwe(vwe), .vaddr(vaddr), .vwdata(vwdata),
        .vready(vready), .vrdata(vrdata), .sound_cmd(debug_sound_cmd),
        .sound_cmd_we(debug_sound_cmd_we),
        .ram_req(ram_req), .ram_we(ram_we), .ram_addr(ram_addr),
        .ram_wdata(ram_wdata), .ram_grant(ram_grant && pause_game),
        .ram_ack(ram_ack), .ram_rdata(ram_rdata), .pc(debug_pc),
        .debug_bank(debug_bank), .debug_irq_n(debug_irq_n), .debug_irq_ack(debug_irq_ack),
        .debug_irq_vector(debug_irq_vector), .debug_input_read(debug_input_read),
        .debug_input_addr(debug_input_addr), .debug_input_data(debug_input_data),
        .debug_cpu_ram_write(debug_cpu_ram_write),
        .debug_cpu_ram_addr(debug_cpu_ram_addr),.debug_cpu_ram_wdata(debug_cpu_ram_wdata),
        .debug_bus_quiescent(debug_bus_quiescent), .debug_ram_busy(debug_ram_busy)
    );
    wire audio_io_we, audio_io_re, audio_latch_read, audio_ram_write, audio_irq_n;
    wire [7:0] audio_io_addr, audio_io_data;
    wire [15:0] audio_cpu_addr, audio_chip_debug;
    wire [1:0] audio_chip_irq_n;
    argus_audio audio (
        .clk_sys(clk_sys), .reset(machine_reset),
        .ce_sound_cpu(ce_sound_cpu), .ce_opn(ce_opn), .pause_game(pause_game),
        .game_id(game_id), .sound_cmd(debug_sound_cmd), .sound_cmd_we(debug_sound_cmd_we),
        .rom_req(sound_req), .rom_addr(sound_addr), .rom_ready(sound_ready), .rom_rdata(sound_rdata),
        .audio_l(audio_l), .audio_r(audio_r), .sample_ce(sample_ce),
        .trace_io_we(audio_io_we), .trace_io_re(audio_io_re),
        .trace_latch_read(audio_latch_read), .trace_ram_write(audio_ram_write),
        .trace_io_addr(audio_io_addr), .trace_io_data(audio_io_data),
        .trace_cpu_addr(audio_cpu_addr), .trace_chip_debug(audio_chip_debug),
        .trace_irq_n(audio_irq_n), .trace_chip_irq_n(audio_chip_irq_n)
    );
    argus_video #(.SHARED_RAW_SPRITES(1'b1),.CACHE_AW(11),.EXTERNAL_GFX_CACHE(1'b1)) video_argus (
        .clk_sys(clk_sys), .reset(machine_reset || game_id != 0),
        .game_id(game_id), .timing_profile(timing_profile), .user_flip_180(user_flip_180),
        .ce_pixel(raw_ce), .hpos(raw_hpos), .vpos(raw_vpos),
        .active(raw_active), .hblank(raw_hblank), .vblank(raw_vblank),
        .line_start(raw_line_start), .frame_start(raw_frame_start),
        .vreq(vreq && game_id == 0), .vwe(vwe), .vaddr(vaddr), .vwdata(vwdata),
        .vready(vready_all[0]), .vrdata(vrdata_all[0]),
        .rom_req(gfx_req[0]), .rom_addr(gfx_addr[0]), .rom_ready(gfx_ready[0]),
        .rom_rdata(video_rdata), .r(red_all[0]), .g(green_all[0]), .b(blue_all[0]),
        .pixel_valid(valid_all[0]), .deadline_miss(missed_all[0])
    );
    argus_video_valtric #(.RAW_OBJECT_STORE(1'b1),.CACHE_AW(11),.EXTERNAL_GFX_CACHE(1'b1)) video_valtric (
        .clk_sys(clk_sys), .reset(machine_reset || game_id != 1),
        .game_id(game_id), .timing_profile(timing_profile), .user_flip_180(user_flip_180),
        .ce_pixel(raw_ce), .hpos(raw_hpos), .vpos(raw_vpos),
        .active(raw_active), .hblank(raw_hblank), .vblank(raw_vblank),
        .line_start(raw_line_start), .frame_start(raw_frame_start),
        .vreq(vreq && game_id == 1), .vwe(vwe), .vaddr(vaddr), .vwdata(vwdata),
        .vready(vready_all[1]), .vrdata(vrdata_all[1]),
        .rom_req(gfx_req[1]), .rom_addr(gfx_addr[1]), .rom_ready(gfx_ready[1]),
        .rom_rdata(video_rdata), .r(red_all[1]), .g(green_all[1]), .b(blue_all[1]),
        .pixel_valid(valid_all[1]), .deadline_miss(missed_all[1])
    );
    argus_video_butasan #(.RAW_OBJECT_STORE(1),.SHARED_GFX_CACHE(1)) video_butasan (
        .clk_sys(clk_sys), .reset(machine_reset || game_id != 2),
        .game_id(game_id), .timing_profile(timing_profile), .user_flip_180(user_flip_180),
        .ce_pixel(raw_ce), .hpos(raw_hpos), .vpos(raw_vpos),
        .active(raw_active), .hblank(raw_hblank), .vblank(raw_vblank),
        .line_start(raw_line_start), .frame_start(raw_frame_start),
        .vreq(vreq && game_id == 2), .vwe(vwe), .vaddr(vaddr), .vwdata(vwdata),
        .vready(vready_all[2]), .vrdata(vrdata_all[2]),
        .rom_req(gfx_req[2]), .rom_addr(gfx_addr[2]), .rom_ready(gfx_ready[2]),
        .rom_rdata(video_rdata), .r(red_all[2]), .g(green_all[2]), .b(blue_all[2]),
        .pixel_valid(valid_all[2]), .deadline_miss(missed_all[2])
    );
    assign r = game_id == 0 ? red_all[0] : game_id == 1 ? red_all[1] : red_all[2];
    assign g = game_id == 0 ? green_all[0] : game_id == 1 ? green_all[1] : green_all[2];
    assign b = game_id == 0 ? blue_all[0] : game_id == 1 ? blue_all[1] : blue_all[2];
    assign pixel_valid = game_id == 0 ? valid_all[0] : game_id == 1 ? valid_all[1] :
                         game_id == 2 ? valid_all[2] : 1'b0;
    assign deadline_miss = game_id == 0 ? missed_all[0] : game_id == 1 ? missed_all[1] :
                           game_id == 2 ? missed_all[2] : 1'b1;
endmodule
