// SPDX-License-Identifier: GPL-3.0-or-later
// MAME 0.289 mystwarr.cpp:gaiapols_map is the address/direction reference.
// addr is the raw 24-bit CPU BYTE address, including A0. The byte strobes,
// rather than A0, select lanes: byte_mask[1] = upper, byte_mask[0] = lower.
// as_n/uds_n/lds_n are active low; rnw is high for a read. Every cs_* is
// qualified by a valid bus cycle, direction and the device's byte lane.
// rd/wr identify the bus direction even on an unmapped address. mapped says
// that the cycle reaches a driver window; it does not describe device-local
// register holes. window_id 0 means unmapped; IDs 1..28 are listed below.
// offset_word is the word offset within that window. The tile mirror has the
// SAME offsets as tile RAM. All consumers receive the original byte_mask.
// K054321 consumes only its upper lane; K053252/K054000 consume only lower.
// dddeeprom_r prioritizes IN1 on ANY upper-lane read, including a word read:
// in1_rd yields {IN1,8'h00}; p2_rd yields {8'h00,P2} only on a lower-only read.
// sprite_chip_sel/addr distinguish the compact K053247 words from the CPU's
// remaining scattered RAM; addr maps word bits [14:7,2:0] to chip [10:0].
module gaiapolis_decode (
    input wire monster,
    input  logic [23:0] addr,
    input  logic        as_n,
    input  logic        rnw,
    input  logic        uds_n,
    input  logic        lds_n,
    output logic        rd,
    output logic        wr,
    output logic [1:0]  byte_mask,
    output logic        mapped,
    output logic [4:0]  window_id,
    output logic [20:0] offset_word,
    output logic        cs_rom,
    output logic        cs_sprite_ram,
    output logic        cs_tile_ram,
    output logic        cs_palette,
    output logic        cs_sprite_ctrl,
    output logic        cs_tile_rom,
    output logic        cs_sprite_rom,
    output logic        cs_sprite_reg,
    output logic        cs_roz_ctrl,
    output logic        cs_roz_line,
    output logic        cs_tile_ctrl,
    output logic        cs_tile_bctrl,
    output logic        cs_roz_clip,
    output logic        cs_ccu,
    output logic        cs_priority,
    output logic        cs_sound,
    output logic        cs_mixer,
    output logic        cs_inputs,
    output logic        cs_eeprom_read,
    output logic        cs_workram,
    output logic        cs_collision,
    output logic        cs_eeprom_write,
    output logic        cs_roz_enable,
    output logic        cs_sound_irq,
    output logic        cs_roz_map0,
    output logic        cs_roz_map1,
    output logic        cs_roz_tiles,
    output logic        cs_watchdog,
    output logic        in1_rd,
    output logic        p2_rd,
    output logic        sprite_chip_sel,
    output logic [10:0] sprite_chip_addr
);
    wire active = !as_n && (!uds_n || !lds_n);
    wire [28:1] window_hit;
    assign byte_mask = {!as_n && !uds_n, !as_n && !lds_n};
    assign rd = active && rnw;
    assign wr = active && !rnw;
    // All board windows have disjoint address ranges. Decode each directly
    // so CPU strobes do not pass through an encoded priority window ID.
    assign window_hit[1] = active && (addr <= (monster ? 24'h1fffff : 24'h2fffff) && rd);
    assign window_hit[2] = active && (addr[23:16] == 8'h40);
    assign window_hit[3] = active && (addr[23:14] == 10'h104);
    assign window_hit[4] = active && (addr[23:13] == 11'h210);
    assign window_hit[5] = active && (addr[23:3] == 21'h86000 && wr);
    assign window_hit[6] = active && ((monster ? addr[23:14] == 10'h110 : addr[23:13] == 11'h220) && rd);
    assign window_hit[7] = active && (addr[23:4] == 20'h45000 && rd);
    assign window_hit[8] = active && (addr[23:4] == 20'h45001 && wr);
    assign window_hit[9] = active && (addr[23:5] == 19'h23000 && wr);
    assign window_hit[10] = active && (addr[23:12] == 12'h470);
    assign window_hit[11] = active && (addr[23:6] == 18'h12000 && wr);
    assign window_hit[12] = active && (addr[23:3] == 21'h90400 && wr);
    assign window_hit[13] = active && (addr[23:2] == 22'h121000 && wr);
    assign window_hit[14] = active && (addr[23:5] == 19'h24300 && byte_mask[0]);
    assign window_hit[15] = active && (addr[23:8] == 16'h4880 && wr);
    assign window_hit[16] = active && (addr[23:5] == 19'h24500 && byte_mask[1]);
    assign window_hit[17] = active && (addr[23:5] == 19'h24600 && wr);
    assign window_hit[18] = active && (addr[23:1] == 23'h247000 && rd);
    assign window_hit[19] = active && (addr[23:1] == 23'h247010 && rd);
    assign window_hit[20] = active && (addr[23:16] == 8'h60);
    assign window_hit[21] = active && (!monster && addr[23:6] == 18'h19800 && byte_mask[0]);
    assign window_hit[22] = active && (addr[23:1] == 23'h350000 && wr && byte_mask[0]);
    assign window_hit[23] = active && (addr[23:1] == 23'h360000 && wr);
    assign window_hit[24] = active && (addr[23:1] == 23'h370000 && wr);
    assign window_hit[25] = active && (addr[23:19] == 5'h10 && rd);
    assign window_hit[26] = active && (addr[23:19] == 5'h14 && rd);
    assign window_hit[27] = active && (addr[23:21] == 3'h6 && rd);
    assign window_hit[28] = active && (addr[23:1] == 23'h700000 && wr);
    assign mapped = |window_hit;
    assign cs_rom = window_hit[1];
    assign cs_sprite_ram = window_hit[2];
    assign cs_tile_ram = window_hit[3];
    assign cs_palette = window_hit[4];
    assign cs_sprite_ctrl = window_hit[5];
    assign cs_tile_rom = window_hit[6];
    assign cs_sprite_rom = window_hit[7];
    assign cs_sprite_reg = window_hit[8];
    assign cs_roz_ctrl = window_hit[9];
    assign cs_roz_line = window_hit[10];
    assign cs_tile_ctrl = window_hit[11];
    assign cs_tile_bctrl = window_hit[12];
    assign cs_roz_clip = window_hit[13];
    assign cs_ccu = window_hit[14];
    assign cs_priority = window_hit[15];
    assign cs_sound = window_hit[16];
    assign cs_mixer = window_hit[17];
    assign cs_inputs = window_hit[18];
    assign cs_eeprom_read = window_hit[19];
    assign cs_workram = window_hit[20];
    assign cs_collision = window_hit[21];
    assign cs_eeprom_write = window_hit[22];
    assign cs_roz_enable = window_hit[23];
    assign cs_sound_irq = window_hit[24];
    assign cs_roz_map0 = window_hit[25];
    assign cs_roz_map1 = window_hit[26];
    assign cs_roz_tiles = window_hit[27];
    assign cs_watchdog = window_hit[28];
    integer window_index;
    always_comb begin
        window_id = 5'd0;
        for(window_index=1; window_index<=28; window_index=window_index+1)
            window_id = window_id | ({5{window_hit[window_index]}} & window_index[4:0]);
    end
    assign offset_word =
        ({21{window_hit[1]}} & addr[21:1]) |
        ({21{(window_hit[2] | window_hit[20])}} & {6'd0,addr[15:1]}) |
        ({21{(window_hit[3] | window_hit[4])}} & {9'd0,addr[12:1]}) |
        ({21{window_hit[6]}} & {8'd0,addr[13:1]}) |
        ({21{(window_hit[5] | window_hit[12])}} & {19'd0,addr[2:1]}) |
        ({21{(window_hit[7] | window_hit[8])}} & {18'd0,addr[3:1]}) |
        ({21{(window_hit[9] | window_hit[14] | window_hit[16] | window_hit[17])}} & {17'd0,addr[4:1]}) |
        ({21{window_hit[10]}} & {10'd0,addr[11:1]}) |
        ({21{(window_hit[11] | window_hit[21])}} & {16'd0,addr[5:1]}) |
        ({21{window_hit[13]}} & {20'd0,addr[1]}) |
        ({21{window_hit[15]}} & {14'd0,addr[7:1]}) |
        ({21{(window_hit[25] | window_hit[26])}} & {2'd0,addr[19:1]}) |
        ({21{window_hit[27]}} & {1'b0,addr[20:1]});
    assign in1_rd = cs_eeprom_read && byte_mask[1];
    assign p2_rd = cs_eeprom_read && byte_mask[0] && !byte_mask[1];
    assign sprite_chip_sel = cs_sprite_ram && addr[7:4] == 4'd0;
    assign sprite_chip_addr = {addr[15:8],addr[3:1]};
endmodule
