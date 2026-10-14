// Focused real RTL checks. Work-RAM fixture is test stimulus, not gameplay proof.
module zero_platform_checks (
    input wire clk,reset,
    input wire download,wr,
    input wire [15:0] index,
    input wire [26:0] address,
    input wire [7:0] data,
    output wire wait_hps,download_busy,
    input wire ready,gfx_req,main_req,cop_req,
    input wire [23:0] gfx_address,main_address,cop_address,
    input wire [2:0] gfx_kind,
    output wire [31:0] gfx_data,
    output wire gfx_valid,main_valid,cop_valid,
    output wire [15:0] main_data,cop_data,
    input wire [17:0] oki_address,
    output wire [7:0] oki_data,
    output wire oki_valid,
    output wire [23:0] addr0,addr1,addr2,addr3,
    output wire [15:0] din0,
    output wire we0,req0,req1,req2,req3,
    output wire [1:0] len0,
    input wire ack0,ack1,ack2,ack3,beat0,
    input wire spr_req,
    input wire [23:0] spr_address,
    output wire [31:0] spr_data,
    output wire spr_valid,spr_half,
    input wire [15:0] dout0,dout1,dout2,dout3,
    output wire ce_pixel,hblank,vblank,hsync,vsync,de,
    output wire [9:0] hpos,vpos,
    input wire mode_60hz,
    input wire hs_reset,hs_osd,hs_upload,hs_paused,
    output wire hs_upload_req,hs_pause,hs_configured,
    output wire [7:0] hs_upload_data,
    input wire test_ram_access,test_ram_write,
    input wire [16:0] test_ram_address,
    input wire [7:0] test_ram_data,
    output wire [7:0] test_ram_q,
    input wire rotation_write,rotation_busy,
    input wire [28:0] rotation_address,
    input wire [63:0] rotation_data,
    input wire [7:0] rotation_be,
    output wire [28:0] ddr_address,
    output wire [63:0] ddr_data,
    output wire [7:0] ddr_be,
    output wire ddr_write,rotation_overflow
);
    wire word_wr,memory_wait;
    wire [26:0] word_address;
    wire [15:0] word_data;
    ZeroTeam_download loader(.clk(clk),.reset(reset),.download(download),.wr(wr),
        .index(index),.address(address),.data(data),.memory_wait(memory_wait),
        .wait_hps(wait_hps),.word_wr(word_wr),.word_address(word_address),.word_data(word_data));
    ZeroTeam_rom_bridge roms(.clk(clk),.reset(reset),.ready(ready),.download(download && index==0),
        .word_wr(word_wr),.word_address(word_address),.word_data(word_data),
        .download_wait(memory_wait),.download_busy(download_busy),
        .gfx_req(gfx_req),.gfx_address(gfx_address),.gfx_kind(gfx_kind),.gfx_data(gfx_data),.gfx_valid(gfx_valid),
        .spr_req(spr_req),.spr_address(spr_address),.spr_data(spr_data),.spr_valid(spr_valid),.spr_half(spr_half),
        .len0(len0),.beat0(beat0),
        .main_req(main_req),.main_address(main_address),.main_data(main_data),.main_valid(main_valid),
        .cop_req(cop_req),.cop_address(cop_address),.cop_data(cop_data),.cop_valid(cop_valid),
        .oki_address(oki_address),.oki_data(oki_data),.oki_valid(oki_valid),
        .addr0(addr0),.addr1(addr1),.addr2(addr2),.addr3(addr3),.din0(din0),.we0(we0),
        .req0(req0),.req1(req1),.req2(req2),.req3(req3),.ack0(ack0),.ack1(ack1),.ack2(ack2),.ack3(ack3),
        .dout0(dout0),.dout1(dout1),.dout2(dout2),.dout3(dout3));
    Raiden2_video_timing timing(.clk(clk),.reset(reset),.mode_60hz(mode_60hz),.ce_pix(ce_pixel),
        .hpos(hpos),.vpos(vpos),.hblank(hblank),.vblank(vblank),.hsync(hsync),.vsync(vsync),.de(de));
    ZeroTeam_rotation rotation(.clk(clk),.reset(reset),.address(rotation_address),.data(rotation_data),
        .be(rotation_be),.write_pixel(rotation_write),.busy(rotation_busy),
        .ddr_address(ddr_address),.ddr_data(ddr_data),.ddr_be(ddr_be),.ddr_write(ddr_write),.overflow(rotation_overflow));
    wire hs_read,hs_write,hs_intent_write;
    wire [16:0] hs_address;
    wire [7:0] hs_in,hs_out;
    hiscore #(.HS_ADDRESSWIDTH(17),.HS_SCOREWIDTH(7),.CFG_ADDRESSWIDTH(2),.RAM_READ_PIPELINED(1)) scores (
        .clk(clk),.reset(hs_reset),.paused(hs_paused),.autosave(1'b1),
        .ioctl_upload(hs_upload),.ioctl_upload_req(hs_upload_req),.ioctl_download(download),
        .ioctl_wr(wr),.ioctl_addr(address[24:0]),.ioctl_index(index[7:0]),.OSD_STATUS(hs_osd),
        .data_from_hps(data),.data_to_hps(hs_upload_data),.data_from_ram(hs_out),
        .ram_address(hs_address),.data_to_ram(hs_in),.ram_write(hs_write),
        .ram_intent_read(hs_read),.ram_intent_write(hs_intent_write),.pause_cpu(hs_pause),.configured(hs_configured));
    ssbus_if ss_workram(),ss_txt(),ss_scroll(),ss_spr(),ss_cpu(),ss_bank();
    ssbus_if ss_copa(),ss_copr(),ss_bg(),ss_fg(),ss_pal(),ss_crtc();
`define TEST_IDLE(s) assign s.data=0;assign s.addr=0;assign s.select=0;assign s.write=0;assign s.read=0;assign s.query=0;
    `TEST_IDLE(ss_workram) `TEST_IDLE(ss_txt) `TEST_IDLE(ss_scroll) `TEST_IDLE(ss_spr)
    `TEST_IDLE(ss_cpu) `TEST_IDLE(ss_bank) `TEST_IDLE(ss_copa) `TEST_IDLE(ss_copr)
    `TEST_IDLE(ss_bg) `TEST_IDLE(ss_fg) `TEST_IDLE(ss_pal) `TEST_IDLE(ss_crtc)
`undef TEST_IDLE
    Raiden2_main_top #(.HS_ENABLED(1)) board (
        .clk(clk),.reset(1'b1),.pause(hs_paused || test_ram_access),.board_dx(1'b0),.clk_sel(3'd0),
        .hs_access(test_ram_access || ((hs_read || hs_intent_write) && hs_paused)),
        .hs_write(test_ram_access ? test_ram_write : hs_write),
        .hs_address(test_ram_access ? test_ram_address : hs_address),
        .hs_data_in(test_ram_access ? test_ram_data : hs_in),.hs_data_out(test_ram_q),
        .p1_input(8'hff),.p2_input(8'hff),.p3_input(8'hff),.p4_input(8'hff),
        .dsw_input(16'hffff),.dsw2_input(16'hffff),.system_input(16'hffff),
        .main_rom_rdata(16'hffff),.main_rom_ready(1'b0),.vblank_in(1'b0),.ioctl_download(1'b0),
        .snd_rdata(16'hffff),.text_vram_addr(11'd0),.spr_vram_addr(11'd0),
        .bg_vram_addr(11'd0),.mg_vram_addr(11'd0),.fg_vram_addr(11'd0),.pal_vram_addr(11'd0),
        .cop_rom_rdata(16'hffff),.cop_rom_ready(1'b0),.main_shared_rdata(16'hffff),
        .ss_bg(ss_bg),.ss_fg(ss_fg),.ss_pal(ss_pal),.ss_crtc(ss_crtc),
        .ss_workram(ss_workram),.ss_txt(ss_txt),.ss_scroll(ss_scroll),.ss_spr(ss_spr),
        .ss_cpu(ss_cpu),.ss_bank(ss_bank),.ss_copa(ss_copa),.ss_copr(ss_copr),.ss_cpu_reload(1'b0));
    assign hs_out=test_ram_q;
endmodule
