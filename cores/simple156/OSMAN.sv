//============================================================================
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//
//  This program is distributed in the hope that it will be useful, but WITHOUT
//  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
//  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
//  more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//
//============================================================================

module emu (
    `include "sys/emu_ports.vh"
);
    `include "build_id.v"
    localparam CONF_STR = {
    "OSMAN;;",
    "O[1],Pause,Off,On;",
    "O[2],Pause when OSD open,On,Off;",
    "O[3],Autosave scores,On,Off;",
    "O[4],Rotate 180,Off,On;",
    "T[5],Service credit;",
    "O[6],Service test,Off,On;",
    "-;",
    "P1,Video & CRT;",
    "H0P1O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
    "H0P1O[19:17],Scale,Normal,V-Integer,HV-Integer-,HV-Integer+,HV-Integer;",
    "H0P1O[20],Crop to 224 lines,Off,On;",
    "H0P1O[49:48],Rotation,None,90 CW,90 CCW;",
    "P1O[14:12],Scandoubler FX,None,HQ2x,CRT25%,CRT50%,CRT75%;",
    "P1O[32],CRT Adjust,Off,On;",
    "H2P1O[42:38],CRT H-Position,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
    "H2P1O[47:43],CRT V-Position,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
    "H2P1O[37:33],CRT H-Size,0,+1,+2,+3,+4,+5,+6,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
    "-;",
    "O[25:24],SFX volume,100%,50%,25%,Off;",
    "O[27:26],Music volume,100%,50%,25%,Off;",
    "O[28],Audio filter,On,Off;",
    "-;",
    "R[120],Credits;",
    "T[0],Reset;",
    "R[0],Reset and close OSD;",
    // J1 must stay AFTER every menu item: the OSD select handler counts any line
    // starting at or above "A" as an entry, so a leading J1 shifts every
    // main-page selection up by one row.
    "J1,Attack,Jump,Special,Start,Coin,Pause,Service,Test;",
    "v,1;",
        "V,v",`BUILD_DATE
    };
    wire clk_sys,clk_sdram,pll_locked;
    pll pll (.refclk(CLK_50M),.rst(1'b0),.outclk_0(clk_sys),.outclk_1(clk_sdram),.locked(pll_locked));
    wire global_reset = RESET || !pll_locked;
    wire [127:0] status;
    wire [1:0] buttons;
    wire [31:0] joystick_0,joystick_1,joystick_2,joystick_3,joystick_4,joystick_5;
    wire [24:0] ps2_mouse;
    wire [15:0] analog_0,analog_1;
    wire [10:0] ps2_key;
    wire forced_scandoubler,direct_video,osd_open;
    assign osd_open=OSD_STATUS;
    wire [21:0] gamma_bus;
    wire hps_download,hps_wr,hps_wait;
    wire [26:0] hps_addr;
    wire [15:0] hps_index;
    wire [7:0] hps_dout;
    wire ioctl_download,ioctl_upload,ioctl_wr,ioctl_wait,ioctl_upload_req;
    wire [26:0] ioctl_addr;
    wire [15:0] ioctl_index;
    wire [7:0] ioctl_dout,ioctl_din;
    wire [35:0] hps_extension;
    hps_io #(.CONF_STR(CONF_STR),.WIDE(0)) u_hps (
        .clk_sys(clk_sys),.HPS_BUS(HPS_BUS),.EXT_BUS(hps_extension),.gamma_bus(gamma_bus),
        .forced_scandoubler(forced_scandoubler),.direct_video(direct_video),
        .buttons(buttons),.status(status),.status_menumask({13'd0,!status[32],1'b0,direct_video}),
        .joystick_0(joystick_0),.joystick_1(joystick_1),
        .joystick_2(joystick_2),.joystick_3(joystick_3),
        .joystick_4(joystick_4),.joystick_5(joystick_5),.ps2_mouse(ps2_mouse),
        .joystick_l_analog_0(analog_0),.joystick_l_analog_1(analog_1),.ps2_key(ps2_key),
        .ioctl_download(hps_download),.ioctl_upload(ioctl_upload),.ioctl_wr(hps_wr),
        .ioctl_addr(hps_addr),.ioctl_index(hps_index),.ioctl_dout(hps_dout),.ioctl_din(ioctl_din),
        .ioctl_wait(hps_wait),.ioctl_upload_req(ioctl_upload_req),.ioctl_upload_index(8'd4)
    );
    // The MRA loads ROM index 0 through DDR3 (Main copies it in one memcpy);
    // this replays it into the byte loader. A byte-stream download passes through.
    wire rom_ddr_rd;
    wire [28:0] rom_ddr_addr;
    wire rot_ddr_we;
    wire [28:0] rot_ddr_addr;
    wire [63:0] rot_ddr_din;
    wire [7:0] rot_ddr_be,rot_ddr_burstcnt;
    osman_ddr_rom u_ddr_rom (
        .clk(clk_sys),.reset(global_reset),
        .hps_download(hps_download),.hps_wr(hps_wr),.hps_index(hps_index),.hps_addr(hps_addr),.hps_dout(hps_dout),.hps_wait(hps_wait),
        .download(ioctl_download),.wr(ioctl_wr),.index(ioctl_index),.addr(ioctl_addr),.dout(ioctl_dout),
        .core_wait(ioctl_wait),.image_ready(image_ready),.load_error(load_error),
        .ddr_busy(DDRAM_BUSY),.ddr_rd(rom_ddr_rd),.ddr_addr(rom_ddr_addr),.ddr_dout(DDRAM_DOUT),.ddr_dout_ready(DDRAM_DOUT_READY)
    );
    wire game_reset = status[0] || buttons[1];
`ifdef VERILATOR
    // JTFRAME splits write data from its input-only DQ port in Verilator.
    // Recreate the physical write driver for board-level emu simulations.
    wire [15:0] sim_sdram_write_data;
    assign SDRAM_DQ = !SDRAM_nCS && SDRAM_nRAS && !SDRAM_nCAS && !SDRAM_nWE
                    ? sim_sdram_write_data : 16'hzzzz;
`endif
    wire paused,core_reset,load_error,reset_release;
    wire ce_native,native_de,native_hs,native_vs;
    wire [8:0] native_x;
    wire [7:0] native_y,native_r,native_g,native_b;
    wire game_video_ce,game_video_de,game_video_hs,game_video_vs;
    wire [8:0] game_video_x;
    wire [7:0] game_video_y,game_video_r,game_video_g,game_video_b;
    wire signed [15:0] core_audio;
    wire image_ready,initialized,nvram_ready,commit_valid,commit_we;
    wire [7:0] profile;
    wire [3:0] load_error_reason;
    wire [23:0] accepted_words,memory_writes;
    wire [25:0] commit_addr;
    wire [31:0] commit_data,raster_frame;
    osman_machine u_machine (
        .clk(clk_sys),.global_reset(global_reset),.game_reset(game_reset),.reset_release(reset_release),
        .joystick_0(joystick_0),.joystick_1(joystick_1),.analog_0(analog_0),.analog_1(analog_1),.ps2_key(ps2_key),
        .menu_pause(status[1]),.pause_osd(!status[2]),.menu_service(status[5]),.menu_test(status[6]),
        .osd_open(osd_open),.autosave(!status[3]),.global_flip(status[4]),.sfx_level(status[25:24]),.music_level(status[27:26]),.audio_filter(!status[28]),
        .ioctl_download(ioctl_download),.ioctl_upload(ioctl_upload),.ioctl_wr(ioctl_wr),
        .ioctl_addr(ioctl_addr),.ioctl_index(ioctl_index),.ioctl_dout(ioctl_dout),.ioctl_din(ioctl_din),
        .ioctl_wait(ioctl_wait),.ioctl_upload_req(ioctl_upload_req),.core_reset(core_reset),.load_error(load_error),.paused(paused),
        .image_ready(image_ready),.initialized(initialized),.nvram_ready(nvram_ready),.profile(profile),
        .load_error_reason(load_error_reason),.accepted_words(accepted_words),.memory_writes(memory_writes),
        .commit_valid(commit_valid),.commit_we(commit_we),.commit_addr(commit_addr),.commit_data(commit_data),.raster_frame(raster_frame),
        .video_ce(game_video_ce),.video_de(game_video_de),.video_hs(game_video_hs),.video_vs(game_video_vs),.video_x(game_video_x),.video_y(game_video_y),
        .red(game_video_r),.green(game_video_g),.blue(game_video_b),.audio(core_audio),
        .state_addr(26'd0),.cpu_state_index(5'd0),
        .sdram_dq(SDRAM_DQ),
`ifdef VERILATOR
        .sdram_din(sim_sdram_write_data),
`endif
        .sdram_a(SDRAM_A),.sdram_ba(SDRAM_BA),
        .sdram_dqml(SDRAM_DQML),.sdram_dqmh(SDRAM_DQMH),.sdram_nwe(SDRAM_nWE),
        .sdram_ncas(SDRAM_nCAS),.sdram_nras(SDRAM_nRAS),.sdram_ncs(SDRAM_nCS),.sdram_cke(SDRAM_CKE)
    );
    // The SDRAM chip clock must lag clk_sys so commands meet tIS/tIH and CL2
    // data reaches jtframe_sdram64's capture edge (DST=READ+2). Forwarded
    // through a DDIO cell, a constrained STA phase sweep of this interface
    // gave a 3.47..8.40 ns lag window at 45.6 MHz. The upper (read capture)
    // bound moves with the period, so at 48.82 MHz it is ~3.47..6.96 ns;
    // 5215 ps (~92 deg) is centred.
    // 0 deg (plain assign) races the command bus; 180 deg misses read capture.
    altddio_out #(
        .extend_oe_disable("OFF"),.intended_device_family("Cyclone V"),.invert_output("OFF"),
        .lpm_hint("UNUSED"),.lpm_type("altddio_out"),.oe_reg("UNREGISTERED"),
        .power_up_high("OFF"),.width(1)
    ) u_sdram_clk (
        .datain_h(1'b1),.datain_l(1'b0),.outclock(clk_sdram),.dataout(SDRAM_CLK),
        .aclr(1'b0),.aset(1'b0),.oe(1'b1),.outclocken(1'b1),.sclr(1'b0),.sset(1'b0)
    );
    osman_startup_probe u_startup_probe (
        .clk(clk_sys),.global_reset(global_reset),.ext_bus(hps_extension),
        .flags({load_error_reason,ioctl_wait,ioctl_upload,ioctl_download,pll_locked,
                game_reset,global_reset,osd_open,paused,nvram_ready,initialized,image_ready,core_reset}),
        .profile(profile),.ioctl_index(ioctl_index),.ioctl_addr(ioctl_addr),
        .accepted_words(accepted_words),.memory_writes(memory_writes),
        .commit_valid(commit_valid),.commit_addr(commit_addr),.commit_data(commit_data),.raster_frame(raster_frame)
    );
    osman_boot_video u_boot_video (
        .clk(clk_sys),.reset(global_reset),.boot(core_reset),
        .game_ce(game_video_ce),.game_de(game_video_de),.game_hs(game_video_hs),.game_vs(game_video_vs),
        .game_x(game_video_x),.game_y(game_video_y),.game_r(game_video_r),.game_g(game_video_g),.game_b(game_video_b),
        .ce(ce_native),.de(native_de),.hs(native_hs),.vs(native_vs),
        .x(native_x),.y(native_y),.r(native_r),.g(native_g),.b(native_b),.release_point(reset_release)
    );
    // Credits use the fixed 320x240 native raster before CRT resampling.
    // Bit 120 is a close-OSD action, independent of reset and gameplay settings.
    wire credits_active,credits_de,credits_hs,credits_vs,credits_hb,credits_vb;
    wire [7:0] credits_r,credits_g,credits_b;
    wire credits_dismiss = |(joystick_0 | joystick_1 | joystick_2 |
                              joystick_3 | joystick_4 | joystick_5) |
                           |buttons | ps2_key[9] | |ps2_mouse[2:0] | osd_open;
    credits_overlay #(.WIDTH(320),.HEIGHT(240),.SCALE_LOG2(0),.SCROLL_FRAMES(4)) u_credits (
        .clk_video(clk_sys),.reset(global_reset),.ce_pixel(ce_native),
        .menu_trigger(status[120]),.dismiss(credits_dismiss),
        .r_in(native_r),.g_in(native_g),.b_in(native_b),.hs_in(native_hs),.vs_in(native_vs),
        .hblank_in(native_x >= 9'd320),.vblank_in(native_y < 8'd8 || native_y >= 8'd248),
        .r_out(credits_r),.g_out(credits_g),.b_out(credits_b),.hs_out(credits_hs),.vs_out(credits_vs),
        .hblank_out(credits_hb),.vblank_out(credits_vb),.de_out(credits_de),.active(credits_active)
    );
    // CRT Adjust derives blanking from coordinates: delay them with RGB/sync.
    reg [8:0] credits_x_pipe [0:2];
    reg [7:0] credits_y_pipe [0:2];
    integer credits_stage;
    always @(posedge clk_sys) begin
        if (global_reset) begin
            for (credits_stage=0;credits_stage<3;credits_stage=credits_stage+1) begin
                credits_x_pipe[credits_stage] <= 9'd320;
                credits_y_pipe[credits_stage] <= 8'd248;
            end
        end else if (ce_native) begin
            credits_x_pipe[0] <= native_x; credits_y_pipe[0] <= native_y;
            credits_x_pipe[1] <= credits_x_pipe[0]; credits_y_pipe[1] <= credits_y_pipe[0];
            credits_x_pipe[2] <= credits_x_pipe[1]; credits_y_pipe[2] <= credits_y_pipe[1];
        end
    end
    wire adjust_ce,adjust_de,adjust_hs,adjust_vs,adjust_hb,adjust_vb;
    wire [7:0] adjust_r,adjust_g,adjust_b;
    // CRT Adjust applies in every analog route, direct video included: the native
    // 320 px span is ~39 us, so 15 kHz CRTs need H-Size to fill the tube. Sync
    // and line/frame periods stay native; only the read CE cadence changes.
    // OSD H-Size codes 0..6 are 0..+6 and codes 7..16 are -10..-1 (the usable range).
    wire [4:0] crt_hsize_code = status[37:33];
    wire signed [4:0] crt_hsize = crt_hsize_code <= 5'd6 ? $signed(crt_hsize_code) :
                                  crt_hsize_code <= 5'd16 ? $signed(crt_hsize_code - 5'd17) : 5'sd0;
    wire signed [4:0] crt_hposition = status[42:38];
    wire signed [4:0] crt_vposition = status[47:43];
    osman_geometry u_geometry (
        .clk(clk_sys),.reset(global_reset),.ce_in(ce_native),.active(status[32]),
        .hsize(crt_hsize),.hposition(crt_hposition),.vposition(crt_vposition),
        .red_in(credits_r),.green_in(credits_g),.blue_in(credits_b),.hs_in(credits_hs),.vs_in(credits_vs),.de_in(credits_de),
        .x(credits_x_pipe[2]),.y(credits_y_pipe[2]),.ce_out(adjust_ce),.de_out(adjust_de),.hs_out(adjust_hs),.vs_out(adjust_vs),
        .hblank_out(adjust_hb),.vblank_out(adjust_vb),.red_out(adjust_r),.green_out(adjust_g),.blue_out(adjust_b)
    );
    wire mixed_de;
    arcade_video #(.WIDTH(320),.DW(24)) u_arcade_video (
        .clk_video(clk_sys),.ce_pix(adjust_ce),.RGB_in({adjust_r,adjust_g,adjust_b}),
        .HBlank(adjust_hb),.VBlank(adjust_vb),.HSync(adjust_hs),.VSync(adjust_vs),
        .CLK_VIDEO(CLK_VIDEO),.CE_PIXEL(CE_PIXEL),.VGA_R(VGA_R),.VGA_G(VGA_G),.VGA_B(VGA_B),
        .VGA_HS(VGA_HS),.VGA_VS(VGA_VS),.VGA_DE(mixed_de),.VGA_SL(VGA_SL),
        .fx(status[14:12]),.forced_scandoubler(forced_scandoubler),.gamma_bus(gamma_bus)
    );
    wire [1:0] aspect = direct_video ? 2'd0 : status[122:121];
    wire rotate_en = !direct_video && (status[49:48]==2'd1 || status[49:48]==2'd2);
    wire [12:0] native_arx,native_ary,rotated_arx,rotated_ary;
    video_freak u_video_freak (
        .CLK_VIDEO(CLK_VIDEO),.CE_PIXEL(CE_PIXEL),.VGA_VS(VGA_VS),.HDMI_WIDTH(HDMI_WIDTH),.HDMI_HEIGHT(HDMI_HEIGHT),
        .VGA_DE_IN(mixed_de),.VGA_DE(VGA_DE),.VIDEO_ARX(native_arx),.VIDEO_ARY(native_ary),
        .ARX(!aspect?12'd4:{10'd0,aspect}-12'd1),.ARY(!aspect?12'd3:12'd0),
        .CROP_SIZE(!direct_video && status[20]?12'd224:12'd0),.CROP_OFF(5'd0),
        .SCALE(direct_video || rotate_en?3'd0:status[19:17])
    );
    // Compute integer scaling from the rotated dimensions, after native crop.
    // ARY=0 denotes a framework custom aspect index; preserve that encoding.
    video_scale_int u_rotated_scale (
        .CLK_VIDEO(CLK_VIDEO),.HDMI_WIDTH(HDMI_WIDTH),.HDMI_HEIGHT(HDMI_HEIGHT),
        .SCALE(rotate_en?status[19:17]:3'd0),.hsize(FB_WIDTH),.vsize(FB_HEIGHT),
        .arx_i(native_ary!=0?native_ary[11:0]:native_arx[11:0]),
        .ary_i(native_ary!=0?native_arx[11:0]:12'd0),
        .arx_o(rotated_arx),.ary_o(rotated_ary)
    );
    assign VIDEO_ARX = rotate_en ? rotated_arx : native_arx;
    assign VIDEO_ARY = rotate_en ? rotated_ary : native_ary;
    osman_rotation u_rotation (
        .clk(CLK_VIDEO),.reset(global_reset),.ce_pix(CE_PIXEL),.enable(rotate_en),.ccw(status[49:48]==2'd2),
        .red(VGA_R),.green(VGA_G),.blue(VGA_B),.hs(VGA_HS),.vs(VGA_VS),.de(VGA_DE),
        .FB_EN(FB_EN),.FB_FORMAT(FB_FORMAT),.FB_WIDTH(FB_WIDTH),.FB_HEIGHT(FB_HEIGHT),
        .FB_BASE(FB_BASE),.FB_STRIDE(FB_STRIDE),.FB_VBL(FB_VBL),.FB_LL(FB_LL),.FB_FORCE_BLANK(FB_FORCE_BLANK),
        .DDRAM_CLK(DDRAM_CLK),.DDRAM_BUSY(DDRAM_BUSY || rom_ddr_rd),.DDRAM_BURSTCNT(rot_ddr_burstcnt),
        .DDRAM_ADDR(rot_ddr_addr),.DDRAM_DIN(rot_ddr_din),.DDRAM_BE(rot_ddr_be),.DDRAM_RD(),.DDRAM_WE(rot_ddr_we)
    );
    // Single-beat requests on one clock: a ROM read wins the cycle and the
    // rotation FIFO sees busy, holding its write. Only the ROM path reads.
    assign DDRAM_BURSTCNT = rom_ddr_rd ? 8'd1 : rot_ddr_burstcnt;
    assign DDRAM_ADDR = rom_ddr_rd ? rom_ddr_addr : rot_ddr_addr;
    assign DDRAM_DIN = rot_ddr_din;
    assign DDRAM_BE = rom_ddr_rd ? 8'hff : rot_ddr_be;
    assign DDRAM_RD = rom_ddr_rd;
    assign DDRAM_WE = rot_ddr_we && !rom_ddr_rd;
    assign AUDIO_S = 1'b1;
    assign AUDIO_L = paused?16'sd0:core_audio;
    assign AUDIO_R = paused?16'sd0:core_audio;
    assign AUDIO_MIX = 2'd0;
    // Credits keep scrolling even when the user has paused gameplay.
    assign HDMI_FREEZE = paused && !credits_active;
    assign VGA_F1=0,VGA_SCALER=0,VGA_DISABLE=0,HDMI_BLACKOUT=0,HDMI_BOB_DEINT=0;
    assign LED_USER=load_error || ioctl_download;
    assign LED_DISK=0,LED_POWER=0,BUTTONS=0;
    assign ADC_BUS='Z;
    assign USER_OUT='1;
    assign {UART_RTS,UART_TXD,UART_DTR}=0;
    assign {SD_SCK,SD_MOSI,SD_CS}='Z;
`ifdef MISTER_DUAL_SDRAM
    // Simple156 uses only the primary SDRAM. Release the second header in
    // both switch positions, including when an analog I/O board is attached.
    assign SDRAM2_CLK = 1'bz;
    assign SDRAM2_A = 13'bz;
    assign SDRAM2_BA = 2'bz;
    assign SDRAM2_DQ = 16'bz;
    assign {SDRAM2_nCS,SDRAM2_nCAS,SDRAM2_nRAS,SDRAM2_nWE} = 4'bz;
`endif
endmodule
