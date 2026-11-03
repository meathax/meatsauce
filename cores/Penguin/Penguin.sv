// SPDX-License-Identifier: GPL-3.0-or-later
module emu(
    `include "sys/emu_ports.vh"
);
    localparam CONF_STR={
        "Penguin;;",
        "P1,Video Settings;",
        "P1OCD,Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
        "H0P1O9A,Rotation,Normal,90 CW,90 CCW,180;",
        "H1P1OB,Rotation,Normal,180;",
        "H0P1O68,Scaling,Normal,V-Integer,HV-Integer;",
        "H0P1O35,Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;",
        "P1-;P1OE,CRT Adjust,Off,On;",
        "H2P1OFI,CRT H-Size,0,+1,+2,-2,-1;",
        "H2P1OJN,CRT H-Position,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
        "H2P1O[31:27],CRT V-Shift,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
        "H2P1OOQ,CRT V-Size,0,+1,+2,+3,-4,-3,-2,-1;",
        "P2,Game Settings;P2O[33],OSD Pause,Off,On;",
        "P2O[32],Autosave Scores,On,Off;P2O1,Test Mode,Off,On;",
        "-;DIP;P3,Credits;P3-,Penguin Brothers;P3-,Original game: Subsino (2000);P3-,MiSTer FPGA platform;",
        "-;R0,Reset;",
        "J1,Bomb,Jump,Pause,Start,Coin,Service,Test;jn,A,B,X,Start,Select,R,L;V,Development;"
    };
    wire clk,clk_forward,pll_locked;
    wire clk_capture = clk_forward;
    penguin_pll pll(.refclk(CLK_50M),.rst(RESET),.outclk_0(clk),.outclk_1(clk_forward),.locked(pll_locked));
    wire cold_reset=RESET||!pll_locked;
    wire rotate_180,osd_pause;
    wire [127:0] status;wire [31:0] joystick_0,joystick_1;wire [1:0] buttons;wire [10:0] ps2_key;
    wire forced_scandoubler,direct_video;wire [21:0] gamma_bus;
    wire ioctl_download,ioctl_upload,ioctl_wr;wire [26:0] ioctl_addr;
    wire ioctl_is_rom;wire [15:0] ioctl_index;wire [7:0] ioctl_dout,ioctl_din;wire load_wait,rom_ready,load_error,fast_loading;
    assign ioctl_din=8'd0;
    hps_io #(.CONF_STR(CONF_STR),.WIDE(0)) hps_io(.clk_sys(clk),.HPS_BUS,.status,.buttons,.joystick_0,.joystick_1,.ps2_key,
        .forced_scandoubler,.direct_video,.gamma_bus,.video_rotated(rotated),.status_menumask({29'd0,!status[14],!direct_video,direct_video}),
        .ioctl_download,.ioctl_upload,.ioctl_wr,.ioctl_addr,.ioctl_index,.ioctl_is_rom,.ioctl_dout,.ioctl_din,.ioctl_upload_req(1'b0),
        .ioctl_upload_index(8'd4),.ioctl_wait(fast_loading||(ioctl_is_rom?load_wait:1'b0)));
    logic [15:0] dip_switches=16'hffff;logic [31:0] keys1=0,keys2=0;logic key_toggle=0,test_key=0;
    always_ff @(posedge clk)begin
        if(cold_reset)begin dip_switches<=16'hffff;keys1<=0;keys2<=0;test_key<=0;key_toggle<=ps2_key[10];end
        else begin
            if(ioctl_download && ioctl_wr && ioctl_index==254 && ioctl_addr<2)dip_switches[ioctl_addr[0]*8+:8]<=ioctl_dout;
            if(key_toggle!=ps2_key[10])begin
                key_toggle<=ps2_key[10];
                case(ps2_key[8:0])
                    9'h174:keys1[0]<=ps2_key[9];9'h16b:keys1[1]<=ps2_key[9];9'h172:keys1[2]<=ps2_key[9];9'h175:keys1[3]<=ps2_key[9];
                    9'h014:keys1[4]<=ps2_key[9];9'h011:keys1[5]<=ps2_key[9];9'h04d:keys1[7]<=ps2_key[9];
                    9'h016:keys1[8]<=ps2_key[9];9'h01e:keys2[8]<=ps2_key[9];9'h02e:keys1[9]<=ps2_key[9];9'h036:keys2[9]<=ps2_key[9];
                    9'h046:keys1[10]<=ps2_key[9];9'h006:test_key<=ps2_key[9];default:;
                endcase
            end
        end
    end
    // HPS button slots4..10; board reserves bit6 and starts Pause atbit7.
    wire [31:0] joy1=keys1|{21'd0,joystick_0[9:6],1'b0,joystick_0[5:0]};
    wire [31:0] joy2=keys2|{21'd0,joystick_1[9:6],1'b0,joystick_1[5:0]};
    wire test_mode=status[1]||test_key||joystick_0[10]||joystick_1[10];
    wire download=ioctl_download&&ioctl_is_rom;
    wire reset_request=status[0]||buttons[1]||download||!rom_ready;
    wire memory_hold,memory_phase_reset;
// BEGIN LOCAL_RESET_DECODE
    // Separate fixed LUTs keep the memory control off the board reset tree.
    // No register, clock, reset-release edge or protocol cycle is added.
    (* keep *) wire [1:0] reset_branch;
`ifdef SYNTHESIS
    cyclonev_lcell_comb #(.lut_mask(64'hfeeefffffeeeffff)) reset_memory_decode(
        .dataa(status[0]),.datab(buttons[1]),.datac(ioctl_download),.datad(ioctl_is_rom),
        .datae(rom_ready),.dataf(1'b0),.datag(1'b0),.cin(1'b0),.sharein(1'b0),
        .combout(reset_branch[0]),.sumout(),.cout(),.shareout());
    cyclonev_lcell_comb #(.lut_mask(64'hfffffffffffffeff)) reset_board_decode(
        .dataa(status[0]),.datab(buttons[1]),.datac(download),.datad(rom_ready),
        .datae(cold_reset),.dataf(memory_hold),.datag(1'b0),.cin(1'b0),.sharein(1'b0),
        .combout(reset_branch[1]),.sumout(),.cout(),.shareout());
`else
    assign reset_branch[0]=reset_request;
    assign reset_branch[1]=cold_reset||reset_request||memory_hold;
`endif
// END LOCAL_RESET_DECODE

    wire board_reset=reset_branch[1];
    wire user_pause;
    gd_pause_toggle pause_button(.clk,.reset(board_reset),.button(joy1[7]||joy2[7]),.paused(user_pause));
    wire board_pause=user_pause||osd_pause;
    wire [20:0] rom_addr,sample_addr;wire rom_req,rom_ack,sample_req,sample_ack;wire [15:0] rom_dout;wire [7:0] sample_dout;
    wire [24:0] gfx_addr;wire gfx_req,gfx_ack;wire [63:0] gfx_dout;
    wire [17:0] ram_addr;wire ram_req,ram_ack,ram_write;
    wire [15:0] ram_data,ram_dout;wire [1:0] ram_be;
    wire [7:0] red,green,blue;wire ce_pix,hsync,vsync,hblank,vblank;
    wire signed [15:0] audio_left,audio_right;wire audio_valid;
    wire [15:0] missed_lines,mixer_overruns,max_gfx_cycles;wire [31:0] graphics_requests;
    // 60.53 Hz: PCB video timer measurement, docs/pcb-refresh-measurement.md.
    penguin_board #(.SYS_HZ(100000000),.PIXEL_DIV(16),.H_TOTAL(400),.V_TOTAL(258),.EXTERNAL_WORK_RAM(1)) board(.clk,.cold_reset,.reset(board_reset),.pause(board_pause),.dip_switches,
        .joystick_p1(joy1),.joystick_p2(joy2),.service(test_mode),.rotate_180(rotate_180),
        .rom_addr,.rom_req,.rom_dout,.rom_ack,.ram_addr,.ram_req,.ram_write,.ram_data,.ram_be,.ram_dout,.ram_ack,
        .gfx_addr,.gfx_req,.gfx_dout,.gfx_ack,.sample_addr,.sample_req,.sample_dout,.sample_ack,
        .red,.green,.blue,.ce_pix,.hsync,.vsync,.hblank,.vblank,.h_count(),.v_count(),.audio_left,.audio_right,.audio_valid,.mixer_overruns,.missed_lines,
        .frame_number(),.debug_bus_cycles(),.debug_rom_cycles(),.debug_unmapped_cycles(),.debug_address(),.cpu_running(),.sprite_buffer_busy(),.raster_enable());
    wire fb_we,fb_busy;wire [28:0] fb_addr;wire [63:0] fb_data;wire [7:0] fb_be;
    penguin_memory memory(.clk,.clk_forward,.clk_capture,.cold_reset,.warm_reset(reset_branch[0]),.core_hold(memory_hold),.phase_reset(memory_phase_reset),.download,.load_wr(ioctl_wr&&ioctl_is_rom),.load_addr(ioctl_addr),.load_data(ioctl_dout),
        .load_wait,.rom_ready,.load_error,.fast_loading,.rom_addr,.rom_req,.rom_dout,.rom_ack,.sample_addr,.sample_req,.sample_dout,.sample_ack,
        .gfx_addr,.gfx_req,.gfx_dout,.gfx_ack,.ram_addr,.ram_req,.ram_write,.ram_data,.ram_be,.ram_dout,.ram_ack,
        .fb_we,.fb_addr,.fb_data,.fb_be,.fb_busy,
        .DDRAM_CLK,.DDRAM_BUSY,.DDRAM_BURSTCNT,.DDRAM_ADDR,.DDRAM_DOUT,.DDRAM_DOUT_READY,.DDRAM_RD,.DDRAM_DIN,.DDRAM_BE,.DDRAM_WE,
        .SDRAM_DQ,.SDRAM_A,.SDRAM_BA,.SDRAM_CLK,.SDRAM_CKE,.SDRAM_DQML,.SDRAM_DQMH,.SDRAM_nCS,.SDRAM_nWE,.SDRAM_nCAS,.SDRAM_nRAS,
        .max_gfx_cycles,.graphics_requests);
    wire signed [16:0] audio_sum={audio_left[15],audio_left}+{audio_right[15],audio_right};
    wire [15:0] mono=audio_sum>17'sd32767 ? 16'h7fff:audio_sum< -17'sd32768 ? 16'h8000:audio_sum[15:0];
    assign AUDIO_L=mono;assign AUDIO_R=mono;assign AUDIO_S=1;assign AUDIO_MIX=0;
    wire [7:0] crt_r,crt_g,crt_b,v_r,v_g,v_b;wire crt_hs,crt_vs,crt_hb,crt_vb,hs_ref,v_hs,v_vs,v_de,v_vb,v_ce,v_hb,crt_read_ce;
    // BEGIN PENGUIN_OSD_DECODE
    logic signed [4:0] hsize;
    always_comb begin
        case(status[18:15])
            4'd1:hsize=5'sd1;4'd2:hsize=5'sd2;
            4'd3:hsize=-5'sd2;4'd4:hsize=-5'sd1;
            default:hsize=5'sd0;
        endcase
    end
    wire signed [8:0] hpos={{4{status[23]}},status[23:19]};
    wire signed [5:0] vpos={status[31],status[31:27]},vsize={{3{status[26]}},status[26:24]};
    wire [2:0] scale_mode=(status[8:6]<=3'd2)?status[8:6]:3'd0;
    assign rotate_180=direct_video?status[11]:(status[10:9]==2'd3);
    assign osd_pause=OSD_STATUS&&status[33];
    // END PENGUIN_OSD_DECODE
    penguin_platform_crt_clock crt_clock(.clk,.reset(cold_reset),.hs_ref,.hsize,.ce(crt_read_ce));
    penguin_platform_crt_adjust #(.VTOTAL(258),.HTOTAL(400)) crt(.clk,.pxl_cen(ce_pix),.pxl2_cen(crt_read_ce),.active(status[14]),.hsize,.hoffset(hpos),.voffset(vpos),
        .r_in(red),.g_in(green),.b_in(blue),.hs_in(hsync),.vs_in(vsync),.hb_in(hblank),.vb_in(vblank),
        .r_out(crt_r),.g_out(crt_g),.b_out(crt_b),.hs_out(crt_hs),.vs_out(crt_vs),.hb_out(crt_hb),.vb_out(crt_vb),.hs_ref_out(hs_ref));
    penguin_platform_crt_vsize #(.RING_LINES(14),.LINE_PX(400),.FRONT_MIN(64)) crt_height(.clk,.pxl_cen(status[14]?crt_read_ce:ce_pix),.active(status[14]),.tube_mode(1'b1),.vsize,
        .r_in(crt_r),.g_in(crt_g),.b_in(crt_b),.hs_in(crt_hs),.vs_in(crt_vs),.de_in(!(crt_hb||crt_vb)),.hb_in(crt_hb),.vb_in(crt_vb),
        .r_out(v_r),.g_out(v_g),.b_out(v_b),.hs_out(v_hs),.vs_out(v_vs),.de_out(v_de),.hb_out(v_hb),.vb_out(v_vb),.ce_out(v_ce));
    wire video_de,rotated;
    penguin_platform_arcade_video #(.WIDTH(320),.DW(24)) video_output(.clk_video(clk),.ce_pix(v_ce),.RGB_in({v_r,v_g,v_b}),.HBlank(v_hb),.VBlank(v_vb),.HSync(v_hs),.VSync(v_vs),
        .CLK_VIDEO,.CE_PIXEL,.VGA_R,.VGA_G,.VGA_B,.VGA_HS,.VGA_VS,.VGA_DE(video_de),.VGA_SL,.fx(status[5:3]),.forced_scandoubler,.gamma_bus);
`ifdef MISTER_FB
    wire rotation_geometry_changed;
    wire rotation_en,rotation_we,rotation_vbl;wire[11:0]rotation_width,rotation_height;wire[13:0]rotation_stride;wire[31:0]rotation_base;
    wire[28:0]rotation_addr;wire[63:0]rotation_data;wire[7:0]rotation_be;
    wire[1:0]rotation_mode=direct_video?2'd0:(status[10:9]==1||status[10:9]==2)?status[10:9]:2'd0;
    screen_rotate rotate(.CLK_VIDEO,.CE_PIXEL,.VGA_R,.VGA_G,.VGA_B,.VGA_HS,.VGA_VS,.VGA_DE(video_de),.rotate_ccw(status[10:9]==2),
        .no_rotate(direct_video||status[10:9]==0||status[10:9]==3),.flip(1'b0),.video_rotated(rotated),
        .FB_EN(rotation_en),.FB_FORMAT,.FB_WIDTH(rotation_width),.FB_HEIGHT(rotation_height),.FB_BASE(rotation_base),.FB_STRIDE(rotation_stride),.FB_GEOMETRY_CHANGED(rotation_geometry_changed),.FB_VBL(rotation_vbl),.FB_LL,
        .DDRAM_CLK(),.DDRAM_BUSY(fb_busy),.DDRAM_BURSTCNT(),.DDRAM_ADDR(rotation_addr),.DDRAM_DIN(rotation_data),.DDRAM_BE(rotation_be),.DDRAM_WE(rotation_we),.DDRAM_RD());
    penguin_platform_framebuffer #(.REGISTERED_GEOMETRY_EPOCH(1)) framebuffer_queue(.clk,.reset(board_reset),.mode(rotation_mode),.source_ce(CE_PIXEL),.source_de(video_de),.source_vs(VGA_VS),
        .in_we(rotation_we),.in_addr(rotation_addr),.in_data(rotation_data),.in_be(rotation_be),.registered_geometry_epoch(rotation_geometry_changed),.raw_en(rotation_en),.raw_width(rotation_width),.raw_height(rotation_height),.raw_stride(rotation_stride),.raw_base(rotation_base),.display_vbl(FB_VBL),.gated_vbl(rotation_vbl),
        .display_en(FB_EN),.display_base(FB_BASE),.display_width(FB_WIDTH),.display_height(FB_HEIGHT),.display_stride(FB_STRIDE),.out_we(fb_we),.out_addr(fb_addr),.out_data(fb_data),.out_be(fb_be),.out_busy(fb_busy),.overflow(),.high_water(),.pixel_count(),.write_count(),.published_frames());
    assign FB_FORCE_BLANK=0;
`ifdef MISTER_FB_PALETTE
    assign FB_PAL_CLK=clk;assign FB_PAL_ADDR=0;assign FB_PAL_DOUT=0;assign FB_PAL_WR=0;
`endif
`else
    assign fb_we=0;assign fb_addr=0;assign fb_data=0;assign fb_be=0;assign rotated=0;
`endif
    wire [1:0] aspect=status[13:12];
    wire [11:0] arx=aspect?{10'd0,aspect}-12'd1:(rotated?12'd3:12'd4),ary=aspect?12'd0:(rotated?12'd4:12'd3);
    wire[12:0] native_arx,native_ary;
    video_freak scaler(.CLK_VIDEO,.CE_PIXEL,.VGA_VS,.HDMI_WIDTH,.HDMI_HEIGHT,.VGA_DE,.VIDEO_ARX(native_arx),.VIDEO_ARY(native_ary),.VGA_DE_IN(video_de),
        .ARX(arx),.ARY(ary),.CROP_SIZE(12'd0),.CROP_OFF(5'd0),.SCALE(direct_video?3'd0:scale_mode));
`ifdef MISTER_FB
    // Integer factors refer to the published rotated image, including CRT size.
    wire[12:0] framebuffer_arx,framebuffer_ary;
    video_scale_int framebuffer_scaler(.CLK_VIDEO,.HDMI_WIDTH,.HDMI_HEIGHT,.SCALE(scale_mode),.hsize(FB_WIDTH),.vsize(FB_HEIGHT),
        .arx_i(arx),.ary_i(ary),.arx_o(framebuffer_arx),.ary_o(framebuffer_ary));
    // BEGIN ASPECT_OUTPUT_PIPELINE: frame metadata gets one master-clock stage.
    logic [12:0] aspect_arx_q=0,aspect_ary_q=0;
    always_ff @(posedge CLK_VIDEO) begin
        aspect_arx_q <= FB_EN?framebuffer_arx:native_arx;
        aspect_ary_q <= FB_EN?framebuffer_ary:native_ary;
    end
    assign VIDEO_ARX=aspect_arx_q;
    assign VIDEO_ARY=aspect_ary_q;
    // END ASPECT_OUTPUT_PIPELINE
`else
    assign VIDEO_ARX=native_arx;assign VIDEO_ARY=native_ary;
`endif
    assign ADC_BUS='Z;assign USER_OUT='1;assign {UART_RTS,UART_TXD,UART_DTR}=0;assign {SD_SCK,SD_MOSI,SD_CS}='Z;
    assign VGA_F1=0;assign VGA_SCALER=0;assign VGA_DISABLE=0;assign HDMI_FREEZE=0;assign HDMI_BLACKOUT=0;assign HDMI_BOB_DEINT=0;
    assign LED_USER=download||load_error;assign LED_POWER=0;assign LED_DISK=0;assign BUTTONS=0;
`ifdef MISTER_DUAL_SDRAM
    assign {SDRAM2_CLK,SDRAM2_A,SDRAM2_BA,SDRAM2_DQ,SDRAM2_nCS,SDRAM2_nCAS,SDRAM2_nRAS,SDRAM2_nWE}='Z;
`endif
endmodule
