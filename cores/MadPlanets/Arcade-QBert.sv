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

module emu
(
	`include "sys/emu_ports.vh"
);

///////// Default values for ports not used in this core /////////

assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;
assign {SDRAM_DQ, SDRAM_A, SDRAM_BA, SDRAM_CLK, SDRAM_CKE, SDRAM_DQML, SDRAM_DQMH, SDRAM_nWE, SDRAM_nCAS, SDRAM_nRAS, SDRAM_nCS} = 'Z;
assign {FB_PAL_CLK, FB_FORCE_BLANK, FB_PAL_ADDR, FB_PAL_DOUT, FB_PAL_WR} = '0;

assign VGA_F1 = 0;
assign VGA_SCALER = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;

assign AUDIO_S = 1;
assign AUDIO_MIX = 3;

assign LED_USER  = ioctl_download;
assign LED_DISK = 0;
assign LED_POWER = 0;
assign BUTTONS = 0;

//////////////////////////////////////////////////////////////////

wire [1:0] ar = status[9:8];

assign VIDEO_ARX = (!ar) ? ((no_rotate) ? 8'd8 : 8'd7) : (ar - 1'd1);
assign VIDEO_ARY = (!ar) ? ((no_rotate) ? 8'd7 : 8'd8) : 12'd0;

`include "build_id.v"
localparam CONF_STR = {
  "MadPlanetsTwinStick;;",
  "-;",
  //"F0,bin,Rom Load;",
  "H0O89,Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
  "O5,Orientation,Vert,Horz;",
  "OFH,Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;",
  "OB,Flip Screen,Off,On;",
//  "OC,HFlip,Off,On;",
  "-;",
  "O6,Test mode,Off,On;",
  "O7,Original column bug,Off,On;",
  "OA,Diagonal joystick,Off,On;",
  "OE,Pause,Off,On;",
  "OCD,Trackball speed,25%,50%,100%;",
  "OIJ,Aim Speed,Normal,Slow,Instant;",
  "OK,Aim Auto Fire,Off,On;",
  "OLM,Aim Deadzone,Normal,Small,Large,Extra Large;",
  "ON,Score Autosave,On,Off;",
  "-;",
  "DIP;",
  "-;",
  "R0,Reset and close OSD;",
  "J1,Fire,Start 1P,Start 2P,Coin,Pause,Service Select;",
	"jn,A,Start,Select,R;",
	"jp,B,Start,,Select;",
  "V,v",`BUILD_DATE
};

wire forced_scandoubler;
wire direct_video;
wire [21:0] gamma_bus;
wire  [1:0] buttons;
wire [31:0] status;
wire [10:0] ps2_key;
wire pause_osd = status[14];
wire pause = pause_osd | pause_toggle;

wire        ioctl_wr;
wire [24:0] ioctl_addr;
wire  [7:0] ioctl_dout;
wire        ioctl_download;
wire        ioctl_upload,ioctl_upload_req;
wire  [7:0] ioctl_din;
wire  [7:0] ioctl_index;
wire        ioctl_wait;

wire [15:0] joystick_0;
wire [15:0] joystick_1;
wire [15:0] joystick_analog_0;
wire [15:0] joystick_right_0;
reg pause_toggle;
reg pause_btn_last;

wire [8:0]  spinner_0;
wire [24:0] ps2_mouse;

hps_io #(.CONF_STR(CONF_STR)) hps_io
(
  .clk_sys(clk_sys),
  .HPS_BUS(HPS_BUS),
  .EXT_BUS(),

  .gamma_bus(gamma_bus),
  .direct_video(direct_video),
	.video_rotated(video_rotated),

  .forced_scandoubler(forced_scandoubler),

  .buttons(buttons),
  .status(status),
  .status_menumask({direct_video}),

  .ps2_key(ps2_key),
  .ps2_mouse(ps2_mouse),

  .ioctl_download(ioctl_download),
  .ioctl_upload(ioctl_upload),
  .ioctl_upload_req(ioctl_upload_req),
  .ioctl_upload_index(8'd4),
  .ioctl_din(ioctl_din),
  .ioctl_wr(ioctl_wr),
  .ioctl_addr(ioctl_addr),
  .ioctl_dout(ioctl_dout),
  .ioctl_wait(ioctl_wait),
  .ioctl_index(ioctl_index),

  .joystick_0(joystick_0),
  .joystick_1(joystick_1),

  .joystick_l_analog_0(joystick_analog_0),
  .joystick_r_analog_0(joystick_right_0),
  .spinner_0(spinner_0)
);

///////////////////////   CLOCKS   ///////////////////////////////

// ** Video
// XTAL = 20M
// CLK = 10M
// HCLK = 5M
// ** CPU
// XTAL = 15M
// CPU_CLK from 8284 = 5M

wire clk_50_unused, clk_40, clk_25, core_clk;
wire clk_sys = clk_40;
pll pll
(
  .refclk(CLK_50M),
  .rst(0),
  .outclk_0(clk_50_unused), // clock plan: clk_sys == CLK_VIDEO == clk_40 (8x 5MHz pixel)
  .outclk_1(clk_40),   // rotation 40MHz + video 10MHz & 5MHz
  .outclk_2(clk_25),
  .outclk_3(core_clk)
);

reg [3:0] cnt1;
reg cpu_clk; // clock enable
always @(posedge clk_sys) begin
  cnt1 <= cnt1 + 5'd1;
  if (cnt1 == 5'd7) begin
    cnt1 <= 5'd0;
    cpu_clk <= 1'b1;
  end
  else cpu_clk <= 1'b0;
end

wire mad_cpu_enable,mad_cpu_paused,mad_bus_idle;
wire hs_pause,hs_write,hs_read_intent,hs_write_intent,hs_configured;
wire [11:0] hs_address;
wire [7:0] hs_data_from_ram,hs_data_to_ram;
// Registered: the score-save RAM select feeds the 100 MHz CPU data-in mux, so a combinational
// reset/mod/paused term would be timed across the 40->100 MHz PLL outputs. The hiscore state machine
// asserts its intent several clocks before the first access and keeps the CPU paused for ACCESS_PAUSEPAD
// clocks after the last one, so the single-clock lag on both edges is covered.
reg hs_access=1'b0;
always @(posedge clk_sys) hs_access <= (mod==mod_mplanets) && mad_cpu_paused && !reset && !rom_init && (hs_read_intent || hs_write_intent);
wire hs_ram_write=hs_access && hs_write_intent && hs_write;
wire cpu_clk_pause=(mod==mod_mplanets) ? mad_cpu_enable : (pause ? 1'b0 : cpu_clk);
madplanets_pause_grant mad_grant(.clk(core_clk),.reset(reset),.request(pause | hs_pause),
 .pulse_in(cpu_clk),.bus_idle(mad_bus_idle),.cpu_enable(mad_cpu_enable),.paused(mad_cpu_paused));
hiscore #(.HS_ADDRESSWIDTH(12),.HS_SCOREWIDTH(12),.HS_DUMP_BYTES(4096),.CFG_ADDRESSWIDTH(3),.CFG_LENGTHWIDTH(2)) hi(
 .clk(clk_sys),.paused(mad_cpu_paused),.reset(reset | rom_init),.autosave(!status[23]),
 .ioctl_upload(ioctl_upload),.ioctl_upload_req(ioctl_upload_req),.ioctl_download(ioctl_download),
 .ioctl_wr(ioctl_wr),.ioctl_addr(ioctl_addr),.ioctl_index(ioctl_index),.OSD_STATUS(OSD_STATUS),
 .data_from_hps(ioctl_dout),.data_from_ram(hs_data_from_ram),.ram_address(hs_address),
 .data_to_hps(ioctl_din),.data_to_ram(hs_data_to_ram),.ram_write(hs_write),
 .ram_intent_read(hs_read_intent),.ram_intent_write(hs_write_intent),.pause_cpu(hs_pause),.configured(hs_configured));

// derive sound clock from clk_sys
// PCB sound 6502: 3.579545MHz/4 = 894886.25Hz = clk_sys(40MHz) * 715909/32000000
reg [24:0] cnt2 = 25'd0;
reg sound_clk;
wire [25:0] cnt2_next = {1'b0,cnt2} + 26'd715909;
always @(posedge clk_sys) begin
  sound_clk <= 1'b0;
  if (cnt2_next >= 26'd32000000) begin
    cnt2 <= cnt2_next - 26'd32000000;
    sound_clk <= 1'b1;
  end else cnt2 <= cnt2_next[24:0];
end

reg [1:0] cnt3;
always @(posedge clk_40)
  cnt3 <= cnt3 + 2'd1;

wire clk_10 = cnt3[1];

reg clk_5;
always @(posedge clk_10)
  clk_5 <= ~clk_5;


wire reset = RESET | status[0] | buttons[1];

always @(posedge clk_sys) begin
  pause_btn_last <= joystick_0[8];

  if(reset) begin
    pause_toggle <= 1'b0;
  end
  else begin
    // Rising edge of Pause button
    if(joystick_0[8] && !pause_btn_last)
      pause_toggle <= ~pause_toggle;
  end
end

//////////////////////////////////////////////////////////////////

// Reactor trackball: accumulate mouse deltas into 8-bit counters.
// The game reads IPA1J2/IPA1J2_Y as the delta since the last analog_reset
// (write to 0x7001), so we zero the counters on each analog_reset pulse.
// Joystick D-pad also feeds the counters at VBlank rate as fallback.
reg        ps2_strobe_r;
reg [7:0]  trackball_x;
reg [7:0]  trackball_y;
reg        vblank_r;
wire       analog_rst_n;  // from mylstar_board: low during write to 0x7001
reg        analog_rst_r;

// Trackball speed scaling (status[13:12]): 50% / 100% / 200% / 400%
// Arithmetic right-shift preserves sign for 50%; left-shift wraps for 200/400%
// which is fine since the 8-bit counter wraps anyway.
wire signed [7:0] tb_raw_x =  $signed(ps2_mouse[15:8]);
wire signed [7:0] tb_raw_y = -$signed(ps2_mouse[23:16]); // invert: PS/2 up = game -Y
wire signed [7:0] tb_dx = (status[13:12] == 2'd0) ? tb_raw_x >>> 2 :  // 25%
                           (status[13:12] == 2'd1) ? tb_raw_x >>> 1 :  // 50%
                           tb_raw_x;                                     // 100% (2 and 3)
wire signed [7:0] tb_dy = (status[13:12] == 2'd0) ? tb_raw_y >>> 2 :  // 25%
                           (status[13:12] == 2'd1) ? tb_raw_y >>> 1 :  // 50%
                           tb_raw_y;                                     // 100% (2 and 3)

always @(posedge clk_sys) begin
  ps2_strobe_r <= ps2_mouse[24];
  vblank_r     <= VBlank;
  analog_rst_r <= analog_rst_n;
  if (reset) begin
    trackball_x  <= 8'd0;
    trackball_y  <= 8'd0;
  end else if (reactor_r && !analog_rst_n && analog_rst_r) begin
    // Falling edge of analog_rst_n = game wrote to 0x7001 → reset counters
    trackball_x <= 8'd0;
    trackball_y <= 8'd0;
  end else if (ps2_mouse[24] != ps2_strobe_r) begin
    // New mouse/trackball packet: accumulate scaled X/Y deltas.
    trackball_x <= trackball_x + 8'(tb_dx);
    trackball_y <= trackball_y + 8'(tb_dy);
  end else if (VBlank && !vblank_r) begin
    // D-pad fallback at VBlank rate (~60 Hz)
    if      (joystick_0[0]) trackball_x <= trackball_x + 8'd4;
    else if (joystick_0[1]) trackball_x <= trackball_x - 8'd4;
    if      (joystick_0[2]) trackball_y <= trackball_y + 8'd4;
    else if (joystick_0[3]) trackball_y <= trackball_y - 8'd4;
  end
end

//////////////////////////////////////////////////////////////////

// read dip switches

reg [7:0] sw[8];
always @(posedge clk_sys) if (ioctl_wr && (ioctl_index==254) && !ioctl_addr[24:3]) sw[ioctl_addr[2:0]] <= ioctl_dout;

wire HBlank, VBlank;
wire HSync, VSync;

wire [5:0] OP2720;

localparam mod_qbert  		= 0;
localparam mod_qub    		= 1;
localparam mod_mplanets    = 2;
localparam mod_krull    = 3;
localparam mod_curvebal = 4;
localparam mod_tylz = 5;
localparam mod_insector = 6;
localparam mod_reactor = 7;

reg [7:0] mod = 255;
always @(posedge clk_sys) if (ioctl_wr & (ioctl_index==1)) mod <= ioctl_dout;

// Register reactor flag to break potential long combinatorial path
reg reactor_r;
always @(posedge clk_sys) reactor_r <= (mod == mod_reactor);


wire [7:0] IP1710;
wire [7:0] IP4740;
wire [7:0] IPA1J2;
reg  [7:0] IPA1J2_Y;
wire mad_angle_write,mad_bias_write,mad_dial_read;
wire [7:0] mad_cpu_data,mad_dial;
wire mad_pending,mad_fire;
wire [3:0] mad_angle,mad_target,mad_move;
wire [3:0] mad_defl,mad_update,left_defl,left_update;
wire [15:0] mad_direction;
wire [11:0] left_direction;
wire [5:0] mad_threshold=status[22:21]==0 ? 6'd32 : status[22:21]==1 ? 6'd13 : status[22:21]==2 ? 6'd38 : 6'd51;
reg [15:0] mad_ms_count=0;
wire mad_tick_ms=mad_ms_count==16'd39999;
always @(posedge clk_sys)begin
 if(reset || mad_tick_ms)mad_ms_count<=0;else mad_ms_count<=mad_ms_count+1'b1;
end
aim_quant16 mad_quant(.clk(clk_sys),.reset(reset),.ana({48'd0,joystick_right_0}),
 .thr({6'd25,6'd25,6'd25,mad_threshold}),.defl(mad_defl),.dir(mad_direction),.upd(mad_update));
snk_aim_quant4 mad_left_quant(.clk(clk_sys),.reset(reset),.ana({48'd0,joystick_analog_0}),
 .thr({4{6'd25}}),.inv_y(4'd0),.defl(left_defl),.dir(left_direction),.upd(left_update));
function [3:0] mad_compass(input [2:0] direction);
 case(direction)
  0:mad_compass=4'b1000;1:mad_compass=4'b1001;2:mad_compass=4'b0001;3:mad_compass=4'b0101;
  4:mad_compass=4'b0100;5:mad_compass=4'b0110;6:mad_compass=4'b0010;7:mad_compass=4'b1010;
 endcase
endfunction
assign mad_move=(mod==mod_mplanets && !pause && !hs_pause && left_defl[0]) ? mad_compass(left_direction[2:0]):4'd0;
wire [15:0] joystick_game=joystick_0 | {11'd0,mad_fire,mad_move};
madplanets_aim_servo mad_servo(.clk(clk_sys),.reset(reset),.paused(pause | hs_pause),.enable(mod==mod_mplanets),
 .tick_ms(mad_tick_ms),.stick_active(mad_defl[0]),.target_update(mad_update[0]),.target_angle(mad_direction[3:0]),
 .speed(status[19:18]),.angle_write(mad_angle_write),.bias_write(mad_bias_write),.angle_data(mad_cpu_data),.bias_data(mad_cpu_data),
 .dial_read(mad_dial_read),.dial_delta(mad_dial),.pending(mad_pending),.observed(mad_angle),.target(mad_target));
aim_autofire mad_af(.clk(clk_sys),.reset(reset),.paused(pause | hs_pause),.tick_ms(mad_tick_ms),
 .enable((mod==mod_mplanets) && status[20]),.stick_active(mad_defl[0]),.fire(mad_fire));


always @(*) begin

  IPA1J2   <= 8'd0;
  IPA1J2_Y <= 8'd0;

  IP1710 <= {
    joystick_0[4], // test 1
    ~status[6],    // test 2
    2'b0,
    joystick_0[7], // coin 1
    1'b0,//joystick_0[6], // coin 2
    joystick_0[6], // p2
    joystick_0[5]  // p1
  };

  if (~status[10]) begin
    IP4740 <= {
      4'b0,
      joystick_0[2], // left
      joystick_0[3], // right
      joystick_0[1], // up
      joystick_0[0]  // down
    };
  end

  case (mod)
    mod_qbert:
    begin
      if (status[10]) begin
        IP4740 <= {
          4'b0,
          joystick_0[2] & joystick_0[1], // left + up
          joystick_0[3] & joystick_0[0], // right + down
          joystick_0[1] & joystick_0[3], // up + right
          joystick_0[0] & joystick_0[2] // down + left
        };
      end
    end

    mod_qub:
    begin
    end

    mod_mplanets:
    begin
      IP1710 <= {
          ~status[6],    // test 2
          joystick_game[9], // test 1
          2'b0,
          1'b0,
          1'b0, // coin 1
          1'b0, // coin 2
          joystick_game[7]  // coin
      };

      IP4740 <= {
        1'b0, // unused input; joystick bit8 controls pause

        joystick_game[6], // p2
        joystick_game[5],  // p1

        joystick_game[4], // button 1
        joystick_game[1], // up
        joystick_game[2], // right
        joystick_game[0],  // down
        joystick_game[3] // left
      };
      
      IPA1J2 <= spinner_0[7:0];
      IPA1J2_Y <= mad_dial;
      
    end

    mod_krull:
    begin
    end

    mod_curvebal:
    begin
      IP1710 <= {
        2'b0,
        1'b0, // p2
        1'b0,//joystick_0[6],
        1'b0,// coin 2
        joystick_0[7], // coin 1
        joystick_0[8], // test 1
        ~status[6],    // test 2
      };

      IP4740 <= {
        1'b0, // n/a
        joystick_0[9], // bunt
        1'b0, // n/a
        joystick_0[11], // pitch right
        1'b0, // n/a
        joystick_0[10], // pitch left
        joystick_0[4], // swing
        1'b0
      };
    end

    mod_tylz:
    begin
      IP1710 <= { // IN1
        4'b0,
        joystick_0[7], // coin 1
        1'b0,//joystick_0[6], // coin 2
        joystick_0[4], // test 1
        ~status[6]

      };

      IP4740 <= { // IN4
        1'b0,
        joystick_0[6], // p2
        joystick_0[5],  // p1

        joystick_0[8], // button 1
        joystick_0[3], // right
        joystick_0[0], // down
        joystick_0[2], // left
        joystick_0[1]  // up
      };
    end
    mod_insector:
    begin
      IP1710 <= { // IN1
        1'b0,
        ~status[6],
        joystick_1[9],
        joystick_1[8],
        1'b0,//joystick_0[6], // coin 2
        joystick_0[7], // coin 1
        joystick_0[9],
        joystick_0[8]

      };

      IP4740 <= { // IN4

        joystick_1[1],
        joystick_1[2],
        joystick_1[0],
        joystick_1[3],


        joystick_0[1],
        joystick_0[2],
        joystick_0[0],
        joystick_0[3]
      };
    end
    mod_reactor:
    begin
      IP1710 <= { // IN1: service inputs
        4'b0,
        joystick_0[7], // coin 1
        1'b0,
        ~status[6],       // service DIP (active-low): OSD Test mode enters service mode
        joystick_0[4]     // test button (active-high per MAME IN1 bit0 IP_ACTIVE_HIGH): fire/"Service Select"
      };

      // IN2: trackball H (game X = right/left)
      // trackball_x is an 8-bit counter accumulated from mouse/trackball or D-pad.
      IPA1J2 <= trackball_x;

      // IN3: trackball V (game Y = up/down)
      IPA1J2_Y <= trackball_y;

      IP4740 <= { // IN4: buttons and start
        2'b0,
        joystick_0[6],                          // coin 2
        joystick_0[7],                          // coin 1 (also in IP1710)
        joystick_0[4] | ps2_mouse[0],           // button 1 (fire) + trackball left
        joystick_0[5] | ps2_mouse[1],           // button 2        + trackball right
        joystick_0[6],                          // start 2P
        joystick_0[5] | ps2_mouse[0]            // start 1P        + trackball left
      };
    end

    default:
    begin
    end
  endcase
end

wire [15:0] audio_votrax;
wire [15:0] audio_dac;
wire [7:0] red, green, blue;

assign AUDIO_L = audio_votrax;
assign AUDIO_R = audio_dac;

wire rom_init = ioctl_download && (ioctl_index==0);

// Timing: the CPU data-in mux is captured by the 100 MHz CPU core clock but its inputs are 40 MHz
// registers (5 ns edge window). These inputs change slowly (input state, game select, ROM download), so
// register them once in the capturing domain / pipeline the download stream as one unit.
reg [7:0] IP1710_c,IP4740_c,IPA1J2_c,IPA1J2_Y_c,sw0_c; reg reactor_c;
always @(posedge core_clk) begin IP1710_c<=IP1710; IP4740_c<=IP4740; IPA1J2_c<=IPA1J2; IPA1J2_Y_c<=IPA1J2_Y; sw0_c<=sw[0]; reactor_c<=reactor_r; end
reg rom_init_q; reg [24:0] ioctl_addr_q; reg [7:0] ioctl_dout_q;
always @(posedge clk_sys) begin rom_init_q<=rom_init; ioctl_addr_q<=ioctl_addr; ioctl_dout_q<=ioctl_dout; end

mylstar_board mylstar_board
(
  .clk_sys(clk_sys),
  .reset(reset),

  .CLK(clk_10),
  .CLK5(clk_5),

  .CPU_CORE_CLK(core_clk),
  .CPU_CLK(cpu_clk_pause),

  .red(red),
  .green(green),
  .blue(blue),

  .IP1710(IP1710_c),
  .IP4740(IP4740_c),
  .IPA1J2(IPA1J2_c),
  .IPA1J2_Y(IPA1J2_Y_c),
  .analog_rst_n(analog_rst_n),
  .mad_angle_write(mad_angle_write),.mad_bias_write(mad_bias_write),
  .mad_dial_read(mad_dial_read),.mad_cpu_data(mad_cpu_data),
  .mad_bus_idle(mad_bus_idle),.hs_access(hs_access),.hs_write(hs_ram_write),
  .hs_address(hs_address),.hs_data_in(hs_data_to_ram),.hs_data_out(hs_data_from_ram),
  .OP2720(OP2720),
  .OP3337(),

  .dip_switch(sw0_c),

  .rom_init(rom_init_q),
  .rom_init_address(ioctl_addr_q[17:0]),
  .rom_init_data(ioctl_dout_q),
  .rom_index(ioctl_index),
  
  .reactor(reactor_c),

  .vflip(status[11]),
  .hflip(status[11])
);

// audio board
ma216_board ma216_board(
  .clk(sound_clk),
  .clk_sys(clk_sys),
  .reset(reset),
  .IP2720(OP2720),
  .audio_votrax(audio_votrax),
  .audio_dac(audio_dac),
  .rom_init(rom_init_q),
  .rom_init_address(ioctl_addr_q[17:0]),
  .rom_init_data(ioctl_dout_q)
);

// 256x240 15KHz 60Hz


// copying fx into a register
// fixes a timing problem
reg [2:0]fx;
always @(posedge clk_sys)
begin
  fx <= status[17:15];
end



wire rotate_ccw = 1'b1;
wire no_rotate = status[5] | (mod==mod_tylz) | (mod==mod_insector) | (mod==mod_reactor) | direct_video;
//wire scandoubler = (status[17:15] || forced_scandoubler);
wire flip = 0;
wire video_rotated;
screen_rotate screen_rotate (.*);

arcade_video #(256,24,0) arcade_video
(
  .*,
  .clk_video(clk_sys),
  .RGB_in({ rgbout[23:16], rgbout[15:8], rgbout[7:0] })
);

wire [23:0] rgbout;
HVGEN hvgen(
  .vclk(clk_5),
  .rgbin({ red, green, blue }),
  .rgbout(rgbout),
  .hb(HBlank),
  .vb(VBlank),
  .hs(HSync),
  .vs(VSync),
  .colfix(~status[7])
);

// single-cycle 5MHz pixel enable, exactly one per eight clk_sys, locked to the clk_5 divider
reg clk_5_d;
always @(posedge clk_sys) clk_5_d <= clk_5;
wire ce_pix = clk_5 & ~clk_5_d;

endmodule

module HVGEN (
  input vclk,
  input [23:0] rgbin,
  output [23:0] rgbout,
  input colfix,
  output reg hb = 1,
  output reg vb = 1,
  output reg hs = 1,
  output reg vs = 1
);

wire [7:0] endhb = colfix ? 5 : 0;
reg [8:0] hcnt;
reg [7:0] vcnt;
assign rgbout = hb | vb ? 24'd0 : rgbin;
always @(posedge vclk) begin
  hcnt <= hcnt + 1'b1;
  case (hcnt)
    0: hb <= colfix ? 1'b1 : 1'b0; // keep hbl active if colfix
    5: hb <= 1'b0;
    255: hb <= 1'b1;
    283: hs <= 1'b0;
    303: hs <= 1'b1;
    317: begin
      vcnt <= vcnt + 1'b1;
      hcnt <= 1'b0;
      case (vcnt)
        239: vb <= 1'b1;
        251: vs <= 1'b0;
        254: vs <= 1'b1;
        255: begin vcnt <= 1'b0; vb <= 1'b0; end
      endcase
    end
  endcase
end

endmodule
