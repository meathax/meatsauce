// SPDX-License-Identifier: GPL-3.0-or-later
// Appoooh and Robo Wres ROM, work-RAM, video-RAM, graphics and PROM storage.
// CPU/video/graphics/sample reads are synchronous; coincident CPU writes leave
// the old value visible on that cycle, matching the original memory contract.
module appoooh_memory(
 input logic clk,reset,load_wr,robowres_mode,
 input logic [18:0] load_addr,
 input logic [7:0] load_data,
 input logic [15:0] cpu_addr,
 input logic cpu_bank,cpu_wr,cpu_m1_n,
 input logic [7:0] cpu_dout,
 output logic [7:0] cpu_din,
 output logic clearing,
 input logic [11:0] video_addr,
 output logic [7:0] video_data,
 input logic [14:0] gfx_addr,
 output logic [23:0] gfx0,gfx1,
 input logic [15:0] sample_addr,
 output logic [7:0] sample_data,
 input logic [8:0] pen_addr,
 output logic [7:0] indirect,
 input logic [4:0] color_addr,
 output logic [7:0] color_data
);
 import appoooh_pkg::*;
 // Nine independent 8 KiB pages match the physical Appoooh ROM organization
 // and also represent Robo Wres's fixed and two selectable bank windows.
 logic [7:0] program_rom0[0:8191],program_rom1[0:8191],program_rom2[0:8191];
 logic [7:0] program_rom3[0:8191],program_rom4[0:8191],program_rom5[0:8191];
 logic [7:0] program_rom6[0:8191],program_rom7[0:8191],program_rom8[0:8191];
 logic [7:0] work_ram[0:8191];
 logic [7:0] gfx1_p0[0:32767],gfx1_p1[0:32767],gfx1_p2[0:32767];
 logic [7:0] gfx2_p0[0:32767],gfx2_p1[0:32767],gfx2_p2[0:32767];
 logic [7:0] samples[0:65535];
 logic [7:0] palette_prom[0:31],lookup_prom[0:511];
 logic [12:0] clear_addr;
 logic [7:0] cpu_rom_q,cpu_ram_q;
 logic [15:0] cpu_addr_q;
 logic cpu_m1_q,cpu_rom_q_valid;
 wire [31:0] load_offset={13'd0,load_addr};
 wire [15:0] bank_offset=cpu_addr-16'ha000;
 wire [7:0] decrypted_cpu_rom;

 segacrp2_315_5179 decrypt(
  .address(cpu_addr_q[14:0]),.encrypted(cpu_rom_q),
  .opcode_fetch(!cpu_m1_q),.decrypted(decrypted_cpu_rom));

 always_comb begin
  if(cpu_rom_q_valid&&robowres_mode&&cpu_addr_q<16'h8000)
   cpu_din=decrypted_cpu_rom;
  else if(cpu_rom_q_valid)cpu_din=cpu_rom_q;
  else cpu_din=cpu_ram_q;
 end

 always_ff @(posedge clk) begin
  if(reset)begin clearing<=1;clear_addr<=0;cpu_rom_q_valid<=0;end
  else if(clearing)begin
   work_ram[clear_addr]<=0;
   if(&clear_addr)clearing<=0;else clear_addr<=clear_addr+13'd1;
  end else if(cpu_wr)work_ram[cpu_addr[12:0]]<=cpu_dout;

  // Preserve synchronous read timing.  Address and M1 are delayed alongside
  // the raw byte so Sega's data/opcode transforms see the matching cycle.
  cpu_addr_q<=cpu_addr;
  cpu_m1_q<=cpu_m1_n;
  cpu_rom_q_valid<=cpu_addr<16'he000;
  if(cpu_addr<16'ha000)begin
   case(cpu_addr[15:13])
    3'd0:cpu_rom_q<=program_rom0[cpu_addr[12:0]];
    3'd1:cpu_rom_q<=program_rom1[cpu_addr[12:0]];
    3'd2:cpu_rom_q<=program_rom2[cpu_addr[12:0]];
    3'd3:cpu_rom_q<=program_rom3[cpu_addr[12:0]];
    3'd4:cpu_rom_q<=program_rom4[cpu_addr[12:0]];
    default:cpu_rom_q<=8'hff;
   endcase
  end else if(cpu_addr<16'he000)begin
   case({cpu_bank,bank_offset[13]})
    2'b00:cpu_rom_q<=program_rom5[bank_offset[12:0]];
    2'b01:cpu_rom_q<=program_rom6[bank_offset[12:0]];
    2'b10:cpu_rom_q<=program_rom7[bank_offset[12:0]];
    2'b11:cpu_rom_q<=program_rom8[bank_offset[12:0]];
   endcase
  end else cpu_ram_q<=work_ram[cpu_addr[12:0]];

  video_data<=work_ram[13'h1000+{1'b0,video_addr}];
  gfx0<={gfx1_p2[gfx_addr],gfx1_p1[gfx_addr],gfx1_p0[gfx_addr]};
  gfx1<={gfx2_p2[gfx_addr],gfx2_p1[gfx_addr],gfx2_p0[gfx_addr]};
  sample_data<=(sample_addr<(robowres_mode?16'h8000:16'ha000))?samples[sample_addr]:8'hff;
  // Robo Wres maps both graphics sets through one 256-entry color table;
  // Appoooh's second graphics set selects the PROM's upper palette half.
  indirect<={3'b000,(pen_addr[8]&&!robowres_mode),lookup_prom[pen_addr][3:0]};
  color_data<=palette_prom[color_addr];

  if(load_wr)begin
   if(robowres_mode)begin
    if(load_offset<ROBOWRES_MAINCPU_SIZE)begin
     if(load_offset<32'h08000)begin
      case(load_addr[16:13])
       4'd0:program_rom0[load_addr[12:0]]<=load_data;
       4'd1:program_rom1[load_addr[12:0]]<=load_data;
       4'd2:program_rom2[load_addr[12:0]]<=load_data;
       4'd3:program_rom3[load_addr[12:0]]<=load_data;
       default:;
      endcase
     end else if(load_offset<32'h0a000)program_rom4[load_addr[12:0]]<=load_data;
     else if(load_offset<32'h0c000)program_rom5[load_addr[12:0]]<=load_data;
     else if(load_offset<32'h0e000)program_rom6[load_addr[12:0]]<=load_data;
     // MAME copies epr-7542 bytes 0x2000-0x5fff into the bank-1 window
     // at 0x10000-0x13fff. In the packed MRA stream those source bytes are
     // at 0x12000-0x15fff, which feed the a000 and c000 CPU pages.
     else if(load_offset>=32'h12000&&load_offset<32'h14000)program_rom7[load_addr[12:0]]<=load_data;
     else if(load_offset>=32'h14000&&load_offset<32'h16000)program_rom8[load_addr[12:0]]<=load_data;
    end
    else if(load_offset<ROBOWRES_GFX1_BASE+32'h08000)gfx1_p0[15'(load_offset-ROBOWRES_GFX1_BASE)]<=load_data;
    else if(load_offset<ROBOWRES_GFX1_BASE+32'h10000)gfx1_p1[15'(load_offset-ROBOWRES_GFX1_BASE-32'h08000)]<=load_data;
    else if(load_offset<ROBOWRES_GFX2_BASE)gfx1_p2[15'(load_offset-ROBOWRES_GFX1_BASE-32'h10000)]<=load_data;
    else if(load_offset<ROBOWRES_GFX2_BASE+32'h08000)gfx2_p0[15'(load_offset-ROBOWRES_GFX2_BASE)]<=load_data;
    else if(load_offset<ROBOWRES_GFX2_BASE+32'h10000)gfx2_p1[15'(load_offset-ROBOWRES_GFX2_BASE-32'h08000)]<=load_data;
    else if(load_offset<ROBOWRES_ADPCM_BASE)gfx2_p2[15'(load_offset-ROBOWRES_GFX2_BASE-32'h10000)]<=load_data;
    else if(load_offset<ROBOWRES_PROMS_BASE)samples[16'(load_offset-ROBOWRES_ADPCM_BASE)]<=load_data;
    else if(load_offset<ROBOWRES_PROMS_BASE+32)palette_prom[load_addr[4:0]]<=load_data;
    else if(load_offset<ROBOWRES_ROM_SIZE)lookup_prom[9'(load_offset-ROBOWRES_PROMS_BASE-32)]<=load_data;
   end else begin
    if(load_offset<ROM_MAINCPU_SIZE)begin
     case(load_addr[16:13])
      4'd0:program_rom0[load_addr[12:0]]<=load_data;
      4'd1:program_rom1[load_addr[12:0]]<=load_data;
      4'd2:program_rom2[load_addr[12:0]]<=load_data;
      4'd3:program_rom3[load_addr[12:0]]<=load_data;
      4'd4:program_rom4[load_addr[12:0]]<=load_data;
      4'd5:program_rom5[load_addr[12:0]]<=load_data;
      4'd6:program_rom6[load_addr[12:0]]<=load_data;
      4'd7:program_rom7[load_addr[12:0]]<=load_data;
      4'd8:program_rom8[load_addr[12:0]]<=load_data;
      default:;
     endcase
    end
    else if(load_offset<ROM_GFX1_BASE+32'h00004000)gfx1_p0[15'(load_offset-ROM_GFX1_BASE)]<=load_data;
    else if(load_offset<ROM_GFX1_BASE+32'h00008000)gfx1_p1[15'(load_offset-ROM_GFX1_BASE-32'h00004000)]<=load_data;
    else if(load_offset<ROM_GFX2_BASE)gfx1_p2[15'(load_offset-ROM_GFX1_BASE-32'h00008000)]<=load_data;
    else if(load_offset<ROM_GFX2_BASE+32'h00004000)gfx2_p0[15'(load_offset-ROM_GFX2_BASE)]<=load_data;
    else if(load_offset<ROM_GFX2_BASE+32'h00008000)gfx2_p1[15'(load_offset-ROM_GFX2_BASE-32'h00004000)]<=load_data;
    else if(load_offset<ROM_ADPCM_BASE)gfx2_p2[15'(load_offset-ROM_GFX2_BASE-32'h00008000)]<=load_data;
    else if(load_offset<ROM_PROMS_BASE)samples[16'(load_offset-ROM_ADPCM_BASE)]<=load_data;
    else if(load_offset<ROM_PROMS_BASE+32)palette_prom[load_addr[4:0]]<=load_data;
    else if(load_offset<ROM_SIZE)lookup_prom[9'(load_offset-ROM_PROMS_BASE-32)]<=load_data;
   end
  end
 end
endmodule
