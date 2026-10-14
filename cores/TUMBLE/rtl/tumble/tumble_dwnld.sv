`timescale 1ns/1ps
// ROM address and byte-lane transforms used by the Tumble bootleg boards. prog_addr is
// a 16-bit SDRAM word address relative to prog_ba; the MRA carries the exact
// MAME region byte lengths so padding between banks is never permuted.
module tumble_dwnld(
    input      [21:0] prog_addr,
    input      [ 1:0] prog_mask,
    input             dwnld_en,
    input      [ 1:0] prog_ba,
    input      [ 7:0] tile_xform,
    input      [ 7:0] sprite_xform,
    input      [ 7:0] main_xform,
    input      [23:0] tile_len_bytes,
    input      [23:0] sprite_len_bytes,
    output reg [21:0] post_addr,
    output reg [ 1:0] post_mask
);

wire [22:0] source_byte = {prog_addr,prog_mask[0]};
reg  [22:0] packed_byte;

function automatic [22:0] tumble_pack_byte(
    input [22:0] logical_addr,
    input [23:0] region_len
);
reg [22:0] half_len, local_addr;
reg [1:0] plane;
begin
    half_len = region_len[23:1];
    local_addr = logical_addr >= half_len ? logical_addr - half_len : logical_addr;
    // MAME's decode assigns its first declared plane to pixel bit 3, while
    // jtcninja_deco16 consumes byte lane 0 as pixel bit 0. Reverse the plane
    // lane when packing into {p3,p2,p1,p0} words.
    if (logical_addr >= half_len)
        plane = local_addr[0] ? 2'd0 : 2'd1;
    else
        plane = local_addr[0] ? 2'd2 : 2'd3;
    tumble_pack_byte = {local_addr[21:4],5'b0} |
                       {18'd0,local_addr[3:1],2'b0} | {21'd0,(2'd3-plane)};
end
endfunction

function automatic [21:0] tumble_reorder(
    input [21:0] addr,
    input [23:0] region_len
);
reg [21:0] offset;
begin
    // MAME swaps bytes separated by 0x20, then swaps the region halves.
    // On this 16-bit SDRAM port both byte XORs are expressed in word units.
    offset = region_len[23:2] | 22'd16;
    tumble_reorder = addr ^ offset;
end
endfunction

function automatic [21:0] suprtrio_tile(
    input [21:0] addr
);
begin
    // tumbleb.cpp: suprtrio_decrypt_gfx(), where i and j are uint16_t indices.
    suprtrio_tile = addr ^ 22'd2;
    if (addr[0]) suprtrio_tile = suprtrio_tile ^ 22'd4;
end
endfunction

// Super Trio tiles use tumbleb.cpp's suprtrio_tlayout: the four bit planes sit
// in separate quarters of the 1 MB region ({p3,p2,p1,p0} = quarters 2,0,3,1),
// each 16x16 tile takes 32 bytes per plane (left half bytes 0-15, right half
// 16-31) and the row order is 1,0,2,3,5,4,6,7,8..15. Repack the decrypted
// byte into the {p3,p2,p1,p0} 32-bit-per-8-pixels form the tile renderer reads.
function automatic [19:0] suprtrio_tile_pack(
    input [21:0] word_addr,
    input        odd_byte
);
reg [21:0] dec;
reg [19:0] d;
reg [12:0] tile;
reg        xhalf;
reg  [3:0] r, y;
reg  [1:0] lane;
begin
    dec   = suprtrio_tile(word_addr);
    d     = {dec[18:0], odd_byte};
    tile  = d[17:5];
    xhalf = d[4];
    r     = d[3:0];
    y     = (!r[3] && !r[1]) ? {r[3:1],~r[0]} : r;
    case (d[19:18])
        2'd0:    lane = 2'd2;
        2'd1:    lane = 2'd0;
        2'd2:    lane = 2'd3;
        default: lane = 2'd1;
    endcase
    // The renderer's packed order comes from tlayout, where the left 8 pixels
    // sit at the higher offset, so the half index is inverted.
    suprtrio_tile_pack = {tile,~xhalf,y[3],y[2:0],lane};
end
endfunction

function automatic [21:0] suprtrio_main(
    input [21:0] addr
);
begin
    // tumbleb.cpp: suprtrio_decrypt_code(). This address permutation is
    // self-inverse, so it places each incoming ROM word at its decrypted index.
    suprtrio_main = addr ^ 22'd6;
    if (!addr[0])       suprtrio_main = suprtrio_main ^ 22'd2;
    if (addr[1:0] == 0) suprtrio_main = suprtrio_main ^ 22'd8;
end
endfunction

always @* begin
    post_addr = prog_addr;
    post_mask = prog_mask;
    packed_byte = 23'd0;
    if (dwnld_en) case (prog_ba)
        2'd0: begin
            // The MRA stream is in MAME order: the first byte of each 68000
            // word is its high byte. jtframe_dwnld (SWAB=1) puts the first
            // byte in the low lane, which suits the 8-bit sound-CPU slot at
            // byte 0x100000-0x10ffff but byte-swaps every 16-bit read. Store
            // everything else in bank 0 (program, protection data and PIC
            // image) with the first byte in the high lane.
            if (prog_addr[21:15] != 7'h10)
                post_mask = {prog_mask[0],prog_mask[1]};
            if (main_xform == 8'd2 && prog_addr < 22'h040000)
                post_addr = suprtrio_main(prog_addr);
        end
        2'd1: if ({2'b0,prog_addr} < (tile_len_bytes >> 1)) begin
            case (tile_xform)
                8'd0, 8'd1: begin
                    if ({1'b0,source_byte} < tile_len_bytes) begin
                        if (tile_xform == 8'd1)
                            packed_byte = tumble_pack_byte(
                                source_byte ^ (tile_len_bytes[23:1] | 23'd32),
                                tile_len_bytes
                            );
                        else
                            packed_byte = tumble_pack_byte(
                                source_byte, tile_len_bytes
                            );
                        post_addr = packed_byte[22:1];
                        post_mask = packed_byte[0] ? 2'b01 : 2'b10;
                    end
                end
                8'd3: begin
                    packed_byte = {3'd0,suprtrio_tile_pack(prog_addr,prog_mask[0])};
                    post_addr = packed_byte[22:1];
                    post_mask = packed_byte[0] ? 2'b01 : 2'b10;
                end
                default:;
            endcase
        end
        2'd2: if ({2'b0,prog_addr} < (sprite_len_bytes >> 1)) begin
            if (sprite_xform == 8'd0 || sprite_xform == 8'd1) begin
                if ({1'b0,source_byte} < sprite_len_bytes) begin
                    if (sprite_xform == 8'd1)
                        packed_byte = tumble_pack_byte(
                            source_byte ^ (sprite_len_bytes[23:1] | 23'd32),
                            sprite_len_bytes
                        );
                    else
                        packed_byte = tumble_pack_byte(
                            source_byte, sprite_len_bytes
                        );
                    post_addr = packed_byte[22:1];
                    post_mask = packed_byte[0] ? 2'b01 : 2'b10;
                end
            end
        end
        default:;
    endcase
end

endmodule
