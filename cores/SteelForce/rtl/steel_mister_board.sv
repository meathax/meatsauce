// SPDX-License-Identifier: GPL-3.0-or-later
// Production board transport boundary. Power reset and CPU reset are distinct:
// soft resets preserve the admitted ROM and EEPROM, while image changes erase
// the EEPROM before the MRA factory/default/saved image is loaded at index 2.
module steel_mister_board(
    input wire clk,power_reset,game_reset,boot_hold,mortalr,pause_cpu,cpu_turbo,
    // OSD "Flip screen" and CRT sync position (steel_raster.sv); the board itself has no flip register.
    input wire flip_screen,
    input wire signed [4:0] crt_h_shift,crt_v_shift,
    input wire [31:0] joystick_0,joystick_1,
    input wire osd_status,service_button,nv_autosave,nv_save_button,
    input wire ioctl_download,ioctl_upload,ioctl_wr,ioctl_rd,
    input wire [15:0] ioctl_index,
    input wire [26:0] ioctl_addr,
    input wire [7:0] ioctl_din,
    output wire [7:0] ioctl_dout,
    output wire ioctl_wait,ioctl_upload_req,
    output wire [7:0] ioctl_upload_index,
    output wire [23:0] rgb,
    output wire ce_pixel,hs,vs,hblank,vblank,
    output wire signed [13:0] audio,
    output wire audio_sample,
    output wire image_valid,image_mortalr,download_active,storage_error,
    output wire nv_initialized,nv_dirty,nv_error,hs_configured,
    output wire [31:0] missed_lines,
    output wire [12:0] sdram_address,
    output wire [1:0] sdram_bank,sdram_dqm,
    output wire sdram_cs_n,sdram_ras_n,sdram_cas_n,sdram_we_n,sdram_drive,
    output wire [15:0] sdram_data_out,
    input wire [15:0] sdram_data_in
);
    wire raw_download=ioctl_download && ioctl_index==0;
    reg raw_last=0;
    always @(posedge clk)begin
        if(power_reset)raw_last<=0;else raw_last<=raw_download;
    end
    wire new_image=raw_download && !raw_last;
    wire persist_hold,persist_pause,persist_wait,persist_upload_req;
    wire [7:0] persist_dout;
    wire [5:0] nv_addr;
    wire nv_we;
    wire [15:0] nv_din,nv_dout;
    wire rom_wait,fabric_error;
    wire score_en,score_write,sprite_busy;
    wire [23:0] score_addr;
    wire [7:0] score_din,score_dout;
    // The OSD does not pause the game (user request 2026-10-15); saves take their own short capture pause.
    wire external_pause=pause_cpu || persist_pause;
    steel_persistence persistence(.clk(clk),.reset(power_reset),.new_image(new_image),
        .mortalr(image_mortalr),.cpu_reset(board_reset),.paused(external_pause),
        .osd_status(osd_status),.sprite_busy(sprite_busy),.autosave(nv_autosave),.save_button(nv_save_button),
        .ioctl_download(ioctl_download),.ioctl_upload(ioctl_upload),.ioctl_wr(ioctl_wr),.ioctl_rd(ioctl_rd),
        .ioctl_index(ioctl_index),.ioctl_addr(ioctl_addr),.ioctl_din(ioctl_din),.ioctl_dout(persist_dout),
        .ioctl_wait(persist_wait),.ioctl_upload_req(persist_upload_req),.cpu_hold(persist_hold),
        .pause_request(persist_pause),.initialized(nv_initialized),.dirty(nv_dirty),.error(nv_error),
        .hs_configured(hs_configured),.nv_addr(nv_addr),.nv_we(nv_we),.nv_din(nv_din),.nv_dout(nv_dout),
        .hs_en(score_en),.hs_write(score_write),.hs_addr(score_addr),.hs_din(score_din),.hs_dout(score_dout));
    reg address_error=0;
    always @(posedge clk)begin
        if(power_reset || new_image)address_error<=0;
        else if(raw_download && ioctl_wr && ioctl_addr[26:25]!=0)address_error<=1;
    end
    assign storage_error=fabric_error || address_error;
    wire rom_req,rom_ready,gfx_req,gfx_ready,oki_ok;
    wire [18:0] rom_word_addr;
    wire [15:0] rom_data;
    wire [22:0] gfx_addr;
    wire [63:0] gfx_data;
    wire [17:0] oki_addr;
    wire [7:0] oki_data;
    wire board_reset=power_reset || game_reset || boot_hold || !image_valid || download_active || persist_hold || storage_error;

    steel_memory_fabric memory(.clk(clk),.reset(power_reset),.mortalr(mortalr),
        .ioctl_download(ioctl_download),.ioctl_wr(ioctl_wr && ioctl_addr[26:25]==0),.ioctl_index(ioctl_index),
        .ioctl_addr(ioctl_addr[24:0]),.ioctl_din(ioctl_din),.ioctl_wait(rom_wait),
        .image_valid(image_valid),.image_mortalr(image_mortalr),
        .download_active(download_active),.error(fabric_error),
        .cpu_request(rom_req),.cpu_word_address(rom_word_addr),.cpu_ready(rom_ready),.cpu_data(rom_data),
        .gfx_request(gfx_req),.gfx_address(gfx_addr),.gfx_ready(gfx_ready),.gfx_data(gfx_data),
        .oki_address(oki_addr),.oki_ready(oki_ok),.oki_data(oki_data),
        .cpu_hits(),.cpu_misses(),.gfx_hits(),.gfx_misses(),.oki_hits(),.oki_misses(),
        .sdram_address(sdram_address),.sdram_bank(sdram_bank),.sdram_dqm(sdram_dqm),
        .sdram_cs_n(sdram_cs_n),.sdram_ras_n(sdram_ras_n),.sdram_cas_n(sdram_cas_n),
        .sdram_we_n(sdram_we_n),.sdram_drive(sdram_drive),
        .sdram_data_out(sdram_data_out),.sdram_data_in(sdram_data_in));
    // One native flip: the game's own flip (none on this board: MAME stlforce/edevices have no flip_screen,
    // only per-sprite flipx) XOR the OSD option.
    localparam GAME_FLIP=1'b0;
    wire video_flip=flip_screen ^ GAME_FLIP;
    steel_game #(.MISTER_INPUTS(1),.HISCORE_PORT(1)) game(
        .clk(clk),.reset(board_reset),.pause_cpu(external_pause),.mortalr(image_mortalr),.cpu_turbo(cpu_turbo),
        .video_flip(video_flip),.crt_h_shift(crt_h_shift),.crt_v_shift(crt_v_shift),
        .input_word(16'hffff),.system_word(16'hffff),.rom_req(rom_req),.rom_word_addr(rom_word_addr),
        .rom_ready(rom_ready),.rom_rdata(rom_data),.gfx_req(gfx_req),.gfx_addr(gfx_addr),
        .gfx_ready(gfx_ready),.gfx_data(gfx_data),.nv_addr(nv_addr),.nv_we(nv_we),.nv_din(nv_din),.nv_dout(nv_dout),
        .oki_addr(oki_addr),.oki_data(oki_data),.oki_ok(oki_ok),.audio(audio),.audio_sample(audio_sample),
        .rgb(rgb),.rgb_valid(),.ce_pixel(ce_pixel),.hs(hs),.vs(vs),.hblank(hblank),.video_vblank(vblank),
        .missed_lines(missed_lines),.sprite_busy(sprite_busy),.joystick_0(joystick_0),.joystick_1(joystick_1),
        .osd_status(osd_status),.service_button(service_button),
        .hs_en(score_en && !image_mortalr),.hs_write(score_write && !image_mortalr),
        .hs_addr(score_addr),.hs_din(score_din),.hs_dout(score_dout),
        .ioctl_upload(1'b0),.ioctl_download(1'b0),.ioctl_wr(1'b0),.ioctl_addr(25'b0),
        .ioctl_index(8'b0),.ioctl_din(8'b0),.ioctl_dout(),.ioctl_upload_req(),.hs_configured());
`ifdef STEEL_HWDIAG
    // Diagnostic builds only: the index-2 upload returns the steel_hwdiag record.
    wire [7:0] diag_dout;
    wire diag_upload_req;
    steel_hwdiag hwdiag(.clk(clk),.reset(power_reset),.board_reset(board_reset),.osd_status(osd_status),
        .flags({image_valid,boot_hold,storage_error,nv_error,download_active,persist_hold,board_reset,external_pause}),
        .rom_req(rom_req),.rom_ready(rom_ready),.rom_word_addr(rom_word_addr),.rom_data(rom_data),
        .gfx_req(gfx_req),.gfx_ready(gfx_ready),.gfx_addr(gfx_addr),.gfx_data(gfx_data),.vs(vs),
        .ioctl_addr(ioctl_addr),.dout(diag_dout),.upload_req(diag_upload_req),
        .ioctl_upload(ioctl_upload && ioctl_index==2));
    assign ioctl_dout=ioctl_index==2 ? diag_dout : persist_dout;
    assign ioctl_upload_req=persist_upload_req || diag_upload_req;
`else
    assign ioctl_dout=persist_dout;
    assign ioctl_upload_req=persist_upload_req;
`endif
    assign ioctl_upload_index=8'd2;
    assign ioctl_wait=persist_wait || (ioctl_index==0 && rom_wait);
endmodule
