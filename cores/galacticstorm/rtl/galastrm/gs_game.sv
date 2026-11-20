// SPDX-License-Identifier: GPL-3.0-or-later
// Real CPU board + physical graphics/memory, with native full sound and shared
// DDR selected by FULL_AUDIO. Final MiSTer wrapper/PLL qualification is separate.
module gs_game #(parameter integer SYS_HZ=32000000,parameter FULL_AUDIO=0,parameter LIVE_DOWNLOAD=0,parameter OSD_FEATURES=0,parameter LINE_WRITES=0)(
    input wire cpu_clk,ram_clk,reset,rom_ready,pause,
    input wire dsp_clk,cold_reset,
    input wire screen_flip,
    input wire cpu_turbo, // OSD overclock of the main 68020 (32 MHz enable), reduces game slowdown
    input wire affine_mame, // 0: PCB-fitted TC0610 mapping (default), 1: MAME rotation/zoom
    input wire hs_req,hs_write,input wire [24:0] hs_addr,
    input wire [15:0] hs_data,input wire [1:0] hs_bytes,
    output wire hs_ack,output wire [15:0] hs_reply,output wire hs_paused,
    input wire download_req,download_write,
    input wire [24:0] download_addr,
    input wire [15:0] download_data,
    input wire [1:0] download_bytes,
    output wire download_ack,
    input wire [7:0] in0,in2,stick_x,stick_y,
    input wire nvram_ld_wr,input wire [5:0] nvram_ld_addr,nvram_sv_addr,
    input wire [15:0] nvram_ld_data,output wire [15:0] nvram_sv_data,output wire nvram_dirty,
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
    output wire audio_fault,
    output wire [15:0] audio_input_overrun,audio_output_underrun,audio_max_sample_cycles,
    output wire scan_valid,native_visible_ce,
    output wire [15:0] scan_index,
    output wire [23:0] pixel_rgb,
    output reg pixel_ce,
    output reg video_ce,video_hsync,video_vsync,video_hblank,video_vblank,
    output reg [31:0] frame_count,
    output reg deadline_fault,
    output wire initialized,video_done,video_supported,video_overflow,
    inout wire [15:0] SDRAM_DQ,
    output wire [12:0] SDRAM_A,output wire [1:0] SDRAM_BA,
    output wire SDRAM_DQML,SDRAM_DQMH,SDRAM_nCS,SDRAM_nWE,SDRAM_nRAS,SDRAM_nCAS,SDRAM_CKE,SDRAM_CLK,
    input wire DDRAM_BUSY,output wire [7:0] DDRAM_BURSTCNT,output wire [28:0] DDRAM_ADDR,
    input wire [63:0] DDRAM_DOUT,input wire DDRAM_DOUT_READY,output wire DDRAM_RD,
    output wire [63:0] DDRAM_DIN,output wire [7:0] DDRAM_BE,output wire DDRAM_WE
);
    wire cpu_memory_req,cpu_memory_write,cpu_memory_ack;
    wire [24:0] cpu_memory_addr;
    wire [15:0] cpu_memory_data,cpu_memory_reply;
    wire [63:0] cpu_memory_line,ram_reply_line;
    wire cpu_memory_write_line,ram_write_line;wire [63:0] cpu_memory_wline,ram_wline;
    wire [1:0] cpu_memory_bytes;
    wire ram_req,ram_write,ram_ack,bridge_idle;
    wire [24:0] ram_addr;
    wire [15:0] ram_data,ram_reply;
    wire [1:0] ram_bytes;
    wire [383:0] scp_controls;
    wire [127:0] scn_controls;
    wire [255:0] affine_controls;
    wire main_idle;
    wire audio_startup_ready;
    wire video_ddr_busy,video_ddr_ready,video_ddr_rd,video_ddr_we;
    wire audio_ddr_busy,audio_ddr_ready,audio_ddr_rd,audio_ddr_we;
    wire [7:0] video_ddr_burst,video_ddr_be,audio_ddr_burst,audio_ddr_be;
    wire [28:0] video_ddr_addr,audio_ddr_addr;
    wire [63:0] video_ddr_din,audio_ddr_din,shared_ddr_dout;
    reg freeze_cpu,vblank_cpu,palette_pending;
    wire palette_cut_ack,palette_busy;
    reg request_toggle,freeze_toggle,release_toggle;
    // Vblank belongs to the raster, including frames for which rendering is
    // busy. Defer delivery only for the bounded snapshot freeze itself.
    reg vblank_toggle,vblank_s1,vblank_s2,vblank_seen;
    reg request_s1,request_s2,release_s1,release_s2,freeze_s1,freeze_s2;
    reg [1:0] ready_s;
    reg [383:0] captured_scp;
    reg [127:0] captured_scn;
    reg [255:0] captured_affine;
    wire cpu_reset=reset || !ready_s[1];
    // Stop new CPU issue before waiting for posted writes to drain. A sustained
    // video clear can otherwise refill the FIFO and starve the snapshot.
    // Dedicated RAM-clock register for the DSP reset capture: keeps the shared
    // high-fanout game reset off that path. Both edges move one RAM clock; the
    // engine already re-registers this level into the DSP domain.
    (* preserve *) reg audio_reset_q=1'b1;
    always @(posedge ram_clk) audio_reset_q<=reset || !rom_ready;
    wire freeze_request=!cpu_reset && !freeze_cpu && request_s2!=freeze_toggle;
    wire freeze_enter=freeze_request && main_idle;
    gs_board #(.SYS_HZ(SYS_HZ),.FULL_AUDIO(FULL_AUDIO),.SAMPLE_LINES(FULL_AUDIO),.LINE_WRITES(LINE_WRITES)) board(
        .clk(cpu_clk),.reset(cpu_reset),.pause(pause),.vblank(vblank_cpu),
        .dsp_clk(dsp_clk),.ram_clk(ram_clk),.cold_reset(cold_reset),.audio_reset(audio_reset_q),
        .main_bus_pause(freeze_cpu || freeze_request),.main_cpu_turbo(cpu_turbo),.main_bus_idle(main_idle),
        .in0(in0),.in2(in2),.stick_x(stick_x),.stick_y(stick_y),
        .nvram_ld_wr(nvram_ld_wr),.nvram_ld_addr(nvram_ld_addr),.nvram_ld_data(nvram_ld_data),
        .nvram_sv_addr(nvram_sv_addr),.nvram_sv_data(nvram_sv_data),.nvram_dirty(nvram_dirty),
        .pixel_ce(1'b0),.pixel_index(12'b0),.pixel_rgb(),
        .scp_controls(scp_controls),.scn_controls(scn_controls),.affine_controls(affine_controls),
        .mem_req(cpu_memory_req),.mem_write(cpu_memory_write),.mem_addr(cpu_memory_addr),
        .mem_wdata(cpu_memory_data),.mem_be(cpu_memory_bytes),.mem_write_line(cpu_memory_write_line),.mem_wline(cpu_memory_wline),.mem_ack(cpu_memory_ack),.mem_rdata(cpu_memory_reply),.mem_rline(cpu_memory_line),
        .main_debug_req(main_debug_req),.main_debug_ack(main_debug_ack),.main_debug_write(main_debug_write),.main_debug_fetch(main_debug_fetch),
        .main_debug_addr(main_debug_addr),.main_debug_wdata(main_debug_wdata),.main_debug_be(main_debug_be),.main_debug_fc(main_debug_fc),.main_debug_irq_n(main_debug_irq_n),
        .sound_debug_req(sound_debug_req),.sound_debug_ack(sound_debug_ack),.sound_debug_write(sound_debug_write),.sound_debug_fetch(sound_debug_fetch),
        .sound_debug_addr(sound_debug_addr),.sound_debug_wdata(sound_debug_wdata),.sound_debug_be(sound_debug_be),.sound_debug_fc(sound_debug_fc),
        .sound_debug_irq(sound_debug_irq),.sound_running(sound_running),.sample_valid(sample_valid),.dsp_halt(dsp_halt),
        .dry_l(dry_l),.dry_r(dry_r),.sampler_drop(sampler_drop),.sampler_overrun(sampler_overrun),
        .pcm_valid(pcm_valid),.pcm_l(pcm_l),.pcm_r(pcm_r),.audio_startup_ready(audio_startup_ready),.audio_fault(audio_fault),
        .audio_input_overrun(audio_input_overrun),.audio_output_underrun(audio_output_underrun),.audio_max_sample_cycles(audio_max_sample_cycles),
        .AUDIO_DDRAM_BUSY(audio_ddr_busy),.AUDIO_DDRAM_BURSTCNT(audio_ddr_burst),.AUDIO_DDRAM_ADDR(audio_ddr_addr),
        .AUDIO_DDRAM_DOUT(shared_ddr_dout),.AUDIO_DDRAM_DOUT_READY(audio_ddr_ready),.AUDIO_DDRAM_RD(audio_ddr_rd),
        .AUDIO_DDRAM_DIN(audio_ddr_din),.AUDIO_DDRAM_BE(audio_ddr_be),.AUDIO_DDRAM_WE(audio_ddr_we));
    generate if(FULL_AUDIO)begin: shared_audio_video
        wire [1:0] service_busy,service_ready;
        gs_ddr_arb2 service(
            .clk(ram_clk),.reset(cold_reset),.rd({audio_ddr_rd,video_ddr_rd}),.we({audio_ddr_we,video_ddr_we}),
            .burstcnt({audio_ddr_burst,video_ddr_burst}),.addr({audio_ddr_addr,video_ddr_addr}),
            .din({audio_ddr_din,video_ddr_din}),.be({audio_ddr_be,video_ddr_be}),
            .busy(service_busy),.dout_ready(service_ready),.dout(shared_ddr_dout),
            .DDRAM_BUSY(DDRAM_BUSY),.DDRAM_BURSTCNT(DDRAM_BURSTCNT),.DDRAM_ADDR(DDRAM_ADDR),
            .DDRAM_DOUT(DDRAM_DOUT),.DDRAM_DOUT_READY(DDRAM_DOUT_READY),.DDRAM_RD(DDRAM_RD),
            .DDRAM_DIN(DDRAM_DIN),.DDRAM_BE(DDRAM_BE),.DDRAM_WE(DDRAM_WE));
        assign {audio_ddr_busy,video_ddr_busy}=service_busy;
        assign {audio_ddr_ready,video_ddr_ready}=service_ready;
    end else begin: video_only
        assign video_ddr_busy=DDRAM_BUSY;assign video_ddr_ready=DDRAM_DOUT_READY;
        assign shared_ddr_dout=DDRAM_DOUT;
        assign audio_ddr_busy=0;assign audio_ddr_ready=0;
        assign DDRAM_RD=video_ddr_rd;assign DDRAM_WE=video_ddr_we;
        assign DDRAM_BURSTCNT=video_ddr_burst;assign DDRAM_ADDR=video_ddr_addr;
        assign DDRAM_DIN=video_ddr_din;assign DDRAM_BE=video_ddr_be;
    end endgenerate
    // cpu_clk and ram_clk are one PLL output in the common64 profile.
    gs_bus_cdc #(.LINE_REPLY(FULL_AUDIO),.LINE_WRITES(LINE_WRITES),.SAME_CLOCK(SYS_HZ==64000000)) memory_bridge(
        .cpu_clk(cpu_clk),.ram_clk(ram_clk),.reset(reset || !rom_ready),
        .cpu_req(cpu_memory_req),.cpu_write(cpu_memory_write),.cpu_addr(cpu_memory_addr),
        .cpu_wdata(cpu_memory_data),.cpu_bytes(cpu_memory_bytes),.cpu_write_line(cpu_memory_write_line),.cpu_wline(cpu_memory_wline),.cpu_ack(cpu_memory_ack),.cpu_idle(bridge_idle),.cpu_rdata(cpu_memory_reply),.cpu_rline(cpu_memory_line),
        .ram_req(ram_req),.ram_write(ram_write),.ram_addr(ram_addr),.ram_wdata(ram_data),.ram_bytes(ram_bytes),.ram_write_line(ram_write_line),.ram_wline(ram_wline),.ram_ack(ram_ack),.ram_rdata(ram_reply),.ram_rline(ram_reply_line));
`ifndef SYNTHESIS
    reg freeze_enter_d;
    always @(posedge cpu_clk)begin
        if(!cpu_reset && freeze_enter_d)
            assert(!main_debug_req) else $fatal(1,"Snapshot freeze launched a late native CPU transfer");
        freeze_enter_d<=freeze_enter;
        if(cpu_reset)freeze_enter_d<=0;
    end
`endif
    // Only the CPU execution bridge freezes. ADC/audio device clocks continue.
    // Native IRQ5 is released after snapshot cut and controls are accepted.
    always @(posedge cpu_clk) begin
        // Main CPU release follows its own memory readiness. Full sound keeps
        // its CPU held independently by gs_sound_devices_full.board_reset until
        // the audio RAM initialization completes.
        ready_s<={ready_s[0],initialized && rom_ready};
        request_s1<=request_toggle;request_s2<=request_s1;
        release_s1<=release_toggle;release_s2<=release_s1;
        vblank_s1<=vblank_toggle;vblank_s2<=vblank_s1;
        vblank_cpu<=0;
        if(vblank_s2!=vblank_seen && !freeze_cpu && !freeze_request) begin
            vblank_cpu<=1;vblank_seen<=vblank_s2;
        end
        if(freeze_enter) begin
            captured_scp<=scp_controls;captured_scn<=scn_controls;captured_affine<=affine_controls;
            freeze_cpu<=1;palette_pending<=1;
        end
        if(freeze_cpu && palette_pending && palette_cut_ack) begin palette_pending<=0;freeze_toggle<=request_s2;end
        if(freeze_cpu && !palette_pending && release_s2==freeze_toggle) freeze_cpu<=0;
        if(reset || !rom_ready) begin
            ready_s<=0;request_s1<=0;request_s2<=0;release_s1<=0;release_s2<=0;
            vblank_s1<=0;vblank_s2<=0;vblank_seen<=0;
            freeze_cpu<=0;palette_pending<=0;freeze_toggle<=0;vblank_cpu<=0;captured_scp<=0;captured_scn<=0;captured_affine<=0;
        end
    end
    // next_bank is held from request admission through QUERY. Synchronize it
    // alongside permission; permission is asserted only after FREEZE starts.
    // No palette copy may overwrite the retained or actively scanned page.
    wire palette_bank_free=
        !(have_shown && shown_bank==next_bank) &&
        !(scanout_active && display_bank==next_bank) &&
        !(video_done && video_done_bank==next_bank);
    wire palette_target_available=state==FREEZE && palette_bank_free;
    (* altera_attribute="-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *) reg [1:0] palette_permission_s,palette_bank_s;
    always @(posedge cpu_clk) begin
        palette_permission_s<={palette_permission_s[0],palette_target_available};
        palette_bank_s<={palette_bank_s[0],next_bank};
        if(reset || !rom_ready) begin palette_permission_s<=0;palette_bank_s<=0;end
    end
    gs_palette_snapshot #(.BANKED(1)) palette(
        .cpu_clk(cpu_clk),.video_clk(ram_clk),.reset(reset || !rom_ready),
        .write_strobe(main_debug_req && main_debug_ack && main_debug_write && main_debug_addr[23:2]==22'h240000),
        .cpu_reg(main_debug_addr[1]),.cpu_bytes(main_debug_be),.cpu_data(main_debug_wdata),
        .cut(freeze_cpu && palette_pending && palette_permission_s[1]),
        .copy_bank(palette_bank_s[1]),.pixel_page(display_bank),
        .cut_ack(palette_cut_ack),.copy_busy(palette_busy),
        .pixel_ce(native_visible_ce && scan_valid),.pixel_index(scan_index[11:0]),.pixel_rgb(pixel_rgb));
`ifndef SYNTHESIS
    // Keep the bounded data-wire timing exception tied to its actual protocol.
    // Four64MHz cycles exceed the required one32MHz settling interval. Native
    // palette copy normally holds these controls for thousands of cycles.
    reg [383:0] observed_scp;
    reg [127:0] observed_scn;
    reg [255:0] observed_affine;
    reg [7:0] control_settle;
    always @(posedge ram_clk)begin
        observed_scp<=captured_scp;observed_scn<=captured_scn;observed_affine<=captured_affine;
        if(reset || !rom_ready || observed_scp!=captured_scp || observed_scn!=captured_scn || observed_affine!=captured_affine)control_settle<=0;
        else if(control_settle!=255)control_settle<=control_settle+1'b1;
        if(!reset && rom_ready && state==QUERY && query_ready)
            assert(frozen && control_settle>=4) else $error("GPU sampled an unsettled control bank");
    end
`endif
    always @(posedge ram_clk) begin
        pixel_ce<=native_visible_ce && scan_valid;
        if(reset || !rom_ready) pixel_ce<=0;
        // Palette RAM and these raster qualifiers retire on the same edge.
        video_ce<=native_pixel_ce;
        video_hsync<=native_x<32;video_vsync<=native_y<4;
        video_hblank<=native_x<96 || native_x>=416;
        video_vblank<=SYS_HZ==64000000 ? (native_y<16 || native_y>=248) : (native_y<84 || native_y>=316);
    end
    wire native_pixel_ce;wire [8:0] native_x,native_y;
    localparam IDLE=0,FREEZE=1,CUT=2,QUERY=3;
    reg [1:0] state;
    reg next_bank,display_start,display_bank;
    wire scanout_active;
    // Present the newest completed rotation. A late renderer repeats that
    // frame instead of scanning a bank or text layer still being rebuilt.
    reg shown_bank,have_shown;
    wire video_done_bank;
    wire [1:0] presentable;
    wire frame_cut,cut_ready,cut_ack,query_ready,cpu_mapped,video_cpu_ack,host_ack,underflow;
    wire [15:0] video_cpu_reply,host_reply;
    wire [63:0] host_reply_line;
    wire frozen=freeze_s2==request_toggle;
    assign ram_ack=cpu_mapped?video_cpu_ack:host_ack;
    assign ram_reply=cpu_mapped?video_cpu_reply:host_reply;
    assign ram_reply_line=cpu_mapped ? {48'b0,video_cpu_reply} : host_reply_line;
    wire physical_host_req,physical_host_write,physical_host_ack;
    wire shared_host_req,shared_host_write,shared_host_ack;
    wire [24:0] shared_host_addr;wire [63:0] shared_host_data;
    wire [7:0] shared_host_bytes;
    assign hs_paused=main_idle && bridge_idle;
    assign hs_reply=host_reply;
    wire physical_host_write_line,shared_host_write_line;wire [63:0] physical_host_wline;
    // High-score persistence is removed. The physical loader/CPU path has one
    // producer here; an unused score arbiter only adds packet storage/latency.
    // OSD_FEATURES still enables the independent 180-degree display flip.
    generate begin: no_score_port
        assign shared_host_req=physical_host_req;assign shared_host_write=physical_host_write;
        assign shared_host_addr=physical_host_addr;assign shared_host_data=physical_host_write_line ? physical_host_wline : {48'b0,physical_host_data};
        assign shared_host_write_line=physical_host_write_line;
        assign shared_host_bytes={6'b0,physical_host_bytes};
        assign physical_host_ack=shared_host_ack;assign hs_ack=0;
    end endgenerate
    wire [24:0] physical_host_addr;
    wire [15:0] physical_host_data;
    wire [1:0] physical_host_bytes;
    generate if(LIVE_DOWNLOAD)begin: live_rom
        // Cold reset alone owns this arbiter. A new upload holds the CPU bridge
        // in reset, but an already captured CPU packet still retires intact.
        gs_rom_upload_port #(.LINE_WRITES(LINE_WRITES)) ports(
            .clk(ram_clk),.cold_reset(cold_reset),
            .cpu_req(ram_req && !cpu_mapped),.cpu_write(ram_write),.cpu_addr(ram_addr),
            .cpu_data(ram_data),.cpu_bytes(ram_bytes),.cpu_write_line(ram_write_line),.cpu_wline(ram_wline),.cpu_ack(host_ack),
            .download_req(download_req),.download_write(download_write),.download_addr(download_addr),
            .download_data(download_data),.download_bytes(download_bytes),.download_ack(download_ack),
            .mem_req(physical_host_req),.mem_write(physical_host_write),.mem_addr(physical_host_addr),
            .mem_data(physical_host_data),.mem_bytes(physical_host_bytes),.mem_write_line(physical_host_write_line),.mem_wline(physical_host_wline),.mem_ack(physical_host_ack));
    end else begin: preloaded_rom
        assign physical_host_req=ram_req && !cpu_mapped;
        assign physical_host_write=ram_write;assign physical_host_addr=ram_addr;
        assign physical_host_data=ram_data;assign physical_host_bytes=ram_bytes;
        assign physical_host_write_line=LINE_WRITES && ram_write_line;assign physical_host_wline=ram_wline;
        assign host_ack=physical_host_ack;assign download_ack=0;
    end endgenerate
    gs_video_gpu #(.PRESENT_15K(SYS_HZ==64000000),.CURRENT_TEXT(1),.ROM_RESET_SEPARATE(LIVE_DOWNLOAD),.FLIP_SUPPORT(OSD_FEATURES),.LINE_WRITES(LINE_WRITES)) video(
        .clk(ram_clk),.reset(reset || !rom_ready),.initialized(initialized),.screen_flip(screen_flip),
        .rom_reset(cold_reset),
        .cut(state==CUT && frozen),.cpu_bus_idle(frozen && !(ram_req && cpu_mapped)),
        .cut_ready(cut_ready),.cut_ack(cut_ack),
        .cpu_req(ram_req && cpu_mapped),.cpu_write(ram_write),.cpu_addr(ram_addr),.cpu_wdata(ram_data),.cpu_bytes(ram_bytes),.cpu_write_line(ram_write_line),.cpu_wline(ram_wline),
        .cpu_mapped(cpu_mapped),.cpu_ack(video_cpu_ack),.cpu_rdata(video_cpu_reply),
        .host_req(shared_host_req),.host_write(shared_host_write),.host_addr(shared_host_addr),.host_wdata(shared_host_data[15:0]),.host_bytes(shared_host_bytes[1:0]),.host_write_line(shared_host_write_line),.host_wline(shared_host_data),.host_ack(shared_host_ack),.host_rdata(host_reply),.host_rline(host_reply_line),
        .query(state==QUERY && query_ready),.bank(next_bank),.query_ready(query_ready),
        .controls(captured_scp),.scn_controls(captured_scn),.current_restart(frame_cut && !pause && state==IDLE && query_ready && cut_ready),.rzx(captured_affine[175:160]),.rzy(captured_affine[191:176]),
        .affine_pcb(!affine_mame),.affine_regs({captured_affine[255:240],captured_affine[223:128]}),
        .done(video_done),.done_bank(video_done_bank),.presentable(presentable),.supported(video_supported),.overflow(video_overflow),
        .display_start(display_start),.display_bank(display_bank),.visible_pixel_ce(1'b0),.raster_run(initialized && rom_ready),
        .native_frame_cut(frame_cut),.native_visible_ce(native_visible_ce),.scan_valid(scan_valid),.scan_underflow(underflow),.scan_busy(scanout_active),.scan_index(scan_index),
        .native_pixel_ce(native_pixel_ce),.native_x(native_x),.native_y(native_y),
        .SDRAM_DQ(SDRAM_DQ),.SDRAM_A(SDRAM_A),.SDRAM_BA(SDRAM_BA),.SDRAM_DQML(SDRAM_DQML),.SDRAM_DQMH(SDRAM_DQMH),
        .SDRAM_nCS(SDRAM_nCS),.SDRAM_nWE(SDRAM_nWE),.SDRAM_nRAS(SDRAM_nRAS),.SDRAM_nCAS(SDRAM_nCAS),.SDRAM_CKE(SDRAM_CKE),.SDRAM_CLK(SDRAM_CLK),
        .DDRAM_BUSY(video_ddr_busy),.DDRAM_BURSTCNT(video_ddr_burst),.DDRAM_ADDR(video_ddr_addr),.DDRAM_DOUT(shared_ddr_dout),.DDRAM_DOUT_READY(video_ddr_ready),
        .DDRAM_RD(video_ddr_rd),.DDRAM_DIN(video_ddr_din),.DDRAM_BE(video_ddr_be),.DDRAM_WE(video_ddr_we),
        .scp_rom_req(),.scp_rom_addr(),.scp_rom_ack(),.scp_rom_rdata(),.sprite_rom_req(),.sprite_rom_addr(),.sprite_rom_ack(),.sprite_rom_rdata(),
        .map_req(),.map_word_addr(),.map_ack(),.map_rdata(),.arena_req(),.arena_write(),.arena_wide(),.arena_addr(),.arena_wdata(),.arena_ack(),.arena_rdata(),
        .surface_req(),.surface_write(),.surface_addr(),.surface_wdata(),.surface_bytes(),.surface_ack(),.surface_rdata());
    always @(posedge ram_clk) begin
        freeze_s1<=freeze_toggle;freeze_s2<=freeze_s1;display_start<=0;
        if(underflow || video_overflow) deadline_fault<=1;
        if(video_done) begin shown_bank<=video_done_bank;have_shown<=1;end
        if(frame_cut) begin
            frame_count<=frame_count+1'b1;
            if(have_shown || video_done) begin
                display_bank<=video_done ? video_done_bank : shown_bank;display_start<=1;
            end
            if(!pause) begin
                vblank_toggle<=!vblank_toggle;
                if(state!=IDLE || !query_ready) deadline_fault<=1;
                // Snapshot only when ready; waiting for the previous render
                // must never hold the game CPU frozen.
                // Wait for a reusable image/palette bank before freezing the
                // CPU. A repeated display frame must not stall game execution.
                if(state==IDLE && query_ready && palette_bank_free) begin request_toggle<=!request_toggle;state<=FREEZE;end
            end
        end
        case(state)
        FREEZE: if(frozen && cut_ready) state<=CUT;
        CUT: if(cut_ack) state<=QUERY;
        QUERY: if(query_ready) begin
            next_bank<=!next_bank;
            release_toggle<=request_toggle;state<=IDLE;
        end
        endcase
        if(reset || !rom_ready) begin
            state<=IDLE;request_toggle<=0;release_toggle<=0;freeze_s1<=0;freeze_s2<=0;
            vblank_toggle<=0;
            next_bank<=0;display_start<=0;display_bank<=0;shown_bank<=0;have_shown<=0;frame_count<=0;deadline_fault<=0;
        end
    end
endmodule
