module SoundWriteCast (
 input logic clk,load_wr,sound_io_rd,sound_ram_wr,
 input logic [24:0] load_addr,
 input logic [15:0] load_data,za,
 input logic [7:0] sound_io_read_data,sound_latch,zdout,
 output wire [7:0] zdin
);
 SoundWidthMemory memory(.clk(clk),.load_wr(load_wr),.sound_io_rd(sound_io_rd),
 .sound_ram_wr(sound_ram_wr),.load_addr(load_addr),.load_data(load_data),.za(za),
 .sound_io_read_data(sound_io_read_data),.sound_latch(sound_latch),.zdout(zdout),
 .debug_rom_kind(3'd0),.debug_rom_addr(16'd0),.debug_rom_data(),.zdin(zdin));
endmodule
module SoundWidthMemory (
 input logic clk,load_wr,sound_io_rd,sound_ram_wr,
 input logic [24:0] load_addr,
 input logic [15:0] load_data,za,debug_rom_addr,
 input logic [2:0] debug_rom_kind,
 input logic [7:0] sound_io_read_data,sound_latch,zdout,
 output logic [15:0] debug_rom_data,
 output wire [7:0] zdin
);
 logic [15:0] sound_rom [0:32767];
 logic [7:0] sound_ram [0:2047];
 always_ff @(posedge clk) begin
   if(load_wr && load_addr >= 'h20100 && load_addr < 'h30100)
     sound_rom[15'((load_addr-'h20100)>>1)] <= load_data;
   if(sound_ram_wr) sound_ram[za[10:0]] <= zdout;
   case(debug_rom_kind)
     2: debug_rom_data <= {sound_rom[debug_rom_addr[14:0]][7:0],sound_rom[debug_rom_addr[14:0]][15:8]};
     default: debug_rom_data <= 16'hffff;
   endcase
 end
 logic [15:0] sound_rom_q;
 logic sound_rom_lane_q,sound_rom_selected_q;
 logic [7:0] sound_nonrom_q;
 always_ff @(posedge clk) begin
   sound_rom_q <= sound_rom[za[15:1]];
   sound_rom_lane_q <= za[0];
   sound_rom_selected_q <= !sound_io_rd && za < 'hc000;
   if(sound_io_rd) sound_nonrom_q <= sound_io_read_data;
   else if(za >= 'hc000 && za < 'hc800) sound_nonrom_q <= sound_ram[za[10:0]];
   else if(za == 'he000) sound_nonrom_q <= sound_latch;
   else sound_nonrom_q <= 8'hff;
 end
 assign zdin=sound_rom_selected_q ? (sound_rom_lane_q?sound_rom_q[15:8]:sound_rom_q[7:0]):sound_nonrom_q;
endmodule
