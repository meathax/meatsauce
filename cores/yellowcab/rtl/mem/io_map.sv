// liberate_map + kamikcab bank view + yellowcb $A000 IN0
module io_map (
  input      [15:0] addr,
  input             rw,          // 1=read
  input             bank_en,

  output            work_cs,     // $0000-0FFF
  output            mir_cs,      // $1000-3FFF main mirror
  output            color_cs,    // $4000-43FF
  output            video_cs,    // $4400-47FF
  output            sprite_cs,   // $4800-4FFF
  output            work2_cs,    // $6200-67FF
  output            main_cs,     // $8000-FFFF ROM (when not banked IO read)
  output            io_w_cs,     // $8000-800F write always
  output            io_r_cs,     // $8000-800F read when bank_en
  output            user1_cs,    // $4000-7FFF when bank_en
  output            in0_cs,      // $A000 yellowcb
  output            bank_vram_hide // bank_en hides color/video/sprite under $4000-4FFF
);

wire in_40_7f = (addr[15:14] == 2'b01);          // 4000-7FFF
wire in_80_8f = (addr[15:4]  == 12'h800);

assign work_cs   = (addr[15:12] == 4'h0);
assign mir_cs    = (addr >= 16'h1000) && (addr <= 16'h3FFF);
// work2 RAM only when bank view is off; with bank_en, $4000-7FFF is user1 ROM
  // (MAME deco16_io view). Writes still hit work2 so RAM is not lost under the view.
  assign work2_cs  = (addr >= 16'h6200) && (addr <= 16'h67FF) && (!bank_en || !rw);

assign bank_vram_hide = bank_en && in_40_7f;

// MAME liberate_map installs the deco16_io view as READ-ONLY over $4000-$7FFF
//   map(0x4000, 0x800f).view(m_deco16_io);
//   m_deco16_io[0](0x4000, 0x7fff).rom().region("user1", 0);
// so with the bank enabled, writes in that range still reach colorram /
// videoram / spriteram in the base map. Gating these with !bank_en threw away
// every VRAM write made while the bank was on. (work2_cs above already got
// this right.)
assign user1_cs  = bank_en && in_40_7f && rw;
assign color_cs  = (!bank_en || !rw) && (addr >= 16'h4000) && (addr <= 16'h43FF);
assign video_cs  = (!bank_en || !rw) && (addr >= 16'h4400) && (addr <= 16'h47FF);
assign sprite_cs = (!bank_en || !rw) && (addr >= 16'h4800) && (addr <= 16'h4FFF);

assign io_w_cs   = in_80_8f && !rw;
assign io_r_cs   = in_80_8f &&  rw && bank_en;

assign in0_cs    = (addr == 16'hA000) && rw;

// Main ROM: 8000-FFFF except banked IO reads; also not when writing IO
assign main_cs   = (addr[15] == 1'b1) && !(io_r_cs) && !(io_w_cs) && !in0_cs;

endmodule
