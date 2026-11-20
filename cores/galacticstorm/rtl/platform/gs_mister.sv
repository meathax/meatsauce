// SPDX-License-Identifier: GPL-3.0-or-later
// Integration candidate: complete native game/EEPROM persistence and combined
// resource/timing qualification remain gates in progress.md.
// Native batch candidate is selected explicitly in its measured FPGA profile.
`ifndef GS_CPU_WRITE_LINES
`define GS_CPU_WRITE_LINES 1
`endif
module emu (
    `include "sys/emu_ports.vh"
);
    assign ADC_BUS='Z;assign USER_OUT='1;
    assign {UART_RTS,UART_TXD,UART_DTR}=0;
    assign {SD_SCK,SD_MOSI,SD_CS}='Z;
    assign VGA_SL=video_status[21:20];assign VGA_F1=0;assign VGA_SCALER=0;assign VGA_DISABLE=0;
    assign HDMI_FREEZE=0;assign HDMI_BLACKOUT=0;assign HDMI_BOB_DEINT=0;
    assign AUDIO_S=1;assign AUDIO_MIX=status[4:3];
    assign LED_DISK=0;assign LED_POWER=0;assign BUTTONS=0;
    `include "build_id.v"
    localparam CONF_STR={
        "GalacticStorm;;",
        // Layout follows HeavyUnit: Video Settings / Game Settings pages, then Reset.
        // Status bit allocation is unchanged except the new control bits [33:31] and [29] (TC0610 mode).
        "P1,Video Settings;",
        "P1O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
        "P1O[21:20],Scandoubler Fx,None,CRT 25%,CRT 50%,CRT 75%;",
        "H1P1O[24:22],Scale,Normal,V-Integer,HV-Integer-,HV-Integer+,HV-Integer;",
        "H1P1O[25],Vertical crop,Off,224 lines;",
        "H2P1O[27:26],Rotate 90,None,CW,CCW;",
        "P1O[30],Rotate 180,Off,On;",
        "P1-;",
        "P1O[5],CRT Adjust,Off,On;",
        "H0P1O[9:6],CRT H-Size,0,+1,+2,+3,+4,-4,-3,-2,-1;",
        "H0P1O[14:10],CRT H-Position,0,+4,+8,+12,+16,+20,+24,+28,+32,-32,-28,-24,-20,-16,-12,-8,-4;",
        "H0P1O[19:15],CRT V-Shift,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
        "P2,Game Settings;",
        "P2O[31],Left Stick Invert Y,On,Off;",
        "P2O[33:32],Left Stick Sensitivity,Medium,Low,Fast;",
        "P2O[34],CPU Speed,Fast,Original 16MHz;",
        "P2-;",
        "P2O[4:3],Stereo mix,0%,25%,50%,Mono;",
        "P2O[1],Pause,Off,On;",
        "P2O[2],Pause in OSD,On,Off;",
        "P2T[28],Service menu;",
        "-;",
        "J1,Shot,Shot (alternate),D-Weapon,D-Weapon (alternate),Start,Coin,Service credit,Service menu,Pause/Resume;",
        "T[0],Reset;R[0],Reset and close OSD;V,v",`BUILD_DATE
    };
    wire direct_video;wire [1:0] rotation=status[27:26];
    wire [127:0] status;wire [1:0] buttons;wire [31:0] joystick,joystick2;
    wire [15:0] analog_stick; /* left analog stick */ wire forced_scandoubler;wire [21:0] gamma_bus;
    wire ioctl_download,ioctl_upload,ioctl_wr,ioctl_wait,loader_wait,hs_wait;
    assign ioctl_wait=loader_wait || hs_wait || (ioctl_download && ioctl_wr) || hps_reset;
    wire nv_dirty,nv_save_req;wire [15:0] nv_save_data;
    wire [15:0] ioctl_index,ioctl_dout;
    wire [26:0] ioctl_addr;wire cpu_clk,ram_clk,dsp_clk,locked;
    // Match the framework service/OSD clock to the video consumer domain.
    wire hps_clk=dsp_clk;
    // The HPS services share the DSP-local cold-reset release.
    wire hps_reset=video_reset;
    gs_pll core_clock(.clk_50(CLK_50M),.reset(1'b0),
        .cpu_clk(cpu_clk),.ram_clk(ram_clk),.dsp_clk(dsp_clk),.locked(locked));
    (* altera_attribute="-name SYNCHRONIZER_IDENTIFICATION FORCED" *) reg [2:0] cold_release=3'b111;
    always @(posedge ram_clk or negedge locked)begin
        if(!locked)cold_release<=3'b111;else cold_release<={cold_release[1:0],1'b0};
    end
    wire cold_reset=cold_release[2];
    hps_io #(.CONF_STR(CONF_STR),.WIDE(1)) hps_io(
        .clk_sys(hps_clk),.HPS_BUS(HPS_BUS[45:0]),.EXT_BUS(),.gamma_bus(gamma_bus),
        .forced_scandoubler(forced_scandoubler),.buttons(buttons),.status(status),
        .status_menumask({28'b0,1'b1,direct_video,(direct_video || HDMI_WIDTH==0 || HDMI_HEIGHT==0),!status[5]}),
        .direct_video(direct_video),
        .joystick_0(joystick),.joystick_1(joystick2),.joystick_l_analog_0(analog_stick),
        .ioctl_download(ioctl_download),.ioctl_wr(ioctl_wr),.ioctl_index(ioctl_index),
        .ioctl_addr(ioctl_addr),.ioctl_dout(ioctl_dout),.ioctl_wait(ioctl_wait),
        .ioctl_upload(ioctl_upload),.ioctl_upload_req(nv_save_req),
        .ioctl_upload_index(8'd254),.ioctl_din(combined_save_data));
    wire loader_download,score_download,score_upload;
    wire [15:0] loader_index,score_index,combined_save_data;
    wire [26:0] score_address,nv_save_address;
    gs_nv_image save_image(.download(ioctl_download),.upload(ioctl_upload),.index(ioctl_index),.address(ioctl_addr),
        .eeprom_data(nv_save_data),.score_data(16'b0),.loader_download(loader_download),
        .score_download(score_download),.score_upload(score_upload),.loader_index(loader_index),
        .score_index(score_index),.save_data(combined_save_data),.score_address(score_address),.nv_save_address(nv_save_address));
    // Keep the EEPROM at bytes 0..127 and zero-fill the legacy score tail.
    // Existing 528-byte NVRAM files remain readable without score persistence.
    wire dl_req,dl_write,dl_ack,nv_req,nv_ack,rom_ready,loader_ready,loader_fault;
    wire [24:0] dl_addr;wire [15:0] dl_data,nv_data;wire [1:0] dl_bytes;wire [5:0] nv_addr;
    wire load_req,load_write,load_ack;
    wire [24:0] load_addr;wire [15:0] load_data;wire [1:0] load_bytes;
    // ROM traffic remains in RAM64. Hold each host-domain tuple until the
    // established request/reply bridge confirms its RAM-domain completion.
    gs_bus_cdc download_bridge(.cpu_clk(hps_clk),.ram_clk(ram_clk),.reset(cold_reset),
        .cpu_req(load_req),.cpu_write(load_write),.cpu_addr(load_addr),
        .cpu_wdata(load_data),.cpu_bytes(load_bytes),.cpu_write_line(1'b0),.cpu_wline(64'b0),
        .cpu_ack(load_ack),.cpu_idle(),.cpu_rdata(),.cpu_rline(),
        .ram_req(dl_req),.ram_write(dl_write),.ram_addr(dl_addr),
        .ram_wdata(dl_data),.ram_bytes(dl_bytes),.ram_write_line(),.ram_wline(),
        .ram_ack(dl_ack),.ram_rdata(16'b0),.ram_rline(64'b0));
    // Cut save-image index translation from loader validation. Raw HPS write
    // lookahead above holds the next word while this registered tuple advances.
    (* preserve *) reg loader_download_q=0,loader_wr_q=0;
    (* preserve *) reg [15:0] loader_index_q=0,loader_data_q=0;
    (* preserve *) reg [26:0] loader_addr_q=0;
    always @(posedge hps_clk) begin
        loader_download_q<=loader_download;loader_wr_q<=ioctl_wr;
        loader_index_q<=loader_index;loader_addr_q<=ioctl_addr;loader_data_q<=ioctl_dout;
        if(hps_reset)begin loader_download_q<=0;loader_wr_q<=0;end
    end
    gs_download loader(.clk(hps_clk),.cold_reset(hps_reset),
        .ioctl_download(loader_download_q),.ioctl_wr(loader_wr_q),.ioctl_index(loader_index_q),
        .ioctl_addr(loader_addr_q),.ioctl_dout(loader_data_q),.ioctl_wait(loader_wait),
        .mem_req(load_req),.mem_write(load_write),.mem_addr(load_addr),.mem_wdata(load_data),.mem_bytes(load_bytes),.mem_ack(load_ack),
        .nv_req(nv_req),.nv_addr(nv_addr),.nv_data(nv_data),.nv_ack(nv_ack),
        .rom_loaded(),.eeprom_loaded(),.ready(loader_ready),.fault(loader_fault));
    // Hold the game until loader completion has entered its RAM clock domain.
    // Decode locally in HPS96; cross only a registered level, then release in RAM64.
    (* preserve *) reg loader_ready_q=0;
    // Keep the decoded diagnostic level in HPS96 before the RAM64 crossing.
    // Loader validity/readiness still uses its immediate fault internally.
    (* preserve *) reg loader_fault_q=0;
    (* preserve *) reg [1:0] ready_ram=0;
    always @(posedge hps_clk) begin
        loader_ready_q<=loader_ready;
        loader_fault_q<=loader_fault;
        if(hps_reset)loader_ready_q<=0;
        if(hps_reset)loader_fault_q<=0;
    end
    always @(posedge ram_clk) begin
        ready_ram<={ready_ram[0],loader_ready_q};
        if(cold_reset)ready_ram<=0;
    end
    assign rom_ready=ready_ram[1];
    wire nv_wr;wire [5:0] nv_word_addr;wire [15:0] nv_word_data;
    gs_nv_bridge nv_upload(.ram_clk(hps_clk),.cpu_clk(cpu_clk),.cold_reset(hps_reset),
        .req(nv_req),.addr(nv_addr),.data(nv_data),.ack(nv_ack),
        .nvram_ld_wr(nv_wr),.nvram_ld_addr(nv_word_addr),.nvram_ld_data(nv_word_data));
    // Assert reset immediately; release it through the game RAM clock domain.
    wire reset_request=RESET || status[0] || buttons[1] || cold_reset;
    (* preserve *) reg [1:0] game_release=2'b11;
    always @(posedge ram_clk or posedge reset_request) begin
        if(reset_request)game_release<=2'b11;
        else game_release<={game_release[0],1'b0};
    end
    wire game_reset=game_release[1];
    // DSP-clock video and HPS services release cold reset in their own domain.
    (* preserve *) reg [1:0] video_release=2'b11;
    always @(posedge dsp_clk or posedge cold_reset) begin
        if(cold_reset)video_release<=2'b11;
        else video_release<={video_release[0],1'b0};
    end
    wire video_reset=video_release[1];
    gs_nv_save nv_save(.cpu_clk(cpu_clk),.ram_clk(hps_clk),.cold_reset(hps_reset),
        .ready(loader_ready),.nvram_dirty(nv_dirty),.osd_open(OSD_STATUS),.ioctl_upload(ioctl_upload),
        .ioctl_index(ioctl_index),.ioctl_addr(nv_save_address),.upload_req(nv_save_req));
    wire pause_game;
    wire [7:0] in0,in2;
    wire [7:0] stick_x_mapped,stick_y_mapped;
    wire [7:0] cabinet_in2;
    wire service_active,button_paused,main_req,main_ack,main_write;
    wire [31:0] main_addr;wire [1:0] main_bytes;
    gs_osd_controls osd_controls(.clk(cpu_clk),.reset(game_reset),.osd_open(OSD_STATUS),
        .ram_clk(ram_clk),.manual_pause(status[1]),.osd_pause_disabled(status[2]),.pause_game(pause_game),
        .service_trigger(status[28]),.pause_button(joystick[12]),
        .cpu_req(main_req),.cpu_ack(main_ack),.cpu_write(main_write),
        .cpu_addr(main_addr),.cpu_bytes(main_bytes),.service_active(service_active),.button_paused(button_paused));
    assign in2=cabinet_in2 & {7'b1111111,!service_active};
    // No score extractor, RAM bus master or score-induced pause remains.
    assign hs_wait=1'b0;
    wire hs_ack,hs_paused;
    wire [15:0] hs_mem_reply;
    // HPS runs at 96 MHz. Capture analog data on the opposite CPU edge
    // so ADC registers avoid a coincident-edge minimum-delay path.
    (* preserve *) reg [15:0] analog_cpu=0;
    always @(negedge cpu_clk) analog_cpu<=analog_stick;
    // OSD control options are static levels; capture them with the stick.
    (* preserve *) reg [2:0] control_cpu=0;
    always @(negedge cpu_clk) control_cpu<=status[33:31];
    // CPU speed is a static OSD level (0=Fast default). TG68K needs ~1.6x the
    // time of MAME's 68020 per game tick, so 16 MHz slows busy scenes beyond
    // the PCB. Retime onto the rising edge before it
    // reaches the CPU enable so it adds only a full-cycle register path.
    (* preserve *) reg turbo_neg=0,cpu_turbo=0;
    always @(negedge cpu_clk) turbo_neg<=!status[34];
    always @(posedge cpu_clk) cpu_turbo<=turbo_neg;
    gs_mister_controls controls(.joystick(joystick),.joystick2(joystick2),
        .analog_stick(analog_cpu),.invert_y(!control_cpu[0]),.sensitivity(control_cpu[2:1]),.in0(in0),.in2(cabinet_in2),.stick_x(stick_x_mapped),.stick_y(stick_y_mapped));
    // Register the scaled/inverted/saturated stick on the same falling edge:
    // the mapping gets a full CPU cycle and only a register-to-register
    // half cycle remains into the rising-edge ADC result latch.
    (* preserve *) reg [7:0] stick_x=8'h80,stick_y=8'h80;
    always @(negedge cpu_clk) begin stick_x<=stick_x_mapped;stick_y<=stick_y_mapped;end
    wire [23:0] rgb;wire game_ce,game_hs,game_vs,game_hb,game_vb,initialized;
    wire pcm_valid;wire signed [15:0] pcm_l,pcm_r;wire audio_fault,deadline_fault;
    gs_game #(.SYS_HZ(64000000),.FULL_AUDIO(1),.LIVE_DOWNLOAD(1),.OSD_FEATURES(1),.LINE_WRITES(`GS_CPU_WRITE_LINES)) game(
        .cpu_clk(cpu_clk),.ram_clk(ram_clk),.dsp_clk(dsp_clk),.cold_reset(cold_reset),
        .reset(game_reset),.rom_ready(rom_ready),.pause(pause_game),.screen_flip(status[30]),.cpu_turbo(cpu_turbo),.affine_mame(1'b0),
        .hs_req(1'b0),.hs_write(1'b0),.hs_addr(25'b0),.hs_data(16'b0),
        .hs_bytes(2'b0),.hs_ack(hs_ack),.hs_reply(hs_mem_reply),.hs_paused(hs_paused),
        .download_req(dl_req),.download_write(dl_write),.download_addr(dl_addr),
        .download_data(dl_data),.download_bytes(dl_bytes),.download_ack(dl_ack),
        .in0(in0),.in2(in2),.stick_x(stick_x),.stick_y(stick_y),
        .nvram_ld_wr(nv_wr),.nvram_ld_addr(nv_word_addr),.nvram_ld_data(nv_word_data),
        .nvram_sv_addr(ioctl_addr[6:1]),.nvram_sv_data(nv_save_data),.nvram_dirty(nv_dirty),
        .pcm_valid(pcm_valid),.pcm_l(pcm_l),.pcm_r(pcm_r),.audio_fault(audio_fault),
        .pixel_rgb(rgb),.pixel_ce(),.native_visible_ce(),.scan_valid(),.scan_index(),
        .video_ce(game_ce),.video_hsync(game_hs),.video_vsync(game_vs),.video_hblank(game_hb),.video_vblank(game_vb),
        .initialized(initialized),.frame_count(),.deadline_fault(deadline_fault),
        .main_debug_req(main_req),.main_debug_ack(main_ack),.main_debug_write(main_write),
        .main_debug_addr(main_addr),.main_debug_be(main_bytes),
        .SDRAM_DQ(SDRAM_DQ),.SDRAM_A(SDRAM_A),.SDRAM_BA(SDRAM_BA),.SDRAM_DQML(SDRAM_DQML),.SDRAM_DQMH(SDRAM_DQMH),
        .SDRAM_nCS(SDRAM_nCS),.SDRAM_nWE(SDRAM_nWE),.SDRAM_nRAS(SDRAM_nRAS),.SDRAM_nCAS(SDRAM_nCAS),
        .SDRAM_CKE(SDRAM_CKE),.SDRAM_CLK(SDRAM_CLK),
        .DDRAM_BUSY(game_ddr_busy),.DDRAM_BURSTCNT(game_ddr_burst),.DDRAM_ADDR(game_ddr_addr),
        .DDRAM_DOUT(ddr_read_data),.DDRAM_DOUT_READY(game_ddr_ready),.DDRAM_RD(game_ddr_rd),
        .DDRAM_DIN(game_ddr_din),.DDRAM_BE(game_ddr_be),.DDRAM_WE(game_ddr_we));
    assign DDRAM_CLK=ram_clk;
    // Capture HPS read returns before distributing them to cache RAM inputs.
    // Delay valid with data; command acceptance and burst ordering stay intact.
    (* preserve *) reg [63:0] ddr_read_data;
    (* preserve *) reg ddr_read_valid=0;
    always @(posedge ram_clk) begin
        ddr_read_data<=DDRAM_DOUT;
        ddr_read_valid<=DDRAM_DOUT_READY;
        if(cold_reset)ddr_read_valid<=0;
    end
    wire game_ddr_busy,game_ddr_ready,game_ddr_rd,game_ddr_we;
    wire [7:0] game_ddr_burst,game_ddr_be;wire [28:0] game_ddr_addr;wire [63:0] game_ddr_din;
    wire rotate_we,rotate_busy,rotate_overflow;wire [28:0] rotate_addr;
    wire [63:0] rotate_data;wire [7:0] rotate_be;
    wire raw_rotate_we;wire [28:0] raw_rotate_addr;wire [63:0] raw_rotate_data;wire [7:0] raw_rotate_be;
    wire [1:0] ddr_client_busy,ddr_client_ready;
    assign game_ddr_busy=ddr_client_busy[0];assign game_ddr_ready=ddr_client_ready[0];
    assign rotate_busy=ddr_client_busy[1];
    gs_ddr_write_queue rotate_queue(.clk(ram_clk),.reset(cold_reset),.push(raw_rotate_we),
        .address(raw_rotate_addr),.data(raw_rotate_data),.bytes(raw_rotate_be),
        .we(rotate_we),.out_address(rotate_addr),.out_data(rotate_data),.out_bytes(rotate_be),
        .busy(rotate_busy),.overflow(rotate_overflow));
    // The game port aggregates audio/video reads. Preserve both outstanding
    // bursts and forward old replies so its child arbiter can drain reset.
    gs_ddr_arb2 #(.PIPELINED_CLIENTS(2'b01),.FORWARD_DRAIN(2'b01)) output_ddr(.clk(ram_clk),.reset(cold_reset),
        .rd({1'b0,game_ddr_rd}),.we({rotate_we,game_ddr_we}),
        .burstcnt({8'd1,game_ddr_burst}),.addr({rotate_addr,game_ddr_addr}),
        .din({rotate_data,game_ddr_din}),.be({rotate_be,game_ddr_be}),
        .busy(ddr_client_busy),.dout_ready(ddr_client_ready),.dout(),
        .DDRAM_BUSY(DDRAM_BUSY),.DDRAM_BURSTCNT(DDRAM_BURSTCNT),.DDRAM_ADDR(DDRAM_ADDR),
        .DDRAM_DOUT(ddr_read_data),.DDRAM_DOUT_READY(ddr_read_valid),.DDRAM_RD(DDRAM_RD),
        .DDRAM_DIN(DDRAM_DIN),.DDRAM_BE(DDRAM_BE),.DDRAM_WE(DDRAM_WE));
    // Like the standard arcade frontend, capture native pixels before CRT
    // geometry/scandoubling. Rotation never multiplies its DDR write rate.
    // Capture service-domain mode bits before RAM-domain address decode.
    (* preserve *) reg [2:0] rotate_control_ram=0;
    always @(posedge ram_clk) begin
        rotate_control_ram<={direct_video,rotation};
        if(cold_reset)rotate_control_ram<=0;
    end
    screen_rotate output_rotation(.CLK_VIDEO(ram_clk),.CE_PIXEL(game_video?game_ce:idle_ce),
        .VGA_R(rgb[23:16]),.VGA_G(rgb[15:8]),.VGA_B(rgb[7:0]),
        .VGA_HS(game_video?game_hs:idle_x<32),.VGA_VS(game_video?game_vs:idle_y<4),
        .VGA_DE(game_video && !(game_hb || game_vb)),
        .rotate_ccw(rotate_control_ram[1:0]==2),.no_rotate(rotate_control_ram[2] || rotate_control_ram[1:0]==0 || rotate_control_ram[1:0]==3),.flip(1'b0),.video_rotated(),
        .FB_EN(FB_EN),.FB_FORMAT(FB_FORMAT),.FB_WIDTH(FB_WIDTH),.FB_HEIGHT(FB_HEIGHT),
        .FB_BASE(FB_BASE),.FB_STRIDE(FB_STRIDE),.FB_VBL(FB_VBL),.FB_LL(FB_LL),
        .DDRAM_CLK(),.DDRAM_BUSY(1'b0),.DDRAM_BURSTCNT(),.DDRAM_ADDR(raw_rotate_addr),
        .DDRAM_DIN(raw_rotate_data),.DDRAM_BE(raw_rotate_be),.DDRAM_WE(raw_rotate_we),.DDRAM_RD());
    assign FB_FORCE_BLANK=rotate_overflow;
    // Board output normalization belongs after the native DSP/AUX mix and
    // volume controls, so music, effects and stereo retain their relative gain.
    // 21/8 gain is 31.25% above the former x2 output. Above 3/4 scale,
    // compress peaks at 16:1 instead of hard clipping. Even full-scale input
    // stays below 28417 (1.2 dB headroom). Magnitude arithmetic is symmetric.
    function automatic [15:0] output_level(input signed [15:0] sample);
        reg [19:0] magnitude,amplified;
        reg [15:0] level;
        begin
            magnitude=sample[15] ? -$signed({{4{sample[15]}},sample}) : {4'b0,sample};
            amplified=((magnitude << 4)+(magnitude << 2)+magnitude) >> 3;
            level=amplified>20'd24576 ? 20'd24576+((amplified-20'd24576) >> 4) : amplified;
            output_level=sample[15] ? -$signed(level) : level;
        end
    endfunction
    assign AUDIO_L=game_reset || !rom_ready ? 16'b0 : output_level(pcm_l);
    assign AUDIO_R=game_reset || !rom_ready ? 16'b0 : output_level(pcm_r);
    wire idle_raw_ce;wire [8:0] idle_raw_x,idle_raw_y;
    reg idle_ce=0;reg [8:0] idle_x=0,idle_y=0;
    always @(posedge ram_clk)begin idle_ce<=idle_raw_ce;idle_x<=idle_raw_x;idle_y<=idle_raw_y;end
    gs_raster #(.PRESENT_15K(1)) idle_raster(.clk(ram_clk),.reset(cold_reset),.pixel_ce(idle_raw_ce),.x(idle_raw_x),.y(idle_raw_y),
        .visible(),.frame_cut(),.frame_start());
    wire game_video=initialized && rom_ready && !game_reset;
    // Capture configuration locally before video decode/fanout.
    // These harmonic clocks remain normally timed; no CDC exception is used.
    (* preserve *) reg [21:5] video_status=0;
    (* preserve *) reg video_forced_scandoubler=0;
    always @(posedge dsp_clk) begin
        video_status<=status[21:5];
        video_forced_scandoubler<=forced_scandoubler;
        if(video_reset)begin video_status<=0;video_forced_scandoubler<=0;end
    end
    wire crt_enable;
    wire signed [4:0] crt_size;
    wire signed [8:0] crt_hpos;
    wire signed [5:0] crt_vpos;
    gs_crt_controls crt_controls(.raw(video_status[19:5]),.enable(crt_enable),
        .hsize(crt_size),.hoffset(crt_hpos),.voffset(crt_vpos));
    wire crt_ce,crt_hs,crt_vs,crt_hb,crt_vb;wire [23:0] crt_rgb;
    wire stable_ce,stable_hs,stable_vs,stable_hb,stable_vb,stable_fault;
    wire [23:0] stable_rgb;
    // Game and idle rasters share one root and one free-running /8 phase.
    // game_ce remains live during reset/pause; never mux pixel enable phases.
    assign stable_ce=game_ce;
    assign stable_rgb=game_video?rgb:24'b0;
    assign stable_hs=game_video?game_hs:idle_x<32;
    assign stable_vs=game_video?game_vs:idle_y<4;
    assign stable_hb=game_video?game_hb:(idle_x<96 || idle_x>=416);
    assign stable_vb=game_video?game_vb:(idle_y<16 || idle_y>=248);
    assign stable_fault=1'b0;
    gs_crt_video #(.PIXEL_UNITS(192),.HTOTAL(512),.VTOTAL(260),.FIXED_OUTPUT(1)) geometry(.clk(dsp_clk),.reset(video_reset),.enable(crt_enable),
        .ce_in(stable_ce),.hsize(crt_size),.hoffset(crt_hpos),
        .voffset(crt_vpos),
        .rgb_in(stable_rgb),.hs_in(stable_hs),.vs_in(stable_vs),.hb_in(stable_hb),.vb_in(stable_vb),
        .ce_out(crt_ce),.rgb_out(crt_rgb),.hs_out(crt_hs),.vs_out(crt_vs),
        .hb_out(crt_hb),.vb_out(crt_vb),.ce2_out(scan_ce));
    wire scandoubled=video_forced_scandoubler || (video_status[21:20]!=0);
    wire scan_ce;
    wire mixed_de;
    gs_video_mixer #(.LINE_LENGTH(320),.GAMMA(1)) video(
        .CLK_VIDEO(dsp_clk),.CE_PIXEL(CE_PIXEL),.ce_pix(crt_ce),
        .reset(video_reset),.ce_pix2(scan_ce),
        .scandoubler(scandoubled),.hq2x(1'b0),.gamma_bus(gamma_bus),
        .R(crt_rgb[23:16]),.G(crt_rgb[15:8]),.B(crt_rgb[7:0]),
        .HSync(crt_hs),.VSync(crt_vs),.HBlank(crt_hb),.VBlank(crt_vb),
        .HDMI_FREEZE(1'b0),.freeze_sync(),.VGA_R(VGA_R),.VGA_G(VGA_G),.VGA_B(VGA_B),
        .VGA_HS(VGA_HS),.VGA_VS(VGA_VS),.VGA_DE(mixed_de));
    assign CLK_VIDEO=dsp_clk;
    wire [12:0] present_arx,present_ary;
    wire [33:0] present_settings;
    wire [11:0] present_width,present_height;
    wire present_direct,present_crop,present_scandoubled;
    wire [1:0] present_rotation,present_aspect;
    wire [2:0] present_scale;
    gs_video_settings presentation_settings(.clk(dsp_clk),.reset(video_reset),
        .raw({HDMI_WIDTH,HDMI_HEIGHT,direct_video,rotation,status[122:121],
              status[24:22],status[25],scandoubled}),.captured(present_settings));
    assign {present_width,present_height,present_direct,present_rotation,
            present_aspect,present_scale,present_crop,present_scandoubled}=present_settings;
    wire quarter_turn=!present_direct && (present_rotation==1 || present_rotation==2);
    assign VIDEO_ARX=quarter_turn ? present_ary : present_arx;
    assign VIDEO_ARY=quarter_turn ? present_arx : present_ary;
    gs_video_presentation presentation(.clk(dsp_clk),.ce(CE_PIXEL),.vs(VGA_VS),
        .de_in(mixed_de),.hdmi_width(quarter_turn ? present_height : present_width),.hdmi_height(quarter_turn ? present_width : present_height),
        .aspect(present_aspect),.scale(present_direct ? 3'd0 : present_scale),.crop(!present_direct && present_crop),
        .scandoubled(present_scandoubled),.de_out(VGA_DE),.arx(present_arx),.ary(present_ary));
    (* altera_attribute="-name SYNCHRONIZER_IDENTIFICATION FORCED" *) reg fault_s1,fault_s2;
    always @(posedge ram_clk)begin
        fault_s1<=audio_fault || deadline_fault || loader_fault_q || stable_fault || rotate_overflow;fault_s2<=fault_s1;
        if(cold_reset)begin fault_s1<=0;fault_s2<=0;end
    end
    assign LED_USER=fault_s2 || !rom_ready;
endmodule
