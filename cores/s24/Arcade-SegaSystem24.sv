module emu (
    `include "sys/emu_ports.vh"
);
    logic forced_scandoubler;
    wire video_rotated;
    // This core has no user-I/O protocol. Drive unused open-drain lines low
    // so the board pins have a deterministic output-enable and Quartus does
    // not leave permanently disabled USER_IO output drivers.
    assign USER_OUT='0;
    assign {UART_RTS,UART_TXD,UART_DTR}=0;
    assign {SD_SCK,SD_MOSI,SD_CS}=3'b000;
    assign SD_OE=1'b0;
    `ifndef MISTER_FB
    assign {DDRAM_CLK,DDRAM_BURSTCNT,DDRAM_ADDR,DDRAM_DIN,
            DDRAM_BE,DDRAM_RD,DDRAM_WE}='0;
    `endif
    assign VGA_F1=0;
    // System 24 is a native 24.39 kHz medium-resolution source.  The legacy
    // 15 kHz in-core line doubler would turn that into an unintended 48.8 kHz
    // mode, so honour MiSTer's forced-scandoubler request by selecting the
    // framework scaler while preserving the board's native raster here.
    assign VGA_DISABLE=0;
    assign HDMI_FREEZE=0; assign HDMI_BLACKOUT=0; assign HDMI_BOB_DEINT=0;
    assign AUDIO_S=1; assign AUDIO_MIX=0;
    assign LED_DISK=0; assign LED_POWER=0; assign BUTTONS=0;
    logic [1:0] aspect;
    logic [127:0] status;
    assign aspect=status[2:1];
    wire [1:0] rotation=status[9:8];
    // video_freak encodes plain HV-Integer as 4. The shortened OSD uses its
    // third entry (2), so translate it while omitting the +/- variants.
    wire [2:0] scaling=(status[12:10]==3'd2) ? 3'd4 : status[12:10];
    wire rotation_active=|rotation;
    assign VGA_SCALER=rotation_active|forced_scandoubler;
    wire rotate_ccw=(rotation==2'd1);
    wire [12:0] aspect_arx=aspect==0 ? (rotation_active ? 13'd3 : 13'd4) : {11'd0,aspect-1'b1};
    wire [12:0] aspect_ary=aspect==0 ? (rotation_active ? 13'd4 : 13'd3) : 13'd0;

    `ifndef BUILD_DATE
    `define BUILD_DATE "S24-WIP"
    `endif
    localparam CONF_STR={
        "S24;;",
        "O[2:1],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
        "O[6],Pause,Off,On;",
        "O[16],Pause when OSD is open,Off,On;",
        "O[7],Service Mode,Off,On;",
        "DIP;",
        "O[9:8],Rotation,Normal,Rotate 90 CCW,Rotate 90 CW;",
        "O[12:10],Scaling,Normal,V-Integer,HV-Integer;",
        "O[15:14],Scandoubler Fx,None,CRT 25%,CRT 50%,CRT 75%;",
        "H0O[22:20],Analog Steering Speed,100%,25%,50%,75%,125%,150%,175%;",
        "H0O[24:23],Steering Response,Normal,Fine,Fast;",
        // Listed On first so the default status value of 0 selects it: several
        // titles (Bonanza Bros' stage intros) obtain translucency by toggling
        // a tilemap on and off every frame, which a CRT integrates but a
        // fixed-pixel display shows as a 28.75 Hz flicker. Off gives the raw
        // alternation the PCB emits. H2 keeps this root option visible only
        // for the verified Bonanza Bros board profile.
        "H2O[13],Projector Flicker Fix,On,Off;",
        "P1,CRT Adjust;",
        "P1O[101],Enable,Off,On;",
        "H1P1O[100:96],CRT H-Size,0,+1,+2,...,+15,-16,...,-1;",
        "H1P1O[85:79],CRT H-Position,0,+1,+2,...,+48,-48,...,-1;",
        "H1P1O[78:74],CRT V-Shift,0,+1,+2,...,+15,-16,...,-1;",
        "R[0],Reset;",
        "J1,B1,B2,B3,B4,B5,B6,Start,Coin,Service,Test,Pause;",
        "V,v",`BUILD_DATE
    };

    logic clk_sys,clk_ram,pll_locked;
    // The generated PLL exposes a fourth helper clock for the framework. It
    // is intentionally unused by this core, but retaining the net keeps the
    // generated clock port explicit in the fitted design.
    logic clk_aux /* synthesis keep */;
    // outclk2 is clk_ram phase-shifted +180 degrees for the SDRAM interface.
    // An IOE-DDR-forwarded alternative (altddio_out driven from clk_ram) was
    // tried and hardware-tested bundled with a falling-edge dq_in capture
    // change; that build made sprite rendering regress from corrupt-but-
    // visible to entirely invisible on real hardware. Reverted back to this
    // direct PLL-tap wiring -- the last hardware-confirmed-good SDRAM_CLK
    // source -- pending an isolated re-test of DDIO forwarding on its own.
    // See rtl/mem/sdram.sv's dq_in capture comment for the full account.
    logic clk_sdram;
    pll pll_i(
        .refclk_clk(CLK_50M),.reset_reset(1'b0),
        .outclk0_clk(clk_ram),.outclk1_clk(clk_sys),
        .outclk2_clk(clk_sdram),.outclk3_clk(clk_aux),.locked_export(pll_locked));
    assign SDRAM_CLK=clk_sdram;
    assign CLK_VIDEO=clk_sys;

    logic [1:0] buttons;
    logic [31:0] joy0,joy1,joy2,joy3;
    logic [8:0] spinner0,spinner1,spinner2,spinner3;
    logic [8:0] hps_spinner0,hps_spinner1,hps_spinner2,hps_spinner3;
    logic [7:0] paddle0,paddle1,paddle2,paddle3;
    logic [15:0] stick_l0,stick_l1,stick_l2,stick_l3;
    wire [21:0] gamma_bus;
    logic ioctl_download,ioctl_upload,ioctl_wr,ioctl_rd,ioctl_wait;
    logic loader_wait,persistence_wait;
    logic [15:0] ioctl_index;
    logic [26:0] ioctl_addr;
    logic [15:0] ioctl_dout,ioctl_din;
    logic floppy_save_req;
    logic [15:0] sdram_sz;
    s24_pkg::board_desc_t descriptor;
    wire wheel_controls = descriptor.hotrod_io ||
                          descriptor.analogue_profile==s24_pkg::ANALOGUE_ROUGHRAC;
    hps_io #(.CONF_STR(CONF_STR),.WIDE(1)) hps(
        .clk_sys(clk_sys),.HPS_BUS(HPS_BUS),.EXT_BUS(),.gamma_bus(gamma_bus),
        .forced_scandoubler(forced_scandoubler),.buttons(buttons),.status(status),
        .video_rotated(video_rotated),.new_vmode(1'b0),
        // H1 owns the CRT-adjust children; H2 owns the Bonanza-only projector
        // flicker fix on the root menu.
        .status_menumask({13'd0,~descriptor.video_profile[0],~status[101],~wheel_controls}),
        .joystick_0(joy0),.joystick_1(joy1),
        .joystick_2(joy2),.joystick_3(joy3),
        .joystick_4(),.joystick_5(),
        .joystick_l_analog_0(stick_l0),.joystick_l_analog_1(stick_l1),
        .joystick_l_analog_2(stick_l2),.joystick_l_analog_3(stick_l3),
        .joystick_l_analog_4(),.joystick_l_analog_5(),
        .joystick_r_analog_0(),.joystick_r_analog_1(),
        .joystick_r_analog_2(),.joystick_r_analog_3(),
        .joystick_r_analog_4(),.joystick_r_analog_5(),
        .joystick_0_rumble(16'd0),.joystick_1_rumble(16'd0),
        .joystick_2_rumble(16'd0),.joystick_3_rumble(16'd0),
        .joystick_4_rumble(16'd0),.joystick_5_rumble(16'd0),
        .paddle_0(paddle0),.paddle_1(paddle1),
        .paddle_2(paddle2),.paddle_3(paddle3),
        .paddle_4(),.paddle_5(),
        .spinner_0(hps_spinner0),.spinner_1(hps_spinner1),
        .spinner_2(hps_spinner2),.spinner_3(hps_spinner3),
        .spinner_4(),.spinner_5(),
        .ps2_kbd_clk_out(),.ps2_kbd_data_out(),
        .ps2_kbd_clk_in(1'b0),.ps2_kbd_data_in(1'b0),
        .ps2_kbd_led_status(3'b000),.ps2_kbd_led_use(3'b000),
        .ps2_mouse_clk_out(),.ps2_mouse_data_out(),
        .ps2_mouse_clk_in(1'b0),.ps2_mouse_data_in(1'b0),
        .ps2_key(),.ps2_mouse(),.ps2_mouse_ext(),
        .direct_video(),
        .status_in(128'd0),.status_set(1'b0),
        .info_req(1'b0),.info(8'd0),
        .img_mounted(),.img_readonly(),.img_size(),
        .sd_lba('{32'd0}),.sd_blk_cnt('{6'd0}),
        .sd_rd(1'b0),.sd_wr(1'b0),.sd_ack(),
        .sd_buff_addr(),.sd_buff_dout(),.sd_buff_din('{16'd0}),.sd_buff_wr(),
        .ioctl_download(ioctl_download),.ioctl_upload(ioctl_upload),
        .ioctl_upload_req(floppy_save_req),.ioctl_upload_index(8'd8),
        .ioctl_wr(ioctl_wr),.ioctl_rd(ioctl_rd),.ioctl_index(ioctl_index),
        .ioctl_addr(ioctl_addr),.ioctl_dout(ioctl_dout),.ioctl_din(ioctl_din),
        .ioctl_wait(ioctl_wait),.ioctl_file_ext(),.RTC(),.TIMESTAMP(),
        .uart_mode(),.uart_speed(),.sdram_sz(sdram_sz));
    assign ioctl_wait=loader_wait|persistence_wait;

    logic [7:0] dsw,coinage;
    s24_switches switches(
        .clk(clk_sys),.reset(~pll_locked),.ioctl_wr(ioctl_wr),
        .ioctl_index(ioctl_index),.ioctl_addr(ioctl_addr),
        .ioctl_dout(ioctl_dout),.coinage(coinage),.dsw(dsw));
    logic [63:0] input_ports;
    logic [63:0] mahjong_matrix;
    logic [2:0] mahjong_line;
    always_comb begin
        // MahMahjan's six populated active-low matrix rows.  The four main
        // A-N/Chi/Pon rows use buttons 1-4 on player slots 1-4; Kan, Reach
        // and Ron use button 5 on slots 1-3.  The ordinary start/coin inputs
        // remain available through the standard MiSTer mappings.
        mahjong_matrix = 64'hffff_ffff_ffff_ffff;
        mahjong_matrix[7:0]   = {4'hf,~joy0[7],~joy0[6],~joy0[5],~joy0[4]};
        mahjong_matrix[15:8]  = {4'hf,~joy1[7],~joy1[6],~joy1[5],~joy1[4]};
        mahjong_matrix[23:16] = {4'hf,~joy2[7],~joy2[6],~joy2[5],~joy2[4]};
        mahjong_matrix[31:24] = {4'hf,~joy3[7],~joy3[6],~joy3[5],~joy3[4]};
        mahjong_matrix[39:32] = {7'h7f,~joy0[10]};
        mahjong_matrix[47:40] = {5'h1f,~joy2[8],~joy1[8],~joy0[8]};
    end

    // Wheel-title steering (Hot Rod, Rough Racer): left analog stick X ->
    // synthesized wheel turns, merged with a real MiSTer spinner peripheral
    // if one is attached. See rtl/io/s24_wheel_input.sv for the relative-
    // control rationale. wheel_tick is a free-running ~57.5 Hz update rate;
    // exact phase to the raster does not matter; the counters this ends up
    // driving are read asynchronously to it by the 68000s.
    logic [23:0] wheel_tick_count;
    logic wheel_tick;
    localparam logic [23:0] WHEEL_TICK_PERIOD = 24'd840_293; // CLK_HZ/57.524
    always_ff @(posedge clk_sys) begin
        if(!pll_locked) begin
            wheel_tick_count<=0;
            wheel_tick<=1'b0;
        end else begin
            wheel_tick<=1'b0;
            if(wheel_tick_count>=WHEEL_TICK_PERIOD-1'b1) begin
                wheel_tick_count<=0;wheel_tick<=1'b1;
            end else wheel_tick_count<=wheel_tick_count+1'b1;
        end
    end
    s24_wheel_input wheel0(.clk(clk_sys),.reset(~pll_locked),.tick(wheel_tick),
        .stick_x(stick_l0[7:0]),
        .stick_enable(wheel_controls),
        .speed_code(status[22:20]),.response_code(status[24:23]),
        .analogue_profile(descriptor.analogue_profile),
        .digital_left(joy0[1]),.digital_right(joy0[0]),
        .spinner_in(hps_spinner0),.spinner_out(spinner0));
    s24_wheel_input wheel1(.clk(clk_sys),.reset(~pll_locked),.tick(wheel_tick),
        .stick_x(stick_l1[7:0]),
        .stick_enable(wheel_controls),
        .speed_code(status[22:20]),.response_code(status[24:23]),
        .analogue_profile(descriptor.analogue_profile),
        .digital_left(joy1[1]),.digital_right(joy1[0]),
        .spinner_in(hps_spinner1),.spinner_out(spinner1));
    s24_wheel_input wheel2(.clk(clk_sys),.reset(~pll_locked),.tick(wheel_tick),
        .stick_x(stick_l2[7:0]),
        .stick_enable(wheel_controls),
        .speed_code(status[22:20]),.response_code(status[24:23]),
        .analogue_profile(descriptor.analogue_profile),
        .digital_left(joy2[1]),.digital_right(joy2[0]),
        .spinner_in(hps_spinner2),.spinner_out(spinner2));
    s24_wheel_input wheel3(.clk(clk_sys),.reset(~pll_locked),.tick(wheel_tick),
        .stick_x(stick_l3[7:0]),
        .stick_enable(wheel_controls),
        .speed_code(status[22:20]),.response_code(status[24:23]),
        .analogue_profile(descriptor.analogue_profile),
        .digital_left(joy3[1]),.digital_right(joy3[0]),
        .spinner_in(hps_spinner3),.spinner_out(spinner3));

    // Hot Rod controls: left-stick X is converted to relative steering above;
    // left-stick Y is deliberately unused. A is the digital full-accelerator
    // input, while MiSTer's RT analogue value arrives through paddle_N and
    // provides variable pedal depth. Do not let this Hot Rod convenience
    // mapping alter ADC inputs for other System 24 titles.
    logic [7:0] pedal_merged0,pedal_merged1,pedal_merged2,pedal_merged3;
    s24_pedal_merge pedal_merge(
        .hotrod_io(descriptor.hotrod_io),
        .button1({joy3[4],joy2[4],joy1[4],joy0[4]}),
        .paddle0(paddle0),.paddle1(paddle1),
        .paddle2(paddle2),.paddle3(paddle3),
        .pedal0(pedal_merged0),.pedal1(pedal_merged1),
        .pedal2(pedal_merged2),.pedal3(pedal_merged3));

    s24_inputs inputs(.joy0(joy0),.joy1(joy1),.joy2(joy2),.joy3(joy3),
        .dsw(dsw),.coinage(coinage),.paddle(paddle0),.test_mode(status[7]),
        .golf_io(descriptor.golf_io),.hotrod_io(descriptor.hotrod_io),
        .golf_angle(descriptor.golf_io&&descriptor.has_upd4701),
        .input_profile(descriptor.input_profile),.mahjong_line(mahjong_line),
        .mahjong_matrix(mahjong_matrix),
        .ports(input_ports));

    logic sdram_ready,sdram_ready_m,sdram_ready_s;
    always_ff @(posedge clk_sys) begin
        if(!pll_locked) begin sdram_ready_m<=0;sdram_ready_s<=0;end
        else begin sdram_ready_m<=sdram_ready;sdram_ready_s<=sdram_ready_m;end
    end
    logic wrong_sdram_size;
    assign wrong_sdram_size=sdram_sz[15]&&(sdram_sz[1:0]!=2'b11);

    logic rom_loaded;
    logic lwr_req,lwr_ack;
    logic [26:1] lwr_addr;
    logic [15:0] lwr_data;
    logic [1:0] lwr_be;
    logic key_wr;
    logic [11:0] key_word_addr;
    logic [15:0] key_wdata;
    s24_rom_loader loader(
        .clk(clk_sys),.reset(~pll_locked),.mem_ready(sdram_ready_s),
        .ioctl_download(ioctl_download),.ioctl_index(ioctl_index[7:0]),
        .ioctl_wr(ioctl_wr),.ioctl_addr(ioctl_addr),.ioctl_dout(ioctl_dout),
        .ioctl_wait(loader_wait),.descriptor(descriptor),.rom_loaded(rom_loaded),
        .wr_req(lwr_req),.wr_addr(lwr_addr),.wr_data(lwr_data),.wr_be(lwr_be),.wr_ack(lwr_ack),
        .key_wr(key_wr),.key_word_addr(key_word_addr),.key_wdata(key_wdata));

    logic core_reset,core_reset_async;
    (* altera_attribute = {"-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS"} *)
    logic [1:0] core_reset_sync;
    assign core_reset_async=RESET|status[0]|buttons[1]|~pll_locked|
                            ~sdram_ready_s|~rom_loaded|ioctl_download|
                            wrong_sdram_size;
    // All reset causes assert immediately, but release only on clk_sys edges.
    // This removes recovery-time failures across the high-fanout core reset
    // network without delaying a requested reset.
    always_ff @(posedge clk_sys or posedge core_reset_async) begin
        if(core_reset_async) core_reset_sync<=2'b11;
        else core_reset_sync<={core_reset_sync[0],1'b0};
    end
    assign core_reset=core_reset_sync[1];

    // OSD Pause remains a level option, while the controller Pause input is
    // edge-toggled so a normal button tap pauses until the next tap.  Keep
    // the latch outside s24_core: all emulated clocks and both audio channels
    // then observe the same pause request.  Optional OSD auto-pause is useful
    // for cabinet play without making opening the menu change the default.
    logic controller_pause;
    logic pause_button_d;
    wire pause_button=joy0[14]|joy1[14]|joy2[14]|joy3[14];
    wire persistence_upload=ioctl_upload && ioctl_index[7:0]==8'd8;
    wire core_pause=status[6]|controller_pause|(status[16]&OSD_STATUS)|
                    persistence_upload;
    always_ff @(posedge clk_sys) begin
        if(core_reset) begin
            controller_pause<=1'b0;
            pause_button_d<=1'b0;
        end else begin
            pause_button_d<=pause_button;
            if(pause_button && !pause_button_d)
                controller_pause<=~controller_pause;
        end
    end

    logic p0_req,p2_req,p3_req,p4_req;
    logic [26:1] p0_addr,p3_addr,p4_addr;
    logic [26:4] p2_addr;
    logic [15:0] p0_data,p3_data,p4_data;
    logic [127:0] p2_data;
    logic p0_ack,p2_ack,p3_ack,p4_ack;
    logic cwr_req,cwr_ack;
    logic [26:1] cwr_addr;
    logic [15:0] cwr_data;
    logic [1:0] cwr_be;
    logic core_ce,hblank,vblank,hsync,vsync,video_flip;
    logic [7:0] r,g,b;
    // The generated Cyclone V PLL is 48.317307 MHz. Pass that value to the
    // fractional enables so the board's native 16 MHz PCD raster remains at
    // its exact 656x424 timing instead of inheriting a /3 frequency error.
    logic floppy_written;
    s24_core #(.CLK_HZ(48_317_307)) core(
        .clk(clk_sys),.reset(core_reset),.pause(core_pause),
        .flicker_blend(~status[13]),.board(descriptor),
        .key_wr(key_wr),.key_word_addr(key_word_addr),.key_wdata(key_wdata),
        .input_ports(input_ports),
        .spinner0(spinner0),.spinner1(spinner1),
        .spinner2(spinner2),.spinner3(spinner3),
        .paddle0(pedal_merged0),.paddle1(pedal_merged1),
        .paddle2(pedal_merged2),.paddle3(pedal_merged3),
        .mahjong_line(mahjong_line),
        .ce_pixel(core_ce),.hblank(hblank),.vblank(vblank),
        .hsync(hsync),.vsync(vsync),.video_flip(video_flip),
        .red(r),.green(g),.blue(b),
        .audio_l(AUDIO_L),.audio_r(AUDIO_R),.floppy_written(floppy_written),
        .p0_req(p0_req),.p0_addr(p0_addr),.p0_data(p0_data),.p0_ack(p0_ack),
        .p2_req(p2_req),.p2_addr(p2_addr),.p2_data(p2_data),.p2_ack(p2_ack),
        .p3_req(p3_req),.p3_addr(p3_addr),.p3_data(p3_data),.p3_ack(p3_ack),
        .p4_req(p4_req),.p4_addr(p4_addr),.p4_data(p4_data),.p4_ack(p4_ack),
        .wr_req(cwr_req),.wr_addr(cwr_addr),.wr_data(cwr_data),.wr_be(cwr_be),.wr_ack(cwr_ack));

    wire native_de = ~(hblank|vblank);

    // Core-side CRT Adjust. The native System 24 raster is 656x424 total at
    // roughly 3 clk_sys cycles per 16 MHz pixel. Use 192 sixteenth-quarter
    // units as the nominal period and four units per OSD H-Size step (1/16
    // clk_sys), keeping the full -16..+15 range inside one native line.
    // H-Size 0 deliberately uses core_ce for an exact native-rate baseline.
    logic crt_on;
    logic signed [4:0] crt_hsize;
    logic [6:0] crt_hpos;
    logic signed [5:0] crt_vshift;
    logic signed [8:0] crt_hoffset;
    logic signed [9:0] crt_hsize_quarter16;
    logic signed [9:0] crt_rd_period_raw;
    logic [9:0] crt_rd_period;
    logic [9:0] crt_rd_acc;
    logic crt_hs_ref_d;
    logic crt_native_de_d;
    logic crt_str_active_d;
    logic crt_de_osd;
    wire [7:0] crt_r,crt_g,crt_b;
    wire crt_hs,crt_vs,crt_hb,crt_vb,crt_hs_ref;

    always_ff @(posedge clk_sys) begin
        if(core_reset) begin
            crt_on<=1'b0;
            crt_hsize<='0;
            crt_hpos<='0;
            crt_vshift<='0;
        end else if(core_ce) begin
            crt_on<=status[101];
            crt_hsize<=$signed(status[100:96]);
            crt_hpos<=status[85:79];
            crt_vshift<=$signed(status[78:74]);
        end
    end

    always_comb begin
        if(crt_hpos<=7'd48)
            crt_hoffset=$signed({2'b00,crt_hpos});
        else crt_hoffset=$signed({2'b00,crt_hpos})-9'sd128;
        crt_hsize_quarter16=$signed({{5{crt_hsize[4]}},crt_hsize}) <<< 2;
        crt_rd_period_raw=10'sd192+crt_hsize_quarter16;
        crt_rd_period=(crt_rd_period_raw<10'sd1) ? 10'd1 : crt_rd_period_raw;
    end

    wire crt_rd_tick=(crt_rd_acc+10'd64)>={1'b0,crt_rd_period};
    wire crt_hs_ref_rise=crt_hs_ref & ~crt_hs_ref_d;
    always_ff @(posedge clk_sys) begin
        if(core_reset) begin
            crt_hs_ref_d<=1'b0;
            crt_rd_acc<=10'd0;
        end else if(crt_hs_ref_rise) begin
            crt_hs_ref_d<=crt_hs_ref;
            crt_rd_acc<=10'd0;
        end else begin
            crt_hs_ref_d<=crt_hs_ref;
            if(crt_rd_tick) crt_rd_acc<=crt_rd_acc+10'd64-crt_rd_period;
            else crt_rd_acc<=crt_rd_acc+10'd64;
        end
    end

    wire crt_rd_ce=crt_on ? ((crt_hsize==0) ? core_ce : crt_rd_tick) : core_ce;
    crt_adjust #(.VTOTAL(424),.HTOTAL(656),.HPOS_MODE(0)) crt_adjust_i(
        .clk(clk_sys),.pxl_cen(core_ce),.pxl2_cen(crt_rd_ce),.active(crt_on),
        .hsize(crt_hsize),.hoffset(crt_hoffset),.voffset(crt_vshift),
        .r_in(r),.g_in(g),.b_in(b),.hs_in(hsync),.vs_in(vsync),
        .hb_in(hblank|vblank),.vb_in(vblank),
        .r_out(crt_r),.g_out(crt_g),.b_out(crt_b),.hs_out(crt_hs),.vs_out(crt_vs),
        .hb_out(crt_hb),.vb_out(crt_vb),.hs_ref_out(crt_hs_ref));

    // Keep the framework OSD anchored to the native active-window start while
    // CRT Adjust changes the content width or horizontal position.
    always_ff @(posedge clk_sys) begin
        if(core_reset) begin
            crt_native_de_d<=1'b0;
            crt_str_active_d<=1'b0;
            crt_de_osd<=1'b0;
        end else begin
            if(core_ce) crt_native_de_d<=native_de;
            if(crt_rd_ce) crt_str_active_d<=~crt_hb;
            if(!crt_on) crt_de_osd<=native_de;
            else if(native_de && !crt_native_de_d) crt_de_osd<=1'b1;
            else if(crt_str_active_d && crt_hb) crt_de_osd<=1'b0;
        end
    end

    wire video_ce=crt_on ? crt_rd_ce : core_ce;
    wire [7:0] video_r=crt_on ? crt_r : r;
    wire [7:0] video_g=crt_on ? crt_g : g;
    wire [7:0] video_b=crt_on ? crt_b : b;
    wire video_hs=crt_on ? crt_hs : hsync;
    wire video_vs=crt_on ? crt_vs : vsync;
    wire video_de=crt_on ? (crt_de_osd & ~crt_vb) : native_de;

    // MiSTer's gamma table is a colour transform, not a reason to retime the
    // medium-resolution raster.  gamma_corr pipelines RGB and all four timing
    // qualifiers together, retaining the native 656x424/57.524 Hz mode.
    wire [7:0] gamma_r,gamma_g,gamma_b;
    wire gamma_hs,gamma_vs,gamma_hblank,gamma_vblank;
    gamma_corr gamma_i(
        .clk_sys(gamma_bus[20]),.clk_vid(clk_sys),.ce_pix(video_ce),
        .gamma_en(gamma_bus[19]),.gamma_wr(gamma_bus[18]),
        .gamma_wr_addr(gamma_bus[17:8]),.gamma_value(gamma_bus[7:0]),
        .HSync(video_hs),.VSync(video_vs),
        // video_de includes the CRT-adjust OSD anchor policy. Carry that
        // exact active window through the gamma pipeline as combined blank.
        .HBlank(~video_de),.VBlank(1'b0),
        .RGB_in({video_r,video_g,video_b}),
        .HSync_out(gamma_hs),.VSync_out(gamma_vs),
        .HBlank_out(gamma_hblank),.VBlank_out(gamma_vblank),
        .RGB_out({gamma_r,gamma_g,gamma_b})
    );
    assign gamma_bus[21]=1'b1;
    wire gamma_de=~(gamma_hblank|gamma_vblank);
    wire video_de_freak;
    video_freak video_freak_i (
        .CLK_VIDEO(clk_sys),
        .CE_PIXEL(video_ce),
        .VGA_VS(gamma_vs),
        .HDMI_WIDTH(HDMI_WIDTH),
        .HDMI_HEIGHT(HDMI_HEIGHT),
        .VGA_DE(video_de_freak),
        .VIDEO_ARX(VIDEO_ARX),
        .VIDEO_ARY(VIDEO_ARY),
        .VGA_DE_IN(gamma_de),
        .ARX(aspect_arx[11:0]),
        .ARY(aspect_ary[11:0]),
        .CROP_SIZE(12'd0),
        .CROP_OFF(5'd0),
        .SCALE(scaling)
    );

`ifdef MISTER_FB
    screen_rotate video_rotate (
        .CLK_VIDEO(clk_sys),
        .CE_PIXEL(video_ce),
        .VGA_R(gamma_r),.VGA_G(gamma_g),.VGA_B(gamma_b),
        .VGA_HS(gamma_hs),.VGA_VS(gamma_vs),.VGA_DE(gamma_de),
        .rotate_ccw(rotate_ccw),
        .no_rotate(~rotation_active),
        // Descriptor video_profile bit 1 is the board-profile screen-flip
        // control.  All current System 24 sets leave it clear; keeping the
        // path profile-driven makes the hardware orientation selectable
        // without a set-name conditional or a change to the native raster.
        .flip(descriptor.video_profile[1] | video_flip),
        .video_rotated(video_rotated),
        .FB_EN(FB_EN),.FB_FORMAT(FB_FORMAT),
        .FB_WIDTH(FB_WIDTH),.FB_HEIGHT(FB_HEIGHT),
        .FB_BASE(FB_BASE),.FB_STRIDE(FB_STRIDE),
        .FB_VBL(FB_VBL),.FB_LL(FB_LL),
        .DDRAM_CLK(DDRAM_CLK),.DDRAM_BUSY(DDRAM_BUSY),
        .DDRAM_BURSTCNT(DDRAM_BURSTCNT),.DDRAM_ADDR(DDRAM_ADDR),
        .DDRAM_DIN(DDRAM_DIN),.DDRAM_BE(DDRAM_BE),
        .DDRAM_WE(DDRAM_WE),.DDRAM_RD(DDRAM_RD)
    );
    assign FB_FORCE_BLANK=1'b0;
`else
    assign video_rotated=1'b0;
`endif

    logic swr_req,swr_ack;
    logic [26:1] swr_addr;
    logic [15:0] swr_data;
    logic [1:0] swr_be;
    assign swr_req=lwr_req|cwr_req;
    assign swr_addr=lwr_req?lwr_addr:cwr_addr;
    assign swr_data=lwr_req?lwr_data:cwr_data;
    assign swr_be=lwr_req?lwr_be:cwr_be;
    assign lwr_ack=swr_ack&&lwr_req;
    assign cwr_ack=swr_ack&&cwr_req&&!lwr_req;

    // Every core/loader SDRAM port crosses from clk_sys to clk_ram.  Keep the
    // request payload stable in a source-domain mailbox until a synchronized
    // completion returns; likewise hold response data in clk_ram until its
    // response toggle has crossed back.  The old direct buses could sample a
    // new address with an old request (or partially settled burst data).
    logic mwr_req,mwr_ack;
    logic [26:1] mwr_addr;
    logic [15:0] mwr_data;
    logic [1:0]  mwr_be;
    logic mp0_req,mp2_req,mp3_req,mp4_req;
    logic [26:1] mp0_addr,mp3_addr,mp4_addr;
    logic [26:4] mp2_addr;
    logic [15:0] mp0_data,mp3_data,mp4_data;
    logic [127:0] mp2_data;
    logic mp0_ack,mp2_ack,mp3_ack,mp4_ack;
    logic wr_rsp_unused_src,wr_rsp_unused_dst;

    // The immutable MRA disk (index 3) is overlaid by MiSTer's index-8 NVRAM
    // file at boot.  Any accepted FDC write marks that image dirty.  Coalesce
    // writes for five seconds before requesting a host save so a format or
    // directory update becomes one transfer rather than a save loop.
    localparam logic [27:0] FLOPPY_SAVE_DELAY=28'd241_586_535;
    logic floppy_dirty;
    logic [27:0] floppy_save_timer;
    always_ff @(posedge clk_sys) begin
        if(!pll_locked) begin
            floppy_dirty<=1'b0;
            floppy_save_timer<='0;
            floppy_save_req<=1'b0;
        end else begin
            if(floppy_written) begin
                floppy_dirty<=1'b1;
                floppy_save_timer<=FLOPPY_SAVE_DELAY;
            end else if(floppy_save_timer!=0) begin
                floppy_save_timer<=floppy_save_timer-1'b1;
            end

            if(floppy_dirty && floppy_save_timer==0)
                floppy_save_req<=1'b1;

            if(persistence_upload) begin
                floppy_dirty<=1'b0;
                floppy_save_req<=1'b0;
            end
        end
    end

    // hps_io presents the upload address before requesting each data word.
    // Prefetch that word through CPU-A's SDRAM port and hold ioctl_wait until
    // it is resident.  Pausing the core lets any already-issued CPU-A request
    // retire before ownership changes; no in-flight response is discarded.
    logic persistence_owns_p0,persistence_p0_req,persistence_p0_ack;
    logic [26:1] persistence_p0_addr;
    logic [15:0] persistence_p0_data;
    logic [26:0] persistence_cached_addr;
    logic persistence_data_valid;
    wire cdc_p0_req=persistence_owns_p0 ? persistence_p0_req : p0_req;
    wire [26:1] cdc_p0_addr=persistence_owns_p0 ? persistence_p0_addr : p0_addr;
    logic cdc_p0_ack;
    logic [15:0] cdc_p0_data;
    assign p0_ack=!persistence_owns_p0 && cdc_p0_ack;
    assign p0_data=cdc_p0_data;
    assign persistence_p0_ack=persistence_owns_p0 && cdc_p0_ack;
    assign persistence_wait=persistence_upload &&
                            (!persistence_owns_p0 || !persistence_data_valid);
    assign ioctl_din=persistence_upload ? persistence_p0_data : 16'd0;

    always_ff @(posedge clk_sys) begin
        if(!pll_locked || !persistence_upload) begin
            persistence_owns_p0<=1'b0;
            persistence_p0_req<=1'b0;
            persistence_p0_addr<='0;
            persistence_p0_data<='0;
            persistence_cached_addr<='1;
            persistence_data_valid<=1'b0;
        end else begin
            if(!persistence_owns_p0 && !p0_req)
                persistence_owns_p0<=1'b1;

            if(persistence_data_valid &&
               persistence_cached_addr!=ioctl_addr)
                persistence_data_valid<=1'b0;

            if(persistence_owns_p0 && !persistence_p0_req &&
               (!persistence_data_valid ||
                persistence_cached_addr!=ioctl_addr)) begin
                persistence_p0_req<=1'b1;
                persistence_p0_addr<=s24_pkg::word_address(
                    s24_pkg::SDR_FLOPPY_BASE+ioctl_addr);
                persistence_cached_addr<=ioctl_addr;
                persistence_data_valid<=1'b0;
            end

            if(persistence_p0_ack) begin
                persistence_p0_req<=1'b0;
                persistence_p0_data<=cdc_p0_data;
                persistence_data_valid<=1'b1;
            end
        end
    end

    // SYNC_STAGES(1) on every instance below: clk_sys and clk_ram are the same
    // PLL VCO divided by 26 and 13 -- an exact phase-locked 2:1 pair that
    // Arcade-SegaSystem24.sdc already keeps in one clock group -- so the second
    // synchronizer flop resolves no metastability and only adds latency. It
    // cost 1.5 clk_sys (31 ns) on every SDRAM access, which pushed CPU reads
    // past the 68000's DTACK deadline and put wait states on every bus cycle.
    // The payload stability window the SDC's multicycle exception relies on is
    // unchanged at one stage; see rtl/mem/s24_sdram_cdc.sv's SYNC_STAGES note
    // before touching this or the PLL ratios.
    s24_sdram_cdc #(.REQ_WIDTH(44),.RSP_WIDTH(1),.SYNC_STAGES(1)) cdc_wr(
        .reset(~pll_locked),
        .src_clk(clk_sys),.src_req(swr_req),
        .src_payload({swr_addr,swr_data,swr_be}),
        .src_ack(swr_ack),.src_response(wr_rsp_unused_src),
        .dst_clk(clk_ram),.dst_req(mwr_req),
        .dst_payload({mwr_addr,mwr_data,mwr_be}),
        .dst_ack(mwr_ack),.dst_response(wr_rsp_unused_dst));
    assign wr_rsp_unused_dst=1'b0;

    s24_sdram_cdc #(.REQ_WIDTH(26),.RSP_WIDTH(16),.SYNC_STAGES(1)) cdc_p0(
        .reset(~pll_locked),
        .src_clk(clk_sys),.src_req(cdc_p0_req),.src_payload(cdc_p0_addr),
        .src_ack(cdc_p0_ack),.src_response(cdc_p0_data),
        .dst_clk(clk_ram),.dst_req(mp0_req),.dst_payload(mp0_addr),
        .dst_ack(mp0_ack),.dst_response(mp0_data));
    s24_sdram_cdc #(.REQ_WIDTH(23),.RSP_WIDTH(128),.SYNC_STAGES(1)) cdc_p2(
        .reset(~pll_locked),
        .src_clk(clk_sys),.src_req(p2_req),.src_payload(p2_addr),
        .src_ack(p2_ack),.src_response(p2_data),
        .dst_clk(clk_ram),.dst_req(mp2_req),.dst_payload(mp2_addr),
        .dst_ack(mp2_ack),.dst_response(mp2_data));
    s24_sdram_cdc #(.REQ_WIDTH(26),.RSP_WIDTH(16),.SYNC_STAGES(1)) cdc_p3(
        .reset(~pll_locked),
        .src_clk(clk_sys),.src_req(p3_req),.src_payload(p3_addr),
        .src_ack(p3_ack),.src_response(p3_data),
        .dst_clk(clk_ram),.dst_req(mp3_req),.dst_payload(mp3_addr),
        .dst_ack(mp3_ack),.dst_response(mp3_data));
    s24_sdram_cdc #(.REQ_WIDTH(26),.RSP_WIDTH(16),.SYNC_STAGES(1)) cdc_p4(
        .reset(~pll_locked),
        .src_clk(clk_sys),.src_req(p4_req),.src_payload(p4_addr),
        .src_ack(p4_ack),.src_response(p4_data),
        .dst_clk(clk_ram),.dst_req(mp4_req),.dst_payload(mp4_addr),
        .dst_ack(mp4_ack),.dst_response(mp4_data));
    sdram memory(
        .clk(clk_ram),.init(~pll_locked),.ready(sdram_ready),
        .SDRAM_DQ(SDRAM_DQ),.SDRAM_A(SDRAM_A),.SDRAM_BA(SDRAM_BA),
        .SDRAM_DQML(SDRAM_DQML),.SDRAM_DQMH(SDRAM_DQMH),.SDRAM_nCS(SDRAM_nCS),
        .SDRAM_nCAS(SDRAM_nCAS),.SDRAM_nRAS(SDRAM_nRAS),.SDRAM_nWE(SDRAM_nWE),
        .SDRAM_CKE(SDRAM_CKE),.wr_req(mwr_req),.wr_addr(mwr_addr),
        .wr_din(mwr_data),.wr_be(mwr_be),.wr_ack(mwr_ack),
        .p0_req(mp0_req),.p0_addr(mp0_addr),.p0_dout(mp0_data),.p0_ack(mp0_ack),
        .p2_req(mp2_req),.p2_addr(mp2_addr),.p2_dout(mp2_data),.p2_ack(mp2_ack),
        .p3_req(mp3_req),.p3_addr(mp3_addr),.p3_dout(mp3_data),.p3_ack(mp3_ack),
        .p4_req(mp4_req),.p4_addr(mp4_addr),.p4_dout(mp4_data),.p4_ack(mp4_ack));

    // Present the board's native 16 MHz, 656x424-total raster directly to the
    // MiSTer framework.  This is 496x384 active video at 24.39 kHz horizontal
    // and 57.524 Hz vertical.  The legacy in-core video_mixer was intended for
    // older 15 kHz cores and re-timed this medium-resolution stream, producing
    // line repeats, frame tearing and vertical jumps on real hardware.
    assign CE_PIXEL=video_ce;
    assign VGA_R=gamma_r;
    assign VGA_G=gamma_g;
    assign VGA_B=gamma_b;
    assign VGA_HS=gamma_hs;
    assign VGA_VS=gamma_vs;
    assign VGA_DE=gamma_de;
    // The framework applies these strengths after scaling; no native System
    // 24 line is discarded or darkened inside the authentic 384-line raster.
    assign VGA_SL=status[15:14];

    assign LED_USER=~rom_loaded|ioctl_download|wrong_sdram_size;
endmodule
