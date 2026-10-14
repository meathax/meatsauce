// Real donor V30/COP/CRTC and Zero Team memory map. Video/audio follow separately.
module zero_board_top (
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
    output wire [15:0] bg_data, fg_data, mg_data, text_data, palette_data, sprite_data
);
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
        .vblank_in(vblank), .ioctl_download(1'b0), .snd_rdata(16'hffff),
        .text_vram_addr(video_probe_address), .text_vram_data(text_data),
        .spr_vram_addr(video_probe_address), .spr_vram_data(sprite_data),
        .bg_vram_addr(video_probe_address), .bg_vram_data(bg_data),
        .fg_vram_addr(video_probe_address), .fg_vram_data(fg_data),
        .mg_vram_addr(video_probe_address), .mg_vram_data(mg_data),
        .pal_vram_addr(video_probe_address), .pal_vram_data(palette_data),
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
endmodule
