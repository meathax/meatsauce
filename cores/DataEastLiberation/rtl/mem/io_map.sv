// liberate_map + kamikcab bank view + yellowcb $A000 IN0
module io_map (
  input      [15:0] addr,
  input             rw,          // 1=read
  input             bank_en,
  input             yellow_in0_override,
  input             prosport,

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
  output            bank_vram_hide, // bank_en hides color/video/sprite under $4000-4FFF

  // Pro Sports-only regions
  output            pro_ram_cs,
  output            pro_palette_cs,
  output            pro_bg_cs,
  output            pro_char_cs
);

wire in_40_7f = (addr[15:14] == 2'b01);          // 4000-7FFF
wire in_80_8f = (addr[15:4]  == 12'h800);

wire pro_base_ram = ((addr <= 16'h03ff) ||
                     ((addr >= 16'h2000) && (addr <= 16'h2fff)));
wire pro_palette  = ((addr >= 16'h0200) && (addr <= 16'h021f)) ||
                    ((addr >= 16'h2200) && (addr <= 16'h221f));

assign pro_palette_cs = prosport && pro_palette;
assign pro_bg_cs      = prosport && (addr >= 16'h0400) && (addr <= 16'h07ff);
assign pro_char_cs    = prosport && (addr >= 16'h0800) && (addr <= 16'h1fff);
assign pro_ram_cs     = prosport && pro_base_ram && !pro_palette;

assign work_cs   = !prosport && (addr[15:12] == 4'h0);
assign mir_cs    = !prosport && (addr >= 16'h1000) && (addr <= 16'h3FFF);
// work2 RAM only when bank view is off; with bank_en, $4000-7FFF is user1 ROM
  // (MAME deco16_io view). Writes still hit work2 so RAM is not lost under the view.
  assign work2_cs  = !prosport && (addr >= 16'h6200) && (addr <= 16'h67FF) && (!bank_en || !rw);

assign bank_vram_hide = !prosport && bank_en && in_40_7f;

// MAME liberate_map installs the deco16_io view as READ-ONLY over $4000-$7FFF
//   map(0x4000, 0x800f).view(m_deco16_io);
//   m_deco16_io[0](0x4000, 0x7fff).rom().region("user1", 0);
// so with the bank enabled, writes in that range still reach colorram /
// videoram / spriteram in the base map. Gating these with !bank_en threw away
// every VRAM write made while the bank was on. (work2_cs above already got
// this right.)
assign user1_cs  = !prosport && bank_en && in_40_7f && rw;
assign color_cs  = prosport ? ((addr >= 16'h3000) && (addr <= 16'h33FF)) :
                              ((!bank_en || !rw) && (addr >= 16'h4000) && (addr <= 16'h43FF));
assign video_cs  = prosport ? ((addr >= 16'h3400) && (addr <= 16'h37FF)) :
                              ((!bank_en || !rw) && (addr >= 16'h4400) && (addr <= 16'h47FF));
assign sprite_cs = prosport ? ((addr >= 16'h3800) && (addr <= 16'h3FFF)) :
                              ((!bank_en || !rw) && (addr >= 16'h4800) && (addr <= 16'h4FFF));

assign io_w_cs   = in_80_8f && !rw;
assign io_r_cs   = in_80_8f &&  rw && bank_en;

assign in0_cs    = !prosport && yellow_in0_override && (addr == 16'hA000) && rw;

// Main ROM: 8000-FFFF except banked IO reads; also not when writing IO
assign main_cs   = (prosport ? (addr >= 16'h4000) : (addr[15] == 1'b1)) &&
                   !(io_r_cs) && !(io_w_cs) && !in0_cs;

endmodule
