// SPDX-License-Identifier: GPL-3.0-or-later
module drmicro_sound(
 input logic clk,reset,psg_ce,adpcm_ce,io_write,
 input logic [7:0] port_addr,data,
 output logic [13:0] sample_addr,
 input logic [7:0] sample_data,
 output logic signed [15:0] audio,
 output logic [14:0] psg0,psg1,psg2,
 output logic signed [11:0] adpcm,
 output logic sample_strobe,
 output logic [14:0] sample_position
);
 sn76496_jt89 sn0(.clk(clk),.reset(reset),.ce(psg_ce),.write(io_write&&port_addr==0),.data(data),.sound(psg0),.digital(),.noise_state());
 sn76496_jt89 sn1(.clk(clk),.reset(reset),.ce(psg_ce),.write(io_write&&port_addr==1),.data(data),.sound(psg1),.digital(),.noise_state());
 sn76496_jt89 sn2(.clk(clk),.reset(reset),.ce(psg_ce),.write(io_write&&port_addr==2),.data(data),.sound(psg2),.digital(),.noise_state());
 logic [3:0] nibble;
 logic pcm_reset,vclk;
 drmicro_adpcm_ctrl ctrl(.clk(clk),.reset(reset),.start(io_write&&port_addr==3),.vclk_request(vclk),.command(data),.rom_addr(sample_addr),.rom_data(sample_data),.nibble(nibble),.decoder_reset(pcm_reset),.position(sample_position));
 jt5205 #(.INTERPOL(0),.VCLK_CEN(1)) decoder(.rst(reset|pcm_reset),.clk(clk),.cen(adpcm_ce),.sel(2'd1),.din(nibble),.sound(adpcm),.sample(sample_strobe),.irq(),.vclk_o(vclk));
 logic signed [19:0] mix;
 always_comb begin
  // Relative MAME gains .5,.5,.5,.75 with a common 1/4 headroom gain.
  // PSG native 0..32764, MSM native -2048..2047 scaled by 16.
  mix=(($signed({5'd0,psg0})+$signed({5'd0,psg1})+$signed({5'd0,psg2}))>>>3)+($signed({{8{adpcm[11]}},adpcm})*20'sd3);
  if(mix>32767)audio=16'sh7fff;
  else if(mix< -32768)audio=16'sh8000;
  else audio=mix[15:0];
 end
endmodule
