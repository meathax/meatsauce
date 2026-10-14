// SPDX-License-Identifier: GPL-3.0-or-later
// All reads synchronous, one cycle. Same-edge read/write returns OLD data.
// Clear has priority over CPU writes. ROM downloads have their own write ports.
module drmicro_memory(
 input logic clk, reset,load_wr,
 input logic [16:0] load_addr,
 input logic [7:0] load_data,
 input logic [15:0] cpu_addr,
 input logic cpu_wr,
 input logic [7:0] cpu_dout,
 output logic [7:0] cpu_din,
 output logic clearing,
 input logic [11:0] video_addr,
 output logic [7:0] video_data,
 input logic [12:0] gfx_addr,
 output logic [15:0] gfx0,
 output logic [23:0] gfx1,
 input logic [13:0] sample_addr,
 output logic [7:0] sample_data,
 input logic [8:0] pen_addr,
 output logic [3:0] indirect,
 input logic [4:0] color_addr,
 output logic [7:0] color_data
);
 import drmicro_pkg::*;
 logic [7:0] program_rom[0:49151];
 logic [7:0] ram[0:16383];
 logic [7:0] g00[0:8191],g01[0:8191],g10[0:8191],g11[0:8191],g12[0:8191];
 logic [7:0] samples[0:16383];
 logic [7:0] colors[0:31],lookup[0:511];
 logic [13:0] clear_addr;
 wire [31:0] load_offset={15'd0,load_addr};
 always_ff @(posedge clk) begin
  if(reset) begin clearing<=1;clear_addr<=0;end
  else if(clearing) begin
   ram[clear_addr]<=0;
   if(&clear_addr)clearing<=0;else clear_addr<=clear_addr+14'd1;
  end else if(cpu_wr)ram[cpu_addr[13:0]]<=cpu_dout;
  cpu_din<=cpu_addr<16'hc000 ? program_rom[cpu_addr]:ram[cpu_addr[13:0]];
  video_data<=ram[{2'b10,video_addr}];
  gfx0<={g01[gfx_addr],g00[gfx_addr]};
  gfx1<={g12[gfx_addr],g11[gfx_addr],g10[gfx_addr]};
  sample_data<=samples[sample_addr];
  indirect<=lookup[pen_addr][3:0];
  color_data<=colors[color_addr];
  if(load_wr)begin
   if(load_offset<ROM_GFX1_BASE)program_rom[load_addr[15:0]]<=load_data;
   else if(load_offset<ROM_GFX1_BASE+8192)g00[load_addr[12:0]]<=load_data;
   else if(load_offset<ROM_GFX2_BASE)g01[load_addr[12:0]]<=load_data;
   else if(load_offset<ROM_GFX2_BASE+8192)g10[load_addr[12:0]]<=load_data;
   else if(load_offset<ROM_GFX2_BASE+16384)g11[load_addr[12:0]]<=load_data;
   else if(load_offset<ROM_ADPCM_BASE)g12[load_addr[12:0]]<=load_data;
   else if(load_offset<ROM_PROMS_BASE)samples[14'(load_offset-ROM_ADPCM_BASE)]<=load_data;
   else if(load_offset<ROM_PROMS_BASE+32)colors[load_addr[4:0]]<=load_data;
   else if(load_offset<ROM_SIZE)lookup[9'(load_offset-ROM_PROMS_BASE-32)]<=load_data;
  end
 end
endmodule
