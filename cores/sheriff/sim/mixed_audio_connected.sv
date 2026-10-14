// SPDX-License-Identifier: GPL-2.0-or-later
// Actual production audio controller plus real8035; recorded CPU latch stimulus.
module mixed_audio_connected(input wire clk,reset,input wire[7:0]sound1,sound2,
input wire load_wr,input wire[9:0]load_addr,input wire[7:0]load_data,
output wire sample_ce,output wire signed[15:0]old_audio,current_audio,
output wire[7:0]p1,p2,output wire[11:0]pc,output wire dac,mono0,mono1,enabled);
wire mode,mixer,voltage5,old_ce;wire signed[15:0]old_sn,current_sn;
n8080_mcs48 controller(.clk(clk),.reset(reset),.pause(1'b0),.sound1(sound1),.sound2(sound2),
.load_wr(load_wr),.load_addr(load_addr),.load_data(load_data),.dac_bit(dac),.p1_out(p1),
.p2_out(p2),.program_address(pc),.program_data(),.irq_n(),.pins(),.mono0(mono0),.mono1(mono1),
.ce_crystal(),.ce_state(),.ram_address(),.ram_write(),.ram_dout(),.sn_enable(enabled),
.sn_vco_mode(mode),.sn_mixer_b(mixer),.sn_vco_5v(voltage5));
sheriff_sn76477 current_chip(.clk(clk),.reset(reset),.pause(1'b0),.enabled(enabled),
.vco_mode(mode),.mixer_b(mixer),.vco_5v(voltage5),.sample_ce(sample_ce),.sample(current_sn),
.slf_voltage(),.vco_voltage(),.noise_voltage(),.ad_voltage(),.slf_bit(),.vco_bit(),.filtered_noise());
sheriff_old_sn76477 old_chip(.clk(clk),.reset(reset),.pause(1'b0),.enabled(enabled),
.vco_mode(mode),.mixer_b(mixer),.vco_5v(voltage5),.sample_ce(old_ce),.sample(old_sn),
.slf_voltage(),.vco_voltage(),.noise_voltage(),.ad_voltage(),.slf_bit(),.vco_bit(),.filtered_noise());
assign old_audio=old_sn+(dac?16'sd4915:16'sd0);
assign current_audio=current_sn+(dac?16'sd4915:16'sd0);
endmodule
