// Action Hollywood game core: wires lane A (ah_main), B (ah_video), C (ah_sound).
// Single clock domain clk (48 MHz); SDRAM lives outside (ah_sdram) behind the three
// client ports of docs/CONTRACTS.md (req level held until ack pulse; data valid with ack).
module ah_game(
    input         clk, rst, pause,
    input         flip,                // 180-degree presentation flip
    // inputs, active low, MAME layout (P1_P2 @800000, SYSTEM @800002)
    input  [15:0] p1p2_n, system_n,
    // EEPROM (93C46, 64x16) persistence port, framework side
    input   [5:0] nv_addr,
    input  [15:0] nv_din,
    input         nv_we,
    output [15:0] nv_dout,
    // SDRAM client ports
    output        rom_req, output [22:2] rom_addr, input rom_ack, input [31:0] rom_data,
    output        gfx_req, output [22:2] gfx_addr, input gfx_ack, input [31:0] gfx_data,
    output        oki_req, output [22:2] oki_addr, input oki_ack, input [31:0] oki_data,
    // video
    output        ce_pix, hs, vs, hblank, vblank,
    output  [7:0] r, g, b,
    // audio (mono, signed)
    output signed [15:0] audio,
    // debug
    output  [9:0] dbg_x, dbg_y,
    output [32*13-1:0] dbg_words,
    // hiscore (standard hiscore.sv; see rtl/hiscore/ah_hiscore.sv).  HPS bus + OSD, framework side.
    input         hs_osd_status, hs_autosave,
    input         hs_ioctl_download, hs_ioctl_upload, hs_ioctl_wr,
    input   [7:0] hs_ioctl_index,
    input  [26:0] hs_ioctl_addr,
    input  [15:0] hs_ioctl_dout,
    output [15:0] hs_tail_din,
    output        hs_upload_req,
    output        hs_configured
);
wire        vid_cs, vid_ack, vint;
wire [23:1] cpu_addr;
wire [15:0] cpu_dout, vid_dout;
wire        cpu_uds_n, cpu_lds_n, cpu_rw;
wire        snd_we, snd_uds_n, snd_lds_n;
wire [15:0] snd_data;

wire        hs_pause, cpu_paused, hs_ram_rd, hs_ram_wr, hs_ram_ready;
wire [15:0] hs_ram_addr;
wire  [7:0] hs_ram_din, hs_ram_dout;

ah_main main(
    .clk(clk), .rst(rst), .pause(pause),
    .rom_req(rom_req), .rom_addr(rom_addr), .rom_ack(rom_ack), .rom_data(rom_data),
    .vid_cs(vid_cs), .cpu_addr(cpu_addr), .cpu_dout(cpu_dout),
    .cpu_uds_n(cpu_uds_n), .cpu_lds_n(cpu_lds_n), .cpu_rw(cpu_rw),
    .vid_dout(vid_dout), .vid_ack(vid_ack), .vint(vint),
    .snd_we(snd_we), .snd_data(snd_data), .snd_uds_n(snd_uds_n), .snd_lds_n(snd_lds_n),
    .p1p2_n(p1p2_n), .system_n(system_n),
    .nv_addr(nv_addr), .nv_din(nv_din), .nv_we(nv_we), .nv_dout(nv_dout),
    .hs_pause_req(hs_pause), .cpu_paused(cpu_paused),
    .hs_addr(hs_ram_addr), .hs_din(hs_ram_din), .hs_rd(hs_ram_rd), .hs_wr(hs_ram_wr),
    .hs_ready(hs_ram_ready), .hs_dout(hs_ram_dout)
);

ah_hiscore hiscore(
    .clk(clk), .rst(rst), .cpu_paused(cpu_paused), .v_sync(vs),
    .osd_status(hs_osd_status), .autosave(hs_autosave),
    .ioctl_download(hs_ioctl_download), .ioctl_upload(hs_ioctl_upload), .ioctl_wr(hs_ioctl_wr),
    .ioctl_index(hs_ioctl_index), .ioctl_addr(hs_ioctl_addr), .ioctl_dout(hs_ioctl_dout),
    .tail_din(hs_tail_din), .upload_req(hs_upload_req),
    .hs_pause(hs_pause), .ram_addr(hs_ram_addr), .ram_din(hs_ram_din), .ram_dout(hs_ram_dout),
    .ram_rd(hs_ram_rd), .ram_wr(hs_ram_wr), .ram_ready(hs_ram_ready), .configured(hs_configured)
);

ah_video video(
    .clk(clk), .rst(rst),
    .vid_cs(vid_cs), .cpu_addr(cpu_addr), .cpu_din(cpu_dout),
    .cpu_uds_n(cpu_uds_n), .cpu_lds_n(cpu_lds_n), .cpu_rw(cpu_rw),
    .vid_dout(vid_dout), .vid_ack(vid_ack),
    .gfx_req(gfx_req), .gfx_addr(gfx_addr), .gfx_ack(gfx_ack), .gfx_data(gfx_data),
    .vint(vint),
    .ce_pix(ce_pix), .hs(hs), .vs(vs), .hblank(hblank), .vblank(vblank),
    .r(r), .g(g), .b(b),
    .dbg_x(dbg_x), .dbg_y(dbg_y), .flip(flip)
);

ah_dbg dbg(.clk(clk), .rst(rst), .rom_ack(rom_ack), .rom_addr(rom_addr), .rom_data(rom_data),
    .vid_cs(vid_cs), .vid_ack(vid_ack), .cpu_rw(cpu_rw), .cpu_addr(cpu_addr), .vint(vint), .gfx_ack(gfx_ack), .words(dbg_words));

ah_sound sound(
    .clk(clk), .rst(rst), .pause(pause),
    .snd_we(snd_we), .snd_data(snd_data), .snd_uds_n(snd_uds_n), .snd_lds_n(snd_lds_n),
    .oki_req(oki_req), .oki_addr(oki_addr), .oki_ack(oki_ack), .oki_data(oki_data),
    .audio(audio)
);
endmodule
