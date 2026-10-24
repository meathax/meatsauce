/* SPDX-FileCopyrightText: 2026 Andrea Bogazzi
 * SPDX-License-Identifier: GPL-3.0-or-later */

module jtmnymny_hiscore_mux(
    input              hiscore_pause,
    input       [15:0] hiscore_addr,
    input        [7:0] hiscore_data_to_ram,
    input              hiscore_write,
    input              hiscore_intent_read,
    input              hiscore_intent_write,
    input       [11:0] cpu_addr,
    input        [7:0] cpu_dout,
    input              cpu_wrn,
    input              cpu_wram_we,
    input              cpu_vram_cs,
    input        [7:0] wram_dout,
    input        [7:0] vram_dout,
    output      [10:0] wram_addr,
    output       [7:0] wram_din,
    output             wram_we,
    output      [10:0] vram_addr,
    output       [7:0] vram_din,
    output             vram_we,
    output       [7:0] hiscore_data_from_ram
);

wire workram_selected = hiscore_addr[14:12] == 3'b111 && !hiscore_addr[11];
wire videoram_selected = hiscore_addr[14:12] == 3'b110 && !hiscore_addr[11];
wire ram_access = hiscore_pause &&
                  (hiscore_intent_read || hiscore_intent_write || hiscore_write);

assign wram_addr = ram_access && workram_selected ? hiscore_addr[10:0] : cpu_addr[10:0];
assign wram_din  = ram_access && workram_selected ? hiscore_data_to_ram : cpu_dout;
assign wram_we   = hiscore_pause ? (ram_access && workram_selected && hiscore_write) : cpu_wram_we;

assign vram_addr = ram_access && videoram_selected ? hiscore_addr[10:0] : cpu_addr[10:0];
assign vram_din  = ram_access && videoram_selected ? hiscore_data_to_ram : cpu_dout;
assign vram_we   = hiscore_pause ? (ram_access && videoram_selected && hiscore_write) :
                                    (cpu_vram_cs && !cpu_wrn);

assign hiscore_data_from_ram = videoram_selected ? vram_dout :
                               workram_selected  ? wram_dout : 8'hff;

endmodule
