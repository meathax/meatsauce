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
 // One RBF, two runtime PLL settings (clock_plan.json pll_modes; snk_pll_mode): clk_sys = CLK_VIDEO = SDRAM clock.
 localparam integer MASTER_HZ = 96000000; // 16 MHz-crystal (late/sports) family: 12 x 8 MHz pixel
 localparam integer EARLY_HZ  = 93800000; // 13.4 MHz-crystal family (profiles 0..10, 14, 18): 14 x 6.7 MHz pixel
 assign ADC_BUS='Z;assign USER_OUT='1;
 assign {UART_RTS,UART_TXD,UART_DTR}=0;assign {SD_SCK,SD_MOSI,SD_CS}='Z;

 assign VGA_F1=0;assign VGA_SCALER=status[10];assign VGA_DISABLE=0;
 assign HDMI_FREEZE=0;assign HDMI_BLACKOUT=0;assign HDMI_BOB_DEINT=0;
 assign AUDIO_S=1;assign AUDIO_L=pause_game ? 16'd0 : snd;assign AUDIO_R=pause_game ? 16'd0 : snd;assign AUDIO_MIX=0;
 assign LED_DISK=0;assign LED_POWER=0;assign LED_USER=ioctl_download;assign BUTTONS=0;
 wire [1:0] ar=status[122:121];
// Rotation "Auto" uses each renderer's native orientation plus the MAME ROT flag.
// Wave profiles 0/1 (Marvin's Maze/Vanguard II) need ROT270 -> 90 CCW (MiSTer clips, 2026-10-25).
// Other early profiles retain ROT270 -> 90 CW; Athena/Fite Golf/Country Club need native 180.
// Late/Ikari renders MAME native orientation: ROT270 sets use 90 CCW; ROT90 (tdfever) uses 90 CW.
 wire [7:0] rot_profile;
 wire wave_rot270=rot_profile==8'd0||rot_profile==8'd1;
 wire early_rot270=rot_profile==8'd3||rot_profile==8'd5||rot_profile==8'd6||rot_profile==8'd7;
 wire early_rot180=rot_profile==8'd8||rot_profile==8'd9||rot_profile==8'd10;
 wire late_rot270=rot_profile==8'd11||rot_profile==8'd12||rot_profile==8'd16||rot_profile==8'd19||rot_profile==8'd14||rot_profile==8'd18;
 wire late_rot90=rot_profile==8'd15;
 wire [1:0] auto_rot=early_rot180 ? 2'd3 : status[3] ? 2'd0 : wave_rot270 ? 2'd2 : (early_rot270||late_rot90) ? 2'd1 : late_rot270 ? 2'd2 : 2'd0;
 wire [1:0] rot_sel=status[2:1]==2'd0 ? auto_rot : status[2:1];

 `include "build_id.v"
 localparam CONF_STR={
  "SNK_TripleZ80;;",
  // Layout: Video Settings / Game Settings pages, DIP Switches, Credits, Reset (same as HeavyUnit).
  // Status bit allocation is unchanged; only grouping and labels differ. H1 = CRT sub-options (hidden while CRT Adjust is Off).
  "P1,Video Settings;",
  "P1O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
  "P1O[2:1],Rotation,Auto,90 CW,90 CCW,180;",
  "P1O[3],Auto Rotate Vertical Games,On,Off;",
  "P1O[8:7],Scaling,HV Integer,V Integer,Normal;",
  "P1O[6:4],Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;",
  "P1O[10],VGA Scaler,Off,On;",
  "P1-;",
  "P1O[101],CRT Adjust,Off,On;",
  "H1P1O[100:96],CRT H-Size,0,+1,+2,+3,+4,+5,+6,+7,+8,-8,-7,-6,-5,-4,-3,-2,-1;",
  "H1P1O[85:81],CRT H-Position,0,+2,+4,+6,+8,+10,+12,+14,+16,+18,+20,+22,+24,+26,+28,+30,-32,-30,-28,-26,-24,-22,-20,-18,-16,-14,-12,-10,-8,-6,-4,-2;",
  "H1P1O[78:74],CRT V-Shift,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
  "P2,Game Settings;",
  "P2O[15],OSD Pause,On,Off;",
  "P2O[16],Dim Paused Video,On,Off;",
  "P2O[17],Autosave Scores,On,Off;",
  "H3P2O[19:18],CPU Speed,8MHz No Slowdown,6MHz,4MHz Original PCB;",
  "P3,Controls;",
  "H2P3O[42:41],Trackball speed,Normal,Slow,Fast,Very Fast;",
  "P3O[31:30],Aim control,Auto,Twin-stick,Bumpers,Digital;",
  "P3O[33:32],Right-stick deadzone,25%,10%,20%,30%;",
  "P3O[35:34],Twin-stick aim speed,Normal,Instant,Slow;",
  "P3O[43],Stick autofire (holds Fire),Off,On;",
  "P3O[37:36],Bumper aim repeat,9/s,5/s,14/s,20/s;",
  "P3O[38],Left stick moves,Yes,No (D-pad only);",
  "P3O[40:39],Stick layout,Normal,Swap sticks,Invert aim Y,Swap + invert aim Y;",
  "-;",
  "DIP;",
  "R[120],Credits;",
  "-;",
  "R[0],Reset;",
  "J1,Fire,Psycho Orb,Start,Coin,Pause,Service,Aim Left,Aim Right;",
  "V,v",`BUILD_DATE
  };
 wire clk_sys,clk_sdram,pll_locked;wire early_active;
 wire direct_video,forced_scandoubler;wire [21:0] gamma_bus;
 wire [63:0] reconfig_to_pll,reconfig_from_pll;wire cfg_waitrequest,cfg_write;wire [5:0] cfg_address;wire [31:0] cfg_data;
 pll pll(.refclk(CLK_50M),.rst(1'b0),.outclk_0(clk_sys),.outclk_1(clk_sdram),.locked(pll_locked),
  .reconfig_to_pll(reconfig_to_pll),.reconfig_from_pll(reconfig_from_pll));
 pll_cfg pll_cfg(.mgmt_clk(CLK_50M),.mgmt_reset(1'b0),.mgmt_waitrequest(cfg_waitrequest),.mgmt_read(1'b0),.mgmt_readdata(),
  .mgmt_write(cfg_write),.mgmt_address(cfg_address),.mgmt_writedata(cfg_data),
  .reconfig_to_pll(reconfig_to_pll),.reconfig_from_pll(reconfig_from_pll));
 // Power-on lock only: a family PLL switch must not clear the download guard's profile (taken from ioctl index 1).
 reg [1:0] pll_lock_s=2'b00;reg pll_up=1'b0;wire pll_switching;
 always @(posedge clk_sys) begin pll_lock_s<={pll_lock_s[0],pll_locked};if(pll_lock_s[1])pll_up<=1'b1; end
 wire [127:0] status;wire [1:0] buttons;wire [31:0] joystick_0,joystick_1,joystick_2,joystick_3;
 wire [10:0] ps2_key; wire [24:0] ps2_mouse;
 wire [8:0] spinner_0,spinner_1,spinner_2,spinner_3; // MiSTer spinners: [7:0] signed delta, [8] toggles per update
 wire ioctl_download,ioctl_wr,ioctl_upload,hs_upload_req;wire [7:0] hs_upload_index,hs_to_hps;wire [15:0] ioctl_index;wire [26:0] ioctl_addr;
 wire [7:0] ioctl_dout;wire bridge_wait,store_initialized,load_idle;
 // Late ROM download: one register stage between the HPS strobe and the profile-dependent native decode
 // (96MHz timing). load_wait covers the staged byte, so the guard cannot accept a second byte while
 // one is between the stage and the bridge's own input stage.
 reg [24:0] ld_addr_q=0;reg [7:0] ld_data_q=0;reg ld_wr_q=0,ld_wr_qq=0;
 // Second stage after the profile-dependent address decode; the bridge consumes only this registered copy.
 reg [24:0] ld2_addr_q=0;reg [7:0] ld2_data_q=0;reg ld2_wr_q=0;
 wire load_wait=bridge_wait||ld_wr_q||ld_wr_qq||ld2_wr_q;
 wire [15:0] ana_l0,ana_r0,ana_l1,ana_r1;wire [31:0] joy0_pad,joy1_pad; // twin-stick: hps_io analog sticks / pad words after the stick filter (snk_rotary_keys)
 wire [15:0] dbg_a_addr;wire [7:0] dbg_a_data;wire [4:0] dbg_a_ctl;     // CPU-A bus snoop (aim variable writes) from the board
 hps_io #(.CONF_STR(CONF_STR)) hps_io(
  .clk_sys(clk_sys),.HPS_BUS(HPS_BUS),.EXT_BUS(),.gamma_bus(gamma_bus),
  .direct_video(direct_video),.forced_scandoubler(forced_scandoubler),
  .buttons(buttons),.status(status),.status_menumask({12'd0,active_profile!=8'd19,active_profile!=8'd10,!status[101],1'b0}),
  .joystick_0(joystick_0),.joystick_1(joystick_1),.joystick_2(joystick_2),.joystick_3(joystick_3),
  .joystick_l_analog_0(ana_l0),.joystick_r_analog_0(ana_r0),.joystick_l_analog_1(ana_l1),.joystick_r_analog_1(ana_r1),
  .spinner_0(spinner_0),.spinner_1(spinner_1),.spinner_2(spinner_2),.spinner_3(spinner_3),
  .ps2_key(ps2_key),.ps2_mouse(ps2_mouse),
  .ioctl_download(ioctl_download),.ioctl_wr(ioctl_wr),.ioctl_index(ioctl_index),
  .ioctl_addr(ioctl_addr),.ioctl_dout(ioctl_dout),
  .ioctl_upload(ioctl_upload),.ioctl_upload_req(hs_upload_req),
  .ioctl_upload_index(hs_upload_index),.ioctl_din(hs_to_hps),
  .ioctl_wait((ioctl_index==0&&load_wait)||pll_switching));
 wire [7:0] active_profile;assign rot_profile=active_profile;
 reg [7:0] dip1=8'h3b,dip2=8'hbf;
 wire hdr_ok,need_rom,rom_accept;
 snk_rom_download_guard download_guard(
  .clk(clk_sys),.reset(!pll_up),.download(ioctl_download),.wr(ioctl_wr),
  .bridge_wait(load_wait),.index(ioctl_index),.addr(ioctl_addr),.data(ioctl_dout),
  .profile(active_profile),.hdr_ok(hdr_ok),.need_rom(need_rom),.rom_accept(rom_accept),
  .accepted_bytes(),.expected_bytes(),.stream_fault());
 always @(posedge clk_sys)begin
  if(ioctl_wr&&ioctl_index==254)begin
   if(ioctl_addr==0)dip1<=ioctl_dout;if(ioctl_addr==1)dip2<=ioctl_dout;
  end
 end
 // Stable IDs from active-scope.json; excluded donors have no runtime fallback.
 function automatic profile_allowed(input [7:0] id);
  case(id)
8'd13,8'd11,8'd12,8'd16,8'd19,8'd5,8'd2,8'd0,8'd1,8'd3,8'd4,8'd15,8'd17,8'd6,8'd7,8'd8,8'd9,8'd10,8'd14,8'd18:profile_allowed=1;
   default:profile_allowed=0;
  endcase
 endfunction
 assign early_active=active_profile<=8'd10; // 0..2 wave, 3..5 hsj, 6..10 TNK3-class
wire ik_active=active_profile==8'd14||active_profile==8'd18; // Ikari Warriors / Victory Road (late bus + early 13.4MHz-family clocks)
// 13.4 MHz-crystal boards run on the 93.8 MHz PLL setting; the late/sports 16 MHz boards on 96 MHz.
wire early_clk=early_active||ik_active;
snk_pll_mode pll_mode(.clk_sys(clk_sys),.pll_locked(pll_locked),.want_early(early_clk),.switching(pll_switching),
 .mgmt_clk(CLK_50M),.cfg_waitrequest(cfg_waitrequest),.cfg_write(cfg_write),.cfg_address(cfg_address),.cfg_data(cfg_data),
 .mgmt_early());
wire implemented=early_active||ik_active||active_profile==8'd11||active_profile==8'd12||active_profile==8'd13||active_profile==8'd16||active_profile==8'd19||active_profile==8'd15||active_profile==8'd17;
 wire bridge_reset=RESET|status[0]|buttons[1]|!pll_locked|pll_switching|need_rom|(ioctl_download&&ioctl_index==0)|
                   !profile_allowed(active_profile)|!implemented;
 wire reset_game=bridge_reset|!store_initialized|!load_idle|ld_wr_q|ld_wr_qq|ld2_wr_q;
 // Registered copy for the large board reset fanout (96MHz timing): reset_game is a level held for the
 // whole download and for many clocks around it, so one clock of skew on the board reset is benign.
 reg reset_game_r=1'b1;
 always @(posedge clk_sys) reset_game_r<=reset_game;
 wire pause_game;wire [7:0] raw_r,raw_g,raw_b;wire [23:0] paused_rgb;
 pause #(.RW(8),.GW(8),.BW(8),.CLK_HZ(MASTER_HZ)) pausing(
  .clk_sys(clk_sys),.reset(reset_game),
  .user_button(cabinet_pause),.pause_request(hs_pause_request),
  .options(~status[16:15]),.OSD_STATUS(OSD_STATUS),
  .r(raw_r),.g(raw_g),.b(raw_b),.pause_cpu(pause_game),.rgb_out(paused_rgb));
 wire hs_pause_request,hs_req,hs_write,hs_ack,hs_configured,hs_fault;
 wire [15:0] hs_addr;wire [7:0] hs_wdata,hs_rdata;
 // Stop every CPU enable, then drain the registered RAM pipeline before granting.
 reg [2:0] pause_drain;
 always @(posedge clk_sys)begin
  if(reset_game || !pause_game)pause_drain<=0;
  else if(pause_drain<4)pause_drain<=pause_drain+1'b1;
 end
 // reset_game_r (registered): the combinational reset_game (bridge busy -> load_idle -> reset_game) fed the whole hs_rdata mux and the
 // hiscore cache counter enable and was the -0.89ns path in r46; one clock of skew on a level held for many clocks is benign.
 wire hs_grant=pause_game && pause_drain==4 && !reset_game_r && (!early_active||early_drained);
 snk_profile_hiscore high_scores(
  .clk(clk_sys),.reset(reset_game_r),.profile(active_profile),.storage_error(1'b0),.paused(hs_grant),.autosave(!status[17]),
  .ioctl_upload(ioctl_upload),.ioctl_download(ioctl_download),.ioctl_wr(ioctl_wr),
  .ioctl_addr(ioctl_addr[24:0]),.ioctl_index((ioctl_index==16'd3 || ioctl_index==16'd4 || (early_active&&ioctl_index==16'd0)) ? ioctl_index[7:0] : 8'hff),.OSD_STATUS(OSD_STATUS),
  .data_from_hps(ioctl_dout),.data_to_hps(hs_to_hps),
  .ioctl_upload_req(hs_upload_req),.ioctl_upload_index(hs_upload_index),
  .configured(hs_configured),.pause_request(hs_pause_request),
  .hs_req(hs_req),.hs_write(hs_write),.hs_addr(hs_addr),.hs_wdata(hs_wdata),
  .hs_ack(hs_ack),.hs_rdata(hs_rdata),.fault(hs_fault));
 wire cen_p,cen_n,ce_pixel;
 // Ikari/Victory Road pixel enable: plain clk_sys/14 counter (clock plan R2): 93.8/14 = 6.7 MHz, 416x262 = 61.47 Hz.
 reg [3:0] ik_pcnt=0;always @(posedge clk_sys) ik_pcnt<=(ik_pcnt==4'd13) ? 4'd0 : ik_pcnt+4'd1;
 wire ik_pixel_cen=ik_pcnt==4'd0;
 wire e335p,e335n,e336p,e336n,e4p,e4n,e2,e8,group_b_pixel_cen,e67p;
 wire early_ab_p,early_ab_n,early_s_p,early_s_n,early_ay_ce,early_wave_ce;
 wire pixel_response_ce,early_drained,board_pixel_ce,early_sound_busy;
 snk_early_master_cen #(.CLK_HZ(EARLY_HZ)) early_enables(.i_clk(clk_sys),.aso_grid(1'b0),
  .clk_13p4_cen(),.clk_13p4(),.clk_13p4b_cen(),.clk_13p4b(),
  .clk_6p7_cen(e67p),.clk_6p7b_cen(),
  .clk_3p35_cen(e335p),.clk_3p35b_cen(e335n),
  .clk_4_cen(e4p),.clk_4b_cen(e4n),
  .clk_3p36_cen(e336p),.clk_3p36b_cen(e336n),.clk_2_cen(e2),.clk_8_cen(e8),
  .group_b_pixel_cen(group_b_pixel_cen));
 snk_psychos_cen enables(.clk(clk_sys),.reset(!pll_locked),
                        .cen_p(cen_p),.cen_n(cen_n),.pxl_cen(ce_pixel));
 // Guerrilla War game CPUs: the PCB's 4MHz drops game ticks in busy scenes (MAME and the
 // real board alike); OSD CPU Speed defaults to 8MHz so every tick fits its frame.
 wire gwar_ab_p,gwar_ab_n;
 snk_late_boost_cen gwar_enables(.clk(clk_sys),.reset(!pll_locked),.mode(status[19:18]),
                        .cen_p(gwar_ab_p),.cen_n(gwar_ab_n));
 // Reset still receives chip clock enables, allowing Yamaha pipelines to prime.
 // Guard spacings at 93.8 MHz: 3.35 MHz exactly 28, 3.36 MHz 27/28, 4 MHz 23/24, 2 MHz 46/47, 8 MHz 11/12 clocks.
 wire run_ce=!pause_game||reset_game;
 snk_early_cen_guard #(.MIN_SPACING(27)) early_ab_p_guard(.clk(clk_sys),.run_enable(run_ce&&(early_active||ik_active)),.raw_ce((active_profile <= 8'd2) ? e336p : e335p),.ce(early_ab_p));
 snk_early_cen_guard #(.MIN_SPACING(27)) early_ab_n_guard(.clk(clk_sys),.run_enable(run_ce&&(early_active||ik_active)),.raw_ce((active_profile <= 8'd2) ? e336n : e335n),.ce(early_ab_n));
 snk_early_cen_guard #(.MIN_SPACING(23)) early_s_p_guard(.clk(clk_sys),.run_enable(run_ce&&(early_active||ik_active)),.raw_ce(e4p),.ce(early_s_p));
 snk_early_cen_guard #(.MIN_SPACING(23)) early_s_n_guard(.clk(clk_sys),.run_enable(run_ce&&(early_active||ik_active)),.raw_ce(e4n),.ce(early_s_n));
 snk_early_cen_guard #(.MIN_SPACING(46)) early_ay_guard(.clk(clk_sys),.run_enable(run_ce&&early_active),.raw_ce(e2),.ce(early_ay_ce));
 snk_early_cen_guard #(.MIN_SPACING(11)) early_wave_guard(.clk(clk_sys),.run_enable(run_ce&&early_active),.raw_ce(e8),.ce(early_wave_ce));
 // The bus adapter produces late sound-busy bits; upper unused input fields stay open.
 // Sports dials (IN6..IN9: MAME IPT_DIAL, 7 bits, wraps mod 128, spinner + adds) and bermudat/worldwar rotaries
 // (IN1/IN2[7:4]: IPT_POSITIONAL, 12 positions, PORT_REVERSE: spinner + steps the value DOWN). 16 spinner counts per
 // rotary position (MAME keys: dial 150 counts/s, rotary 9 positions/s at full key rate). All values reset with reset_game.
 wire hblank,vblank,hsync,vsync;
 reg [6:0] dial0=0,dial1=0,dial2=0,dial3=0;reg [3:0] rot1=0,rot2=0,ra1=0,ra2=0,sp_t=0;
 integer t1,t2,v1,v2;
 always @(posedge clk_sys)begin
  if(reset_game)begin
   dial0<=0;dial1<=0;dial2<=0;dial3<=0;rot1<=0;rot2<=0;ra1<=0;ra2<=0;
   sp_t<={spinner_3[8],spinner_2[8],spinner_1[8],spinner_0[8]};
  end else begin
   if(spinner_0[8]!=sp_t[0])begin
    sp_t[0]<=spinner_0[8];dial0<=dial0+spinner_0[6:0];
    t1=ra1;t1=t1+$signed(spinner_0[7:0]);v1=rot1;v1=v1-(t1>>>4);
    if(v1<0)v1=v1+12;else if(v1>=12)v1=v1-12;
    ra1<=t1&15;rot1<=v1;
   end
   if(spinner_1[8]!=sp_t[1])begin
    sp_t[1]<=spinner_1[8];dial1<=dial1+spinner_1[6:0];
    t2=ra2;t2=t2+$signed(spinner_1[7:0]);v2=rot2;v2=v2-(t2>>>4);
    if(v2<0)v2=v2+12;else if(v2>=12)v2=v2-12;
    ra2<=t2&15;rot2<=v2;
   end
   if(spinner_2[8]!=sp_t[2])begin sp_t[2]<=spinner_2[8];dial2<=dial2+spinner_2[6:0];end
   if(spinner_3[8]!=sp_t[3])begin sp_t[3]<=spinner_3[8];dial3<=dial3+spinner_3[6:0];end
  end
 end
 wire [3:0] rotary_0,rotary_1;
 snk_rotary_keys #(.CLK_HZ(MASTER_HZ),.REPEAT_HZ(9)) rotary_keys(.clk_sys(clk_sys),.reset_game(reset_game),.pause_game(pause_game||OSD_STATUS),
  .profile(active_profile),.joy0(joystick_0),.joy1(joystick_1),.ps2_key(ps2_key),
  .spinner_rotary_0(rot1),.spinner_rotary_1(rot2),.rotary_0(rotary_0),.rotary_1(rotary_1),.digital_0(),.digital_1(),
  .ana_l0(ana_l0),.ana_r0(ana_r0),.ana_l1(ana_l1),.ana_r1(ana_r1),.aim_cfg({status[43],status[40:30]}),
  .cpu_a_addr(dbg_a_addr),.cpu_a_data(dbg_a_data),.cpu_a_ctl(dbg_a_ctl),.joy0_f(joy0_pad),.joy1_f(joy1_pad));
 wire [27:0] country_counters;
 wire country_active=active_profile==8'd10;
 wire [31:0] country_joy0=joy0_pad | (country_active ? {26'd0,ps2_mouse[1:0],4'd0}:32'd0);
 snk_trackball #(.CLK_HZ(EARLY_HZ)) country_trackball(.clk(clk_sys),.reset(reset_game||!country_active),
  .pause(pause_game||OSD_STATUS),.ps2_mouse(ps2_mouse),.joy0(joy0_pad),.joy1(joy1_pad),
  .analog0(ana_l0),.analog1(ana_l1),.speed(status[42:41]),.counters(country_counters));
 wire [79:0] cabinet_ports;wire [7:0] dip1_live,dip2_live;wire cabinet_pause,cabinet_supported;
 snk_cabinet_inputs cabinet(.profile(active_profile),.joy0(country_joy0),.joy1(joy1_pad),
 // busy_in stays 1 (neutral 0xff) until a board exports its busy flag; buses already merge their own busy (see adapter comments).
  .joy2(joystick_2),.joy3(joystick_3),.hardware_inputs(80'hffffffffffffffffffff),.busy_in(early_active?early_sound_busy:1'b1),.dial(country_active ? country_counters : {dial3,dial2,dial1,dial0}),.rot_p1(rotary_0),.rot_p2(rotary_1),
  .dsw1(dip1),.dsw2(dip2),.ports(cabinet_ports),.dsw1_live(dip1_live),.dsw2_live(dip2_live),
  .pause_button(cabinet_pause),.supported(cabinet_supported));
 wire [7:0] in0=cabinet_ports[7:0],in1=cabinet_ports[15:8],
            in2=cabinet_ports[23:16],in3=cabinet_ports[31:24];
 wire [7:0] in4=cabinet_ports[39:32],in5=cabinet_ports[47:40],in6=cabinet_ports[55:48],in7=cabinet_ports[63:56],in8=cabinet_ports[71:64],in9=cabinet_ports[79:72]; // sports IN4..IN9 (C200..C480); connect when the sports board is instantiated
 wire [24:0] core_load_addr,late_load_addr;wire [7:0] core_load_data,late_load_data;wire rom_wr,late_rom_wr;
 wire native_wait,native_supported,native_mapped,native_transformed;
 // ld_addr_q/ld_data_q are loaded only on an accepted late byte and then held; the strobe reaches the decode one
 // clock later (ld_wr_qq), so the profile-dependent decode has two clocks (multicycle in the SDC).
 always @(posedge clk_sys) begin
  if(rom_accept&&!early_active) begin ld_addr_q<=ioctl_addr[24:0];ld_data_q<=ioctl_dout; end
  ld_wr_q<=rom_accept&&!early_active;ld_wr_qq<=ld_wr_q;
 end
 snk_late_native_loader native_loader(.profile(active_profile),.native_addr(ld_addr_q),
  .native_data(ld_data_q),.native_wr(ld_wr_qq),
  .bridge_wait(bridge_wait),.core_addr(late_load_addr),.core_data(late_load_data),.core_wr(late_rom_wr),
  .native_wait(native_wait),.supported(native_supported),.mapped(native_mapped),.transformed(native_transformed));
 assign core_load_addr=early_active?ioctl_addr[24:0]:late_load_addr;
 assign core_load_data=early_active?ioctl_dout:late_load_data;
 assign rom_wr=early_active?rom_accept:late_rom_wr;
 always @(posedge clk_sys) begin ld2_addr_q<=late_load_addr;ld2_data_q<=late_load_data;ld2_wr_q<=late_rom_wr&&!early_active; end
 // One register stage between the HPS/loader decode and the board ROM/RAM load ports (96MHz timing).
 reg [24:0] board_load_addr=0;reg [7:0] board_load_data=0;reg board_rom_wr=0;
 always @(posedge clk_sys) begin board_load_addr<=core_load_addr;board_load_data<=core_load_data;board_rom_wr<=rom_wr; end
 wire [16:0] bg_addr,s32_addr;wire [15:0] s16_addr;wire [20:0] sample_addr;
 wire bg_cs,s16_cs,s32_cs,sample_cs,bg_ok,s16_ok,s32_ok,sample_ok;
 wire [31:0] bg_data,s16_data,s32_data;wire [7:0] sample_data;
 snk_union_rom_bridge #(.CLK_HZ(MASTER_HZ),.CLK_MIN_HZ(EARLY_HZ)) roms(
  .clk(clk_sys),.clk_shifted(clk_sdram),.init(!pll_locked||pll_switching),.rst(bridge_reset),
  .initialized(store_initialized),.big_sp16(active_profile==8'd19),.ioctl_wr(ld2_wr_q),.ioctl_addr(ld2_addr_q),
  .ioctl_data(ld2_data_q),.ioctl_wait(bridge_wait),.load_idle(load_idle),
  .bg_cs(bg_cs),.bg_addr(bg_addr),.bg_data(bg_data),.bg_ok(bg_ok),.bg_tag(),
  .s16_cs(s16_cs),.s16_addr(s16_addr),.s16_data(s16_data),.s16_ok(s16_ok),.s16_tag(),
  .s32_cs(s32_cs),.s32_addr(s32_addr),.s32_data(s32_data),.s32_ok(s32_ok),.s32_tag(),
  .sample_cs(sample_cs),.sample_addr(sample_addr),.sample_data(sample_data),.sample_ok(sample_ok),.sample_tag(),
  .SDRAM_DQ(SDRAM_DQ),.SDRAM_A(SDRAM_A),.SDRAM_BA(SDRAM_BA),
  .SDRAM_DQML(SDRAM_DQML),.SDRAM_DQMH(SDRAM_DQMH),.SDRAM_nCS(SDRAM_nCS),
  .SDRAM_nWE(SDRAM_nWE),.SDRAM_nRAS(SDRAM_nRAS),.SDRAM_nCAS(SDRAM_nCAS),
  .SDRAM_CLK(SDRAM_CLK),.SDRAM_CKE(SDRAM_CKE));
 // 4 MHz sound/OPL pair (and Victory Road's game CPUs): /24 at 96 MHz, the guarded 93.8 MHz early 4 MHz pair otherwise.
 wire late_cen_p=early_clk ? early_s_p : cen_p&&run_ce;
 wire late_cen_n=early_clk ? early_s_n : cen_n&&run_ce;
 wire signed [15:0] snd;
 assign board_pixel_ce=(early_active||ik_active)?pixel_response_ce:ce_pixel;
 snk_union_system_shared #(.HISCORE_ENABLE(1),.DISPLAY_FLIP_ENABLE(1)) board(
  .profile_id(active_profile),
  .display_flip(rot_sel==3),.pause_cpu(pause_game),
  .hs_grant(hs_grant),.hs_req(hs_req),.hs_write(hs_write),.hs_addr(hs_addr),
  .hs_wdata(hs_wdata),.hs_ack(hs_ack),.hs_rdata(hs_rdata),
  .clk(clk_sys),.reset_n(!reset_game_r),.cen_p(late_cen_p),.cen_n(late_cen_n),
  .gwar_ab_p(gwar_ab_p&&run_ce),.gwar_ab_n(gwar_ab_n&&run_ce),
  .ce_opl(late_cen_p),.pxl_cen(ik_active?ik_pixel_cen:ce_pixel),
  .early_ab_p(early_ab_p),.early_ab_n(early_ab_n),
  .early_s_p(early_s_p),.early_s_n(early_s_n),.early_ay_ce(early_ay_ce),.early_wave_ce(early_wave_ce),
  .early_pixel_ce(group_b_pixel_cen),.pixel_response_ce(pixel_response_ce),.early_drained(early_drained),.early_sound_busy(early_sound_busy),
  .ioctl_addr(board_load_addr),.ioctl_data(board_load_data),.ioctl_wr(board_rom_wr),
  .in0(in0),.in1(in1),.in2(in2),.in3(in3),.dsw1(dip1_live),.dsw2(dip2_live),.sports_inputs(cabinet_ports),
  .bgrom_addr(bg_addr),.s16rom_addr(s16_addr),.s32rom_addr(s32_addr),
  .bgrom_req(bg_cs),.s16rom_req(s16_cs),.s32rom_req(s32_cs),
  .bgrom_data(bg_data),.s16rom_data(s16_data),.s32rom_data(s32_data),
  .bgrom_ack(bg_ok),.s16rom_ack(s16_ok),.s32rom_ack(s32_ok),
  .sample_addr(sample_addr),.sample_req(sample_cs),.sample_data(sample_data),.sample_ack(sample_ok),
  .red(raw_r),.green(raw_g),.blue(raw_b),
  .hsync(hsync),.vsync(vsync),.hblank(hblank),.vblank(vblank),
  .audio_mono(snd),.ym3526_pcm(),.y8950_pcm(),.ym3526_sample(),.y8950_sample(),
  .sound_status(),.render_busy(),.line_overrun(),
  .debug_a_addr(dbg_a_addr),.debug_b_addr(),.debug_s_addr(),.debug_a_data(dbg_a_data),.debug_b_data(),.debug_s_data(),
  .debug_a_din(),.debug_b_din(),.debug_s_din(),.debug_a_ctl(dbg_a_ctl),.debug_b_ctl(),.debug_s_ctl(),
  .sound_command_wr(),.sound_command());
 wire signed [4:0] crt_size=status[100:96]<=8 ? $signed(status[100:96]) :
  (status[100:96]<=16 ? $signed({1'b0,status[100:96]})-6'sd17 : 5'sd0);
 wire signed [8:0] crt_pos=$signed({{4{status[85]}},status[85:81]}) <<< 1;
 wire signed [5:0] crt_vpos=$signed({status[78],status[78:74]});
 assign FB_FORCE_BLANK=1'b0;
 // Credits overlay: inserted before the video boundary (scandoubler, scaler and quarter-turn rotation).
 // 180 is done natively upstream, so only the downstream quarter turns are described here; direct video disables rotation.
 wire [7:0] credits_early_r,credits_early_g,credits_early_b,credits_late_r,credits_late_g,credits_late_b;
 wire credits_early_hs,credits_early_vs,credits_early_hb,credits_early_vb,credits_early_de,credits_early_active;
 wire credits_late_hs,credits_late_vs,credits_late_hb,credits_late_vb,credits_late_de,credits_late_active;
 wire [7:0] credits_r,credits_g,credits_b;wire credits_hs,credits_vs,credits_hb,credits_vb,credits_de,credits_active;
 wire credits_dismiss=|(joystick_0|joystick_1|joystick_2|joystick_3)|(|buttons)|OSD_STATUS;
 wire [1:0] credits_rotation=direct_video ? 2'd0 : (rot_sel==2'd1 ? 2'd1 : (rot_sel==2'd2 ? 2'd3 : 2'd0));
 credits_overlay #(.WIDTH(400),.HEIGHT(224)) credits_late(
  .clk_video(clk_sys),.reset(!pll_locked|RESET),.ce_pixel(board_pixel_ce),
  .menu_trigger(status[120]),.dismiss(credits_dismiss),.rotation(credits_rotation),
  .r_in(paused_rgb[23:16]),.g_in(paused_rgb[15:8]),.b_in(paused_rgb[7:0]),
  .hs_in(hsync),.vs_in(vsync),.hblank_in(hblank),.vblank_in(vblank),
  .r_out(credits_late_r),.g_out(credits_late_g),.b_out(credits_late_b),
  .hs_out(credits_late_hs),.vs_out(credits_late_vs),.hblank_out(credits_late_hb),.vblank_out(credits_late_vb),
  .de_out(credits_late_de),.active(credits_late_active));
 credits_overlay #(.WIDTH(288),.HEIGHT(224)) credits_early(
  .clk_video(clk_sys),.reset(!pll_locked|RESET),.ce_pixel(board_pixel_ce),
  .menu_trigger(status[120]),.dismiss(credits_dismiss),.rotation(credits_rotation),
  .r_in(paused_rgb[23:16]),.g_in(paused_rgb[15:8]),.b_in(paused_rgb[7:0]),
  .hs_in(hsync),.vs_in(vsync),.hblank_in(hblank),.vblank_in(vblank),
  .r_out(credits_early_r),.g_out(credits_early_g),.b_out(credits_early_b),
  .hs_out(credits_early_hs),.vs_out(credits_early_vs),.hblank_out(credits_early_hb),.vblank_out(credits_early_vb),
  .de_out(credits_early_de),.active(credits_early_active));
 wire credits_narrow=early_active||ik_active; // 288-wide overlay for the 288x224 families
 assign credits_r=credits_narrow?credits_early_r:credits_late_r;
 assign credits_g=credits_narrow?credits_early_g:credits_late_g;
 assign credits_b=credits_narrow?credits_early_b:credits_late_b;
 assign credits_hs=credits_narrow?credits_early_hs:credits_late_hs;
 assign credits_vs=credits_narrow?credits_early_vs:credits_late_vs;
 assign credits_hb=credits_narrow?credits_early_hb:credits_late_hb;
 assign credits_vb=credits_narrow?credits_early_vb:credits_late_vb;
 assign credits_de=credits_narrow?credits_early_de:credits_late_de;
 assign credits_active=credits_narrow?credits_early_active:credits_late_active;
 snk_mister_video #(.NATIVE_180(1)) video_boundary(
  .clk(clk_sys),.reset(!pll_locked|RESET),.ce_pix(board_pixel_ce),.rgb({credits_r,credits_g,credits_b}),
  .hb(credits_hb),.vb(credits_vb),.hs(credits_hs),.vs(credits_vs),
  .direct_video(direct_video),.forced_scandoubler(forced_scandoubler),
  .fx(status[6:4]),.rotation(rot_sel),.scale_mode(status[8:7]==2'd0 ? 2'd2 : (status[8:7]==2'd2 ? 2'd0 : status[8:7])),.aspect(ar),
  .hdmi_width(HDMI_WIDTH),.hdmi_height(HDMI_HEIGHT),
  .crt_active(status[101]),.crt_hsize(crt_size),.crt_hpos(crt_pos),.crt_vpos(crt_vpos),
  .gamma_bus(gamma_bus),
  .CLK_VIDEO(CLK_VIDEO),.CE_PIXEL(CE_PIXEL),
  .VGA_R(VGA_R),.VGA_G(VGA_G),.VGA_B(VGA_B),.VGA_HS(VGA_HS),.VGA_VS(VGA_VS),
  .VGA_DE(VGA_DE),.VGA_SL(VGA_SL),.VIDEO_ARX(VIDEO_ARX),.VIDEO_ARY(VIDEO_ARY),
  .FB_EN(FB_EN),.FB_FORMAT(FB_FORMAT),.FB_WIDTH(FB_WIDTH),.FB_HEIGHT(FB_HEIGHT),
  .FB_BASE(FB_BASE),.FB_STRIDE(FB_STRIDE),.FB_VBL(FB_VBL),.FB_LL(FB_LL),
  .DDRAM_CLK(DDRAM_CLK),.DDRAM_BUSY(DDRAM_BUSY),
  .DDRAM_BURSTCNT(DDRAM_BURSTCNT),.DDRAM_ADDR(DDRAM_ADDR),
  .DDRAM_DIN(DDRAM_DIN),.DDRAM_BE(DDRAM_BE),.DDRAM_WE(DDRAM_WE),.DDRAM_RD(DDRAM_RD));
endmodule
