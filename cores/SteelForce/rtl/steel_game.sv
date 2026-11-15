// Real PCB chips/RAM + scanline GPU/palette/raster, using one board clock.
// External ROM clients are separate here; native SDRAM/download is a later layer.
module steel_game #(parameter MISTER_INPUTS=0, HISCORE_PORT=0, USE_HISCORE=0)(
    input wire clk,reset,pause_cpu,mortalr,cpu_turbo,
    // Native 180-degree flip and CRT sync position (zero = unadjusted raster); see steel_raster.sv.
    input wire video_flip,
    input wire signed [4:0] crt_h_shift,crt_v_shift,
    input wire [15:0] input_word,system_word,
    output wire rom_req,
    output wire [18:0] rom_word_addr,
    input wire rom_ready,
    input wire [15:0] rom_rdata,
    output wire gfx_req,
    output wire [22:0] gfx_addr,
    input wire gfx_ready,
    input wire [63:0] gfx_data,
    input wire [5:0] nv_addr,
    input wire nv_we,
    input wire [15:0] nv_din,
    output wire [15:0] nv_dout,
    output wire [17:0] oki_addr,
    input wire [7:0] oki_data,
    input wire oki_ok,
    output wire signed [13:0] audio,
    output wire audio_sample,
    output wire debug_io_accept,
    output wire [15:0] debug_io_rdata,
    // Passive native diagnostic outputs; no feedback into renderer or memory.
    output wire debug_video_read,
    output wire [16:0] debug_video_word_addr,
    output wire [15:0] debug_video_rdata,
    output wire [23:0] rgb,
    output wire rgb_valid,ce_pixel,hs,vs,hblank,video_vblank,
    output wire [8:0] pixel_x,
    output wire [7:0] pixel_y,
    output wire [31:0] pixel_frame,missed_lines,
    output wire render_start,render_busy,render_done,line_ready,
    output wire [7:0] render_y,
    output wire video_command_valid,
    output wire [15:0] video_command,
    output wire sprite_busy,sprite_which,sprite_active_bank,
    output wire [31:0] frame_number,
    output wire frame_tick,vblank,
    output wire [23:0] debug_cpu_addr,
    output wire [15:0] debug_cpu_wdata,
    output wire [2:0] debug_fc,
    output wire debug_asn,debug_rwn,debug_haltedn,irq_pending,irq_ack,
    output wire mem_valid,mem_write,mem_ready,
    output wire [23:0] mem_addr,
    output wire [15:0] mem_wdata,debug_mem_rdata,
    output wire [1:0] mem_lanes,
    input wire [31:0] joystick_0, joystick_1,
    input wire osd_status, service_button,
    input wire hs_en, hs_write,
    input wire [23:0] hs_addr,
    input wire [7:0] hs_din,
    output wire [7:0] hs_dout,
    input wire ioctl_upload, ioctl_download, ioctl_wr,
    input wire [24:0] ioctl_addr,
    input wire [7:0] ioctl_index, ioctl_din,
    output wire [7:0] ioctl_dout,
    output wire ioctl_upload_req, hs_configured
);
    wire ram_en,sprite_en,render_swap,scan_en;
    wire [16:0] ram_addr;
    wire [15:0] ram_data;
    assign debug_video_read=ram_en;
    assign debug_video_word_addr=ram_addr;
    assign debug_video_rdata=ram_data;
    wire [7:0] sprite_index;
    wire [63:0] sprite_data;
    wire [8:0] scan_x;
    wire [23:0] pixel_rgb;
    wire [15:0] cabinet_input,cabinet_system;
    wire cabinet_pause;
    wire score_pause,score_en,score_write;
    wire [23:0] score_addr;
    wire [7:0] score_din;
    wire board_pause=pause_cpu | (MISTER_INPUTS && cabinet_pause) | score_pause | (USE_HISCORE && osd_status);
    generate if(USE_HISCORE) begin: persistent_scores
        // Pause immediately on OSD opening; let an already-issued sprite DMA
        // finish before the donor captures scores through the shared RAM port.
        steel_hiscore scores(.clk(clk),.reset(reset),.image_reset(1'b0),.paused(board_pause),.osd_status(osd_status && !sprite_busy),
            .ioctl_upload(ioctl_upload),.ioctl_download(ioctl_download),.ioctl_wr(ioctl_wr),
            .ioctl_addr(ioctl_addr),.ioctl_index(ioctl_index),.ioctl_din(ioctl_din),.ioctl_dout(ioctl_dout),
            .ioctl_upload_req(ioctl_upload_req),.configured(hs_configured),.pause_cpu(score_pause),
            .hs_en(score_en),.hs_write(score_write),.hs_addr(score_addr),.hs_din(score_din),.hs_dout(hs_dout));
    end else begin: external_scores
        assign score_pause=0;
        assign score_en=hs_en;assign score_write=hs_write;assign score_addr=hs_addr;assign score_din=hs_din;
        assign ioctl_dout=0;assign ioctl_upload_req=0;assign hs_configured=0;
    end endgenerate
    steel_controls controls(.clk(clk),.reset(reset),.joystick_0(joystick_0),.joystick_1(joystick_1),
        .osd_status(osd_status),.service_button(service_button),.input_word(cabinet_input),
        .system_word(cabinet_system),.pause_cpu(cabinet_pause));
    // Idempotent mirror throughout the held write transaction. It starts at the
    // actual RAM write edge, preserves both byte strobes and defines RGB collisions.
    wire palette_we=mem_valid && mem_write && mem_addr[23:12]==12'h104 && !reset;
    // Scroll/attribute RAM, palette and the displayed sprite buffer are latched once per frame at vblank start (see
    // steel_scroll_shadow): entry to raster line 240. video_vblank is not used because a missed render line also blanks,
    // which would latch mid-frame. One latch for all three keeps sprites and background from the same CPU frame.
    reg vblank_line_q;
    wire vblank_line=pixel_y==8'd240;
    always @(posedge clk) vblank_line_q<=vblank_line;
    wire frame_latch=vblank_line && !vblank_line_q;
    steel_board #(.HISCORE_PORT(HISCORE_PORT || USE_HISCORE)) board(.clk(clk),.reset(reset),
        .pause_cpu(board_pause),.mortalr(mortalr),.cpu_turbo(cpu_turbo),.sprite_latch(frame_latch),.render_busy(render_busy),
        .input_word(MISTER_INPUTS ? cabinet_input : input_word),.system_word(MISTER_INPUTS ? cabinet_system : system_word),
        .rom_req(rom_req),.rom_word_addr(rom_word_addr),.rom_ready(rom_ready),.rom_rdata(rom_rdata),
        .video_en(ram_en),.video_word_addr(ram_addr),.video_rdata(ram_data),
        .nv_addr(nv_addr),.nv_we(nv_we),.nv_din(nv_din),.nv_dout(nv_dout),
        .oki_addr(oki_addr),.oki_data(oki_data),.oki_ok(oki_ok),.audio(audio),.audio_sample(audio_sample),
        .debug_io_accept(debug_io_accept),.debug_io_rdata(debug_io_rdata),
        .video_command_valid(video_command_valid),.video_command(video_command),
        .sprite_en(sprite_en),.sprite_index(sprite_index),.sprite_data(sprite_data),
        .sprite_busy(sprite_busy),.sprite_which(sprite_which),.sprite_active_bank(sprite_active_bank),
        .frame_number(frame_number),.frame_tick(frame_tick),.vblank(vblank),
        .debug_cpu_addr(debug_cpu_addr),.debug_cpu_wdata(debug_cpu_wdata),.debug_fc(debug_fc),
        .debug_asn(debug_asn),.debug_rwn(debug_rwn),.debug_haltedn(debug_haltedn),.irq_pending(irq_pending),.irq_ack(irq_ack),
        .mem_valid(mem_valid),.mem_write(mem_write),.mem_ready(mem_ready),.mem_addr(mem_addr),
        .mem_wdata(mem_wdata),.debug_mem_rdata(debug_mem_rdata),.mem_lanes(mem_lanes),
        .hs_en(score_en),.hs_write(score_write),.hs_addr(score_addr),.hs_din(score_din),.hs_dout(hs_dout));
    steel_video video(.clk(clk),.reset(reset),.mortalr(mortalr),.start(render_start),.swap(render_swap),.frame_latch(frame_latch),.line_y(render_y),
        .busy(render_busy),.done(render_done),.line_ready(line_ready),
        .ram_en(ram_en),.ram_addr(ram_addr),.ram_data(ram_data),
        .sprite_en(sprite_en),.sprite_index(sprite_index),.sprite_data(sprite_data),
        .gfx_req(gfx_req),.gfx_addr(gfx_addr),.gfx_ready(gfx_ready),.gfx_data(gfx_data),
        .palette_we(palette_we),.palette_addr(mem_addr[11:1]),.palette_data(mem_wdata),.palette_lanes(mem_lanes),
        .scan_en(scan_en),.scan_x(scan_x),.scan_index(),.scan_priority(),.rgb_valid(rgb_valid),.rgb(pixel_rgb));
    steel_raster raster(.clk(clk),.reset(reset),.render_busy(render_busy),.line_ready(line_ready),
        .flip(video_flip),.h_shift(crt_h_shift),.v_shift(crt_v_shift),
        .render_start(render_start),.render_swap(render_swap),.render_y(render_y),.scan_en(scan_en),.scan_x(scan_x),
        .ce_pixel(ce_pixel),.hs(hs),.vs(vs),.hblank(hblank),.vblank(video_vblank),
        .pixel_x(pixel_x),.pixel_y(pixel_y),.pixel_frame(pixel_frame),.missed_lines(missed_lines));
    assign rgb=rgb_valid && !hblank && !video_vblank ? pixel_rgb : 24'b0;
endmodule
