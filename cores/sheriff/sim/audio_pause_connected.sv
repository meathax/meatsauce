// SPDX-License-Identifier: GPL-2.0-or-later
// Production audio with observation ports for a synthetic-command pause test.
module audio_pause_connected(
input wire clk,reset,pause,input wire[7:0]sound1,sound2,
input wire load_wr,input wire[9:0]load_addr,input wire[7:0]load_data,
output wire sample_ce,output wire signed[15:0]sample,
output wire[7:0]p1,p2,output wire[11:0]pc,output wire dac,mono0,mono1,enabled,
output wire[35:0]slf,vco,noise,ad,shot,output wire[24:0]duration0,duration1,
output wire[30:0]rng,output wire[10:0]divider,output wire[5:0]accumulator,
output wire[4:0]bits_state);
wire mode,mixer,voltage5,slf_bit,vco_bit,filtered_noise;
n8080_mcs48 controller(.clk(clk),.reset(reset),.pause(pause),.sound1(sound1),.sound2(sound2),
.load_wr(load_wr),.load_addr(load_addr),.load_data(load_data),.dac_bit(dac),.p1_out(p1),
.p2_out(p2),.program_address(pc),.program_data(),.irq_n(),.pins(),.mono0(mono0),.mono1(mono1),
.ce_crystal(),.ce_state(),.ram_address(),.ram_write(),.ram_dout(),.sn_enable(enabled),
.sn_vco_mode(mode),.sn_mixer_b(mixer),.sn_vco_5v(voltage5));
sheriff_sn76477 chip(.clk(clk),.reset(reset),.pause(pause),.enabled(enabled),
.vco_mode(mode),.mixer_b(mixer),.vco_5v(voltage5),.sample_ce(sample_ce),.sample(sample),
.slf_voltage(slf),.vco_voltage(vco),.noise_voltage(noise),.ad_voltage(ad),
.slf_bit(slf_bit),.vco_bit(vco_bit),.filtered_noise(filtered_noise));
assign duration0=controller.duration0;
assign duration1=controller.duration1;
assign accumulator=controller.accumulator;
assign divider=chip.divider;
assign rng=chip.rng;
assign shot=chip.shot_voltage;
assign bits_state={chip.shot_running,chip.previous_enabled,slf_bit,vco_bit,filtered_noise};
endmodule
