// Live CPU/COP memory ports feed the actual target RTL video pipeline.
// Real donor V30/COP/CRTC, target video/cipher and sound CPU/chips.
module zero_av_top (
    input wire clk, reset, vblank, pause,
    input wire [7:0] p1, p2, p3, p4,
    input wire [15:0] dips, system_input,
    input wire [15:0] rom_data, cop_rom_data,
    input wire rom_ack, cop_rom_ack,
    output wire [23:0] rom_address, cop_rom_address,
    output wire rom_request, cop_rom_request,
    output wire [19:0] cpu_address,
    output wire [15:0] cpu_write_data,
    output wire cpu_read, cpu_write, irq_ack, cop_busy,
    output wire [1:0] cpu_be,
    output wire [12:0] video_dma_address,
    output wire video_dma_write, palette_dma_write,
    input wire [10:0] video_probe_address,
    input wire [15:0] ram_probe_address,
    output wire [15:0] ram_probe_data,
    output wire [15:0] bg_data, fg_data, mg_data, text_data, palette_data, sprite_data,
    input wire [31:0] av_rom_data,
    input wire av_rom_valid,
    output wire av_rom_request,
    output wire [23:0] av_rom_address,
    output wire [2:0] av_rom_kind,
    output wire av_sprite_request,
    output wire [23:0] av_sprite_address,
    input wire [31:0] av_sprite_data,
    input wire av_sprite_valid,av_sprite_half,
    output wire av_pixel_strobe,av_pixel_display,
    output wire [9:0] av_pixel_x,
    output wire [8:0] av_pixel_y,
    output wire [7:0] av_r,av_g,av_b,
    input wire audio_download,audio_download_wr,
    input wire [26:0] audio_download_addr,
    input wire [15:0] audio_download_data,
    input wire [7:0] coin_input,oki_rom_data,
    input wire oki_rom_ok,
    output wire [17:0] oki_rom_address,
    output wire signed [15:0] audio_l,audio_r,
    output wire audio_sample,
    output wire [15:0] sound_address,
    output wire [7:0] sound_data,sound_din,
    output wire sound_read,sound_write,sound_fetch,sound_iack,
    output wire sound_cen,sound_ym_irq,sound_pending
);
    wire [10:0] render_bg,render_mg,render_fg,render_tx,render_spr,render_pal;
    wire video_vblank;
    wire snd_cs,snd_wr,snd_rd;
    wire [4:1] snd_addr;
    wire [15:0] snd_wdata,snd_rdata;
    ssbus_if ss_workram(), ss_txt(), ss_scroll(), ss_spr(), ss_cpu(), ss_bank();
    ssbus_if ss_copa(), ss_copr(), ss_bg(), ss_fg(), ss_pal(), ss_crtc();
`define IDLE_STATE(s) assign s.data=0; assign s.addr=0; assign s.select=0; assign s.write=0; assign s.read=0; assign s.query=0;
    `IDLE_STATE(ss_workram) `IDLE_STATE(ss_txt) `IDLE_STATE(ss_scroll)
    `IDLE_STATE(ss_spr) `IDLE_STATE(ss_cpu) `IDLE_STATE(ss_bank)
    `IDLE_STATE(ss_copa) `IDLE_STATE(ss_copr) `IDLE_STATE(ss_bg)
    `IDLE_STATE(ss_fg) `IDLE_STATE(ss_pal) `IDLE_STATE(ss_crtc)
`undef IDLE_STATE
    Raiden2_main_top #(.IRQ_HALF_CAPTURE(1)) board (
        .board_dx(1'b0), .clk(clk), .reset(reset), .pause(pause), .clk_sel(3'd0),
        .p1_input(p1), .p2_input(p2), .p3_input(p3), .p4_input(p4),
        .dsw_input(dips), .dsw2_input(16'hffff), .system_input(system_input),
        .main_rom_rdata(rom_data), .main_rom_ready(rom_ack),
        .main_rom_addr(rom_address), .main_rom_req(rom_request),
        .vblank_in(video_vblank), .ioctl_download(1'b0), .snd_rdata(snd_rdata),
        .snd_cs(snd_cs),.snd_addr(snd_addr),.snd_wr(snd_wr),.snd_rd(snd_rd),.snd_wdata(snd_wdata),
        .text_vram_addr(pause ? video_probe_address : render_tx), .text_vram_data(text_data),
        .spr_vram_addr(pause ? video_probe_address : render_spr), .spr_vram_data(sprite_data),
        .bg_vram_addr(pause ? video_probe_address : render_bg), .bg_vram_data(bg_data),
        .fg_vram_addr(pause ? video_probe_address : render_fg), .fg_vram_data(fg_data),
        .mg_vram_addr(pause ? video_probe_address : render_mg), .mg_vram_data(mg_data),
        .pal_vram_addr(pause ? video_probe_address : render_pal), .pal_vram_data(palette_data),
        .ss_bg(ss_bg), .ss_fg(ss_fg), .ss_pal(ss_pal), .ss_crtc(ss_crtc),
        .cop_rom_addr(cop_rom_address), .cop_rom_req(cop_rom_request),
        .cop_rom_rdata(cop_rom_data), .cop_rom_ready(cop_rom_ack), .cop_busy_out(cop_busy),
        .main_shared_rdata(16'hffff), .ss_workram(ss_workram), .ss_txt(ss_txt),
        .ss_scroll(ss_scroll), .ss_spr(ss_spr), .ss_cpu(ss_cpu), .ss_bank(ss_bank),
        .ss_copa(ss_copa), .ss_copr(ss_copr), .ss_cpu_reload(1'b0)
    );
    assign cpu_address = board.cpu_addr;
    assign cpu_write_data = board.cpu_dout;
    assign cpu_read = board.cpu_rd;
    assign cpu_write = board.cpu_wr;
    assign cpu_be = board.cpu_be;
    assign irq_ack = board.cpu_irq_active;
    assign video_dma_address = board.cop_dma_vram_addr_now;
    assign video_dma_write = board.cop_dma_vram_we_now;
    assign palette_dma_write = board.cop_dma_pal_we;
    // Read-only observation of actual RTL work RAM; no state injection.
    assign ram_probe_data = {board.ram_hi[ram_probe_address], board.ram_lo[ram_probe_address]};
    ZeroTeam_audio audio (
        .clk(clk),.reset(reset),.pause(pause),
        .ioctl_download(audio_download),.ioctl_wr(audio_download_wr),
        .ioctl_addr(audio_download_addr),.ioctl_dout(audio_download_data),
        .snd_cs(snd_cs),.snd_addr(snd_addr[3:1]),.snd_wr(snd_wr),.snd_rd(snd_rd),
        .snd_wdata(snd_wdata),.snd_rdata(snd_rdata),.coin_input(coin_input),
        .oki_rom_addr(oki_rom_address),.oki_rom_data(oki_rom_data),.oki_rom_ok(oki_rom_ok),
        .audio_l(audio_l),.audio_r(audio_r),.audio_sample(audio_sample),
        .debug_address(sound_address),.debug_data(sound_data),.debug_din(sound_din),
        .debug_read(sound_read),.debug_write(sound_write),.debug_fetch(sound_fetch),
        .debug_iack(sound_iack),.debug_cen(sound_cen),.debug_ym_irq(sound_ym_irq),.debug_pending(sound_pending)
    );
    ZeroTeam_video video (
        .clk(clk),.reset(reset),
        .layer_enable({board.crtc_layer_en_spr,board.crtc_layer_en_text,
                       board.crtc_layer_en_fg,board.crtc_layer_en_mg,board.crtc_layer_en_bg}),
        .flip_screen(board.crtc_flip_screen),
        .bg_x(board.crtc_scroll_bg_x),.bg_y(board.crtc_scroll_bg_y),
        .mg_x(board.crtc_scroll_mg_x),.mg_y(board.crtc_scroll_mg_y),
        .fg_x(board.crtc_scroll_fg_x),.fg_y(board.crtc_scroll_fg_y),
        .tx_x(16'd0),.tx_y(16'd0), // target MAME scroll dispatcher handles BG/MG/FG only
        .bg_address(render_bg),.mg_address(render_mg),.fg_address(render_fg),
        .tx_address(render_tx),.spr_address(render_spr),.pal_address(render_pal),
        .bg_data(bg_data),.mg_data(mg_data),.fg_data(fg_data),.tx_data(text_data),
        .spr_data(sprite_data),.pal_data(palette_data),
        .rom_request(av_rom_request),.rom_address(av_rom_address),.rom_kind(av_rom_kind),
        .rom_data(av_rom_data),.rom_valid(av_rom_valid),.vblank(video_vblank),
        .sprite_rom_request(av_sprite_request),.sprite_rom_address(av_sprite_address),
        .sprite_rom_data(av_sprite_data),.sprite_rom_valid(av_sprite_valid),
        .sprite_rom_half(av_sprite_half),
        .pixel_strobe(av_pixel_strobe),.pixel_display(av_pixel_display),
        .pixel_x(av_pixel_x),.pixel_y(av_pixel_y),.r(av_r),.g(av_g),.b(av_b)
    );
endmodule
