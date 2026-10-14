package suna8_bus_pkg;

// Main Z80 address-space helpers shared by the CPU wrapper and the memory
// map.  The returned ROM offset is a byte offset in the flat maincpu MRA
// region; it is deliberately independent of opcode/data decryption.
function automatic logic [3:0] suna8_rom_bank(
    input logic [2:0] profile,
    input logic [7:0] bank_latch
);
    logic [3:0] bank;
    begin
        case (profile)
            3'd1: begin // sranger / rranger_map
                bank = bank_latch[2:0];
                if (!bank_latch[4] && (bank >= 4))
                    bank = bank + 4;
            end
            default: bank = bank_latch[3:0];
        endcase
        suna8_rom_bank = bank;
    end
endfunction

function automatic logic [19:0] suna8_main_rom_offset(
    input logic [2:0] profile,
    input logic [7:0] bank_latch,
    input logic [15:0] cpu_address
);
    begin
        suna8_main_rom_offset = 20'd0;
        if (cpu_address < 16'h8000)
            suna8_main_rom_offset = {4'd0, cpu_address};
        else if (cpu_address < 16'hc000)
            suna8_main_rom_offset = 20'h10000 +
                                    ({16'd0, suna8_rom_bank(profile, bank_latch)} << 14) +
                                    (cpu_address - 16'h8000);
    end
endfunction

function automatic logic suna8_is_fixed_rom(input logic [15:0] address);
    suna8_is_fixed_rom = (address < 16'h8000);
endfunction

function automatic logic suna8_is_banked_rom(input logic [15:0] address);
    suna8_is_banked_rom = (address >= 16'h8000) && (address < 16'hc000);
endfunction

// Hard Head's fixed 0x0000-0x7fff ROM is hardware-scrambled: MAME's
// init_hardhead() bitswaps bits 3/4 and XORs with 0x58 for addresses where
// swaptable[(addr[14]<<2)|addr[11:10]] is set, applied identically to both
// opcode fetches and plain data reads (MAME decrypts rom[] once in place at
// driver init and points both the data map and the decrypted-opcode map at
// the same buffer). On real hardware this must be fixed glue logic between
// the ROM output and the bus, active on every access, so it is modelled
// here as a combinational function applied at read time rather than a
// one-time transform at ROM load.
function automatic logic [7:0] suna8_hardhead_descramble(
    input logic [15:0] address,
    input logic [7:0] data
);
    logic [2:0] table_index;
    logic swap;
    begin
        table_index = {address[14], address[11:10]};
        case (table_index)
            3'd0: swap = 1'b1;
            3'd1: swap = 1'b1;
            3'd2: swap = 1'b0;
            3'd3: swap = 1'b1;
            3'd4: swap = 1'b1;
            3'd5: swap = 1'b1;
            3'd6: swap = 1'b1;
            3'd7: swap = 1'b0;
        endcase
        if (swap)
            suna8_hardhead_descramble = {data[7:5], data[3], data[4], data[2:0]} ^ 8'h58;
        else
            suna8_hardhead_descramble = data;
    end
endfunction

// Spark Man protection (init_sparkman, suna8.cpp:428). Three independent
// layers, all confirmed against a passing MAME differential trace for
// hardhead's simpler single-layer scheme first (see verif/NOTES.md):
//   1. Address-line scrambling: PCB wiring swaps ROM address lines 7 and 8
//      for specific 4KB blocks across the whole flat maincpu region (fixed
//      + banked). Must be applied to the *address* before reading raw ROM
//      bytes, not to the data -- real hardware, the ROM chip itself never
//      sees the logical address.
//   2. Opcode-only transform (fixed ROM, <0x8000 only): a bit permutation
//      + XOR, keyed by a 5-bit block index, applied only when cpu_m1_n is
//      low (opcode fetch).
//   3. Data-only transform (fixed ROM, <0x8000 only): a different bit
//      permutation + XOR, keyed by a 3-bit block index, applied only for
//      plain data reads.
// Banked ROM (0x8000-0xbfff) only gets layer 1; MAME's opcode/data loops
// are bounded to i<0x8000.
function automatic logic suna8_sparkman_addr_swap_block(input logic [7:0] block);
    begin
        case (block)
            8'd0, 8'd1, 8'd2, 8'd3, 8'd6, 8'd7, 8'd72, 8'd73: suna8_sparkman_addr_swap_block = 1'b1;
            default: suna8_sparkman_addr_swap_block = 1'b0;
        endcase
    end
endfunction

function automatic logic [19:0] suna8_sparkman_addr_scramble(input logic [19:0] addr);
    begin
        if (suna8_sparkman_addr_swap_block(addr[19:12]))
            suna8_sparkman_addr_scramble = {addr[19:9], addr[7], addr[8], addr[6:0]};
        else
            suna8_sparkman_addr_scramble = addr;
    end
endfunction

function automatic logic suna8_sparkman_opcode_swap_block(input logic [4:0] table_idx);
    begin
        case (table_idx)
            5'd12, 5'd13, 5'd15, 5'd25: suna8_sparkman_opcode_swap_block = 1'b1;
            default: suna8_sparkman_opcode_swap_block = 1'b0;
        endcase
    end
endfunction

function automatic logic [7:0] suna8_sparkman_opcode_xor(input logic [4:0] table_idx);
    begin
        suna8_sparkman_opcode_xor = (table_idx == 5'd26) ? 8'h40 : 8'h00;
    end
endfunction

function automatic logic [7:0] suna8_sparkman_opcode_transform(
    input logic [7:0] data,
    input logic [19:0] address
);
    logic [4:0] table_idx;
    logic [7:0] stage1;
    logic [7:0] stage2;
    logic [7:0] result;
    begin
        table_idx = address[14:10];
        // bitswap<8>(x,5,6,7,3,4,2,1,0) ^ 0x44 ^ xortable[table]
        stage1 = {data[5], data[6], data[7], data[3], data[4], data[2], data[1], data[0]}
                 ^ 8'h44 ^ suna8_sparkman_opcode_xor(table_idx);
        // bitswap<8>(x,5,6,7,4,3,2,1,0) ^ 0x04, only if swaptable[table]
        stage2 = {stage1[5], stage1[6], stage1[7], stage1[4], stage1[3], stage1[2], stage1[1], stage1[0]}
                 ^ 8'h04;
        result = suna8_sparkman_opcode_swap_block(table_idx) ? stage2 : stage1;
        // init_sparkman patches the two c083 bit-7 protection checks in the
        // decrypted opcode view.  Keep these profile-scoped substitutions
        // until the physical PAL/protection device is modelled.
        case (address)
            20'h00ee0, 20'h00ee1, 20'h00ee2,
            20'h01ac3, 20'h01ac4, 20'h01ac5: result = 8'h00;
            default: ;
        endcase
        suna8_sparkman_opcode_transform = result;
    end
endfunction

function automatic logic suna8_sparkman_data_swap_block(input logic [2:0] table_idx);
    begin
        case (table_idx)
            3'd0, 3'd1, 3'd2, 3'd4, 3'd5, 3'd7: suna8_sparkman_data_swap_block = 1'b1;
            default: suna8_sparkman_data_swap_block = 1'b0;
        endcase
    end
endfunction

function automatic logic [7:0] suna8_sparkman_data_transform(
    input logic [7:0] data,
    input logic [19:0] address
);
    logic [2:0] table_idx;
    begin
        table_idx = address[14:12];
        // bitswap<8>(x,5,6,7,4,3,2,1,0) ^ 0x44, only if swaptable[table]
        if (suna8_sparkman_data_swap_block(table_idx))
            suna8_sparkman_data_transform =
                {data[5], data[6], data[7], data[4], data[3], data[2], data[1], data[0]} ^ 8'h44;
        else
            suna8_sparkman_data_transform = data;
    end
endfunction

// Star Fighter protection (init_starfigh, suna8.cpp:340). Same three-layer
// shape as Spark Man (address-line scramble, then separate opcode/data
// transforms on the descrambled fixed-ROM bytes) but with its own tables,
// its own XOR constant (0x45, not 0x44), a different scrambled address-bit
// pair (bits 6/7, not 7/8), and three explicit decrypted-opcode patches
// that MAME's driver_init applies after decryption. Those patches are kept
// here unchanged from MAME (bypassing a `c080` bit-7 protection check and
// two "work RAM writes disable" corruption points). They are retained as a
// per-profile behavioural compatibility layer because the protection silicon
// is still unidentified; replace them only when PCB evidence proves the
// device's native response. See suna8.cpp:404-413 for the source rationale.
function automatic logic suna8_starfigh_addr_swap_block(input logic [7:0] block);
    begin
        case (block)
            8'd0, 8'd1, 8'd2, 8'd3, 8'd4, 8'd5, 8'd72, 8'd73: suna8_starfigh_addr_swap_block = 1'b1;
            default: suna8_starfigh_addr_swap_block = 1'b0;
        endcase
    end
endfunction

function automatic logic [19:0] suna8_starfigh_addr_scramble(input logic [19:0] addr);
    begin
        if (suna8_starfigh_addr_swap_block(addr[19:12]))
            suna8_starfigh_addr_scramble = {addr[19:8], addr[6], addr[7], addr[5:0]};
        else
            suna8_starfigh_addr_scramble = addr;
    end
endfunction

function automatic logic suna8_starfigh_opcode_swap_block(input logic [4:0] table_idx);
    begin
        case (table_idx)
            5'd9, 5'd17: suna8_starfigh_opcode_swap_block = 1'b1;
            default: suna8_starfigh_opcode_swap_block = 1'b0;
        endcase
    end
endfunction

function automatic logic [7:0] suna8_starfigh_opcode_xor(input logic [4:0] table_idx);
    begin
        case (table_idx)
            5'd8, 5'd9, 5'd11, 5'd16, 5'd17, 5'd19: suna8_starfigh_opcode_xor = 8'h01;
            5'd10, 5'd18: suna8_starfigh_opcode_xor = 8'h41;
            default: suna8_starfigh_opcode_xor = 8'h00;
        endcase
    end
endfunction

function automatic logic [7:0] suna8_starfigh_opcode_transform(
    input logic [7:0] data,
    input logic [19:0] address
);
    logic [4:0] table_idx;
    logic [7:0] stage1;
    logic [7:0] stage2;
    logic [7:0] result;
    begin
        table_idx = address[14:10];
        stage1 = {data[5], data[6], data[7], data[3], data[4], data[2], data[1], data[0]}
                 ^ 8'h45 ^ suna8_starfigh_opcode_xor(table_idx);
        stage2 = {stage1[5], stage1[6], stage1[7], stage1[4], stage1[3], stage1[2], stage1[1], stage1[0]}
                 ^ 8'h04;
        result = suna8_starfigh_opcode_swap_block(table_idx) ? stage2 : stage1;
        case (address)
            20'h007c0: result = 8'hc9;
            20'h02696: result = 8'hc9;
            20'h04e9a: result = 8'h00;
            default: ;
        endcase
        suna8_starfigh_opcode_transform = result;
    end
endfunction

function automatic logic suna8_starfigh_data_swap_block(input logic [2:0] table_idx);
    begin
        case (table_idx)
            3'd0, 3'd1, 3'd3, 3'd5, 3'd6: suna8_starfigh_data_swap_block = 1'b1;
            default: suna8_starfigh_data_swap_block = 1'b0;
        endcase
    end
endfunction

function automatic logic [7:0] suna8_starfigh_data_transform(
    input logic [7:0] data,
    input logic [19:0] address
);
    logic [2:0] table_idx;
    begin
        table_idx = address[14:12];
        if (suna8_starfigh_data_swap_block(table_idx))
            suna8_starfigh_data_transform =
                {data[5], data[6], data[7], data[4], data[3], data[2], data[1], data[0]} ^ 8'h45;
        else
            suna8_starfigh_data_transform = data;
    end
endfunction

// Hard Head 2 protection (init_hardhea2, suna8.cpp:244). Same three-layer
// shape again, own tables: address scramble swaps bits 6/7 of the lower 16
// address bits only (bank nibble addr[19:16] passes through unscrambled),
// opcode transform swaps only bits 3/4 (no 5/6/7 rotation, unlike
// sparkman/starfigh) with a non-contiguous 5-bit table index assembled from
// addr[14:12]/addr[10]/addr[0], XOR 0x41, and no second XOR when the
// swapped second stage applies (sparkman/starfigh XOR 0x04 there, hardhea2
// doesn't). Data transform reuses the same bit-permutation shape as
// sparkman/starfigh's data layer, XOR 0x41. No explicit decrypted-opcode
// patches for this profile (unlike starfigh) as of suna8.cpp's
// init_hardhea2.
function automatic logic suna8_hardhea2_addr_swap_block(input logic [7:0] block);
    begin
        case (block)
            8'd0, 8'd1, 8'd2, 8'd3, 8'd6, 8'd7,
            8'd16, 8'd17, 8'd28, 8'd29,
            8'd64, 8'd65, 8'd72, 8'd73, 8'd76, 8'd77:
                suna8_hardhea2_addr_swap_block = 1'b1;
            default: suna8_hardhea2_addr_swap_block = 1'b0;
        endcase
    end
endfunction

function automatic logic [19:0] suna8_hardhea2_addr_scramble(input logic [19:0] addr);
    begin
        if (suna8_hardhea2_addr_swap_block(addr[19:12]))
            suna8_hardhea2_addr_scramble = {addr[19:16], addr[15:8], addr[6], addr[7], addr[5:0]};
        else
            suna8_hardhea2_addr_scramble = addr;
    end
endfunction

function automatic logic suna8_hardhea2_opcode_swap_block(input logic [4:0] table_idx);
    begin
        case (table_idx)
            5'd10, 5'd18, 5'd28, 5'd30, 5'd31: suna8_hardhea2_opcode_swap_block = 1'b0;
            default: suna8_hardhea2_opcode_swap_block = 1'b1;
        endcase
    end
endfunction

function automatic logic [7:0] suna8_hardhea2_opcode_xor(input logic [4:0] table_idx);
    begin
        case (table_idx)
            5'd0, 5'd1, 5'd3, 5'd5, 5'd8, 5'd11, 5'd13,
            5'd16, 5'd19, 5'd21, 5'd24, 5'd25, 5'd27, 5'd29:
                suna8_hardhea2_opcode_xor = 8'h04;
            5'd9, 5'd17: suna8_hardhea2_opcode_xor = 8'h45;
            default: suna8_hardhea2_opcode_xor = 8'h00;
        endcase
    end
endfunction

function automatic logic [7:0] suna8_hardhea2_opcode_transform(
    input logic [7:0] data,
    input logic [19:0] address
);
    logic [4:0] table_idx;
    logic [7:0] stage1;
    begin
        table_idx = {address[14:12], address[10], address[0]};
        stage1 = {data[7], data[6], data[5], data[3], data[4], data[2], data[1], data[0]}
                 ^ 8'h41 ^ suna8_hardhea2_opcode_xor(table_idx);
        if (suna8_hardhea2_opcode_swap_block(table_idx))
            suna8_hardhea2_opcode_transform =
                {stage1[5], stage1[6], stage1[7], stage1[4], stage1[3], stage1[2], stage1[1], stage1[0]};
        else
            suna8_hardhea2_opcode_transform = stage1;
    end
endfunction

function automatic logic suna8_hardhea2_data_swap_block(input logic [2:0] table_idx);
    begin
        case (table_idx)
            3'd0, 3'd1, 3'd3, 3'd5, 3'd6: suna8_hardhea2_data_swap_block = 1'b1;
            default: suna8_hardhea2_data_swap_block = 1'b0;
        endcase
    end
endfunction

function automatic logic [7:0] suna8_hardhea2_data_transform(
    input logic [7:0] data,
    input logic [19:0] address
);
    logic [2:0] table_idx;
    begin
        table_idx = address[14:12];
        if (suna8_hardhea2_data_swap_block(table_idx))
            suna8_hardhea2_data_transform =
                {data[5], data[6], data[7], data[4], data[3], data[2], data[1], data[0]} ^ 8'h41;
        else
            suna8_hardhea2_data_transform = data;
    end
endfunction

// Brick Zone protection (brickzn_decrypt/init_brickzn_common, suna8.cpp:113).
// No address-line scrambling (unlike every other protected profile), but
// opcode and data decryption interact rather than being independent layers:
// both conditions can apply to the same byte, sharing a final permutation
// step. Ported directly from MAME's C: bitswap1 swaps bits 0/1, bitswap2
// mirrors bits 2-6 around their centre.
//   opcode_swap = opcode_swaptable[{addr[6],addr[3:2]}]
//   data_swap   = (addr>=0x8000) ? 0 : data_swaptable[{addr[10],addr[3],addr[1:0]}]
//   data byte   = data_swap ? bitswap2(bitswap1(raw)) ^ 0x10 : raw
//   opcode byte = starts from raw, applies bitswap1 first iff data_swap,
//                 then ^0x80 iff opcode_swap, then bitswap2^0x10 iff
//                 (opcode_swap || data_swap)
// MAME also prepares an alternate banked-data view at rom[i+0x40000] by
// XORing the raw banked bytes with 0x44.  The MiSTer image keeps the source
// ROMs in their normal flat region, so the equivalent is applied at the bus
// boundary when the protection state selects that view (see
// suna8_brickzn_alt_data_transform below).
function automatic logic suna8_brickzn_opcode_swap(input logic [19:0] address);
    logic [2:0] idx;
    begin
        idx = {address[6], address[3:2]};
        case (idx)
            3'd0, 3'd1, 3'd2, 3'd5, 3'd6: suna8_brickzn_opcode_swap = 1'b1;
            default: suna8_brickzn_opcode_swap = 1'b0;
        endcase
    end
endfunction

function automatic logic suna8_brickzn_data_swap(input logic [19:0] address);
    logic [3:0] idx;
    begin
        if (address >= 20'h08000) begin
            suna8_brickzn_data_swap = 1'b0;
        end else begin
            idx = {address[10], address[3], address[1:0]};
            case (idx)
                4'd9: suna8_brickzn_data_swap = 1'b0;
                4'd3, 4'd4: suna8_brickzn_data_swap = 1'b0;
                default: suna8_brickzn_data_swap = 1'b1;
            endcase
        end
    end
endfunction

function automatic logic [7:0] suna8_brickzn_bitswap1(input logic [7:0] x);
    suna8_brickzn_bitswap1 = {x[7:2], x[0], x[1]};
endfunction

function automatic logic [7:0] suna8_brickzn_bitswap2(input logic [7:0] x);
    suna8_brickzn_bitswap2 = {x[7], x[2], x[3], x[4], x[5], x[6], x[1], x[0]};
endfunction

function automatic logic [7:0] suna8_brickzn_data_transform(
    input logic [7:0] raw,
    input logic [19:0] address
);
    begin
        if (suna8_brickzn_data_swap(address))
            suna8_brickzn_data_transform = suna8_brickzn_bitswap2(suna8_brickzn_bitswap1(raw)) ^ 8'h10;
        else
            suna8_brickzn_data_transform = raw;
    end
endfunction

function automatic logic [7:0] suna8_brickzn_alt_data_transform(
    input logic [7:0] raw
);
    // MAME's alternate bank is rom[i] ^ 0x44 for i >= 0x10000.  Those
    // addresses are never subject to the fixed-ROM data permutation above.
    suna8_brickzn_alt_data_transform = raw ^ 8'h44;
endfunction

function automatic logic [7:0] suna8_brickzn_sound_transform(
    input logic [7:0] data
);
    // brickzn_multi_w's optional remap is a wiring permutation in front of
    // the sound latch, not a software-side command-table change.
    suna8_brickzn_sound_transform =
        {data[7], data[6], data[3], data[4], data[5], data[2], data[1], data[0]};
endfunction

function automatic logic [7:0] suna8_brickzn_opcode_transform(
    input logic [7:0] raw,
    input logic [19:0] address
);
    logic data_swap;
    logic opcode_swap;
    logic [7:0] x;
    begin
        data_swap = suna8_brickzn_data_swap(address);
        opcode_swap = suna8_brickzn_opcode_swap(address);
        x = data_swap ? suna8_brickzn_bitswap1(raw) : raw;
        if (opcode_swap)
            x = x ^ 8'h80;
        if (opcode_swap || data_swap)
            x = suna8_brickzn_bitswap2(x) ^ 8'h10;
        // The curated parent is MAME's brickzn set.  Its driver_init applies
        // these documented protection/boot workarounds to the decrypted low
        // opcode image because the original security PAL is not dumped.
        case (address)
            20'h011cc, 20'h011cd, 20'h011ce: x = 8'h00;
            20'h0335b, 20'h01442: x = 8'hc9;
            20'h024c6, 20'h025a4: x = 8'h00;
            default: ;
        endcase
        suna8_brickzn_opcode_transform = x;
    end
endfunction

function automatic logic [2:0] suna8_sprite_bank(
    input logic [2:0] profile,
    input logic [7:0] sprite_latch,
    input logic [7:0] sprite_bank_data
);
    logic [2:0] bank;
    begin
        bank = 3'd0;
        case (profile)
            3'd2: begin
                // MAME sparkman_spritebank_w: m_spritebank =
                // ((data>>1)&1) | ((data<<1)&2), i.e. bits 0 and 1 of the
                // write data are swapped, not passed through directly.
                bank = {1'b0, sprite_bank_data[0], sprite_bank_data[1]};
                // sparkman_spritebank_latch_w stores (data>>4)&3 into
                // m_spritebank_latch, and the invert test reads bit 1 of
                // that reduced value -- i.e. bit 5 of the raw latch byte
                // kept here.
                if (sprite_latch[5])
                    bank = bank ^ 3'b011;
            end
            // This function has exactly one call site (suna8_main_memory.sv,
            // the profile==3'd2 case), so profile is always 3'd2 here.
            // Hard Head 2 and Brick Zone read cpu_dout[1] directly at their
            // own call sites instead of going through this function; a
            // dead 3'd4/3'd5 branch here previously used the wrong bit
            // (sprite_bank_data[0]) and would have gone live silently if
            // anyone ever routed those profiles through it.
            default: bank = 3'd0;
        endcase
        suna8_sprite_bank = bank;
    end
endfunction

function automatic logic [9:0] suna8_palette_address(
    input logic [2:0] profile,
    input logic palette_bank,
    input logic [15:0] cpu_address
);
    begin
        if (profile == 3'd0)
            suna8_palette_address = {1'b0, (cpu_address - 16'hd800)};
        else if ((profile == 3'd5) && palette_bank)
            suna8_palette_address = 10'h200 + (cpu_address - 16'hc600);
        else
            suna8_palette_address = {1'b0, (cpu_address - 16'hc600)};
    end
endfunction

endpackage
