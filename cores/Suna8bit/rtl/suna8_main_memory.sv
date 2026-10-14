module suna8_main_memory
(
    input  logic clk,
    input  logic reset,
    input  logic [2:0] profile_id,

    input  logic [15:0] cpu_addr,
    input  logic [7:0] cpu_dout,
    input  logic cpu_mreq_n,
    input  logic cpu_iorq,
    input  logic cpu_rd_n,
    input  logic cpu_wr_n,
    input  logic cpu_m1_n,
    // Hiscore work-RAM access; see suna8_core.sv.
    input  logic hs_pause,
    input  logic [15:0] hs_addr,
    input  logic [7:0] hs_din,
    input  logic hs_wr,
    output logic [7:0] hs_dout,
    output logic [7:0] cpu_din,

    output logic [19:0] main_rom_addr,
    output logic [19:0] opcode_rom_addr,
    input  logic [7:0] main_rom_q,
    input  logic [7:0] opcode_rom_q,

    input  logic [7:0] input_p1,
    input  logic [7:0] input_p2,
    input  logic [7:0] dip_1,
    input  logic [7:0] dip_2,
    input  logic [7:0] buttons,
    input  logic [7:0] spinner_1,
    input  logic [7:0] spinner_2,
    input  logic [7:0] cheats,
    input  logic [31:0] frame_counter,
    input  logic vblank,
    input  logic [7:0] soundlatch2_in,

    output logic palette_wr,
    output logic [9:0] palette_wr_addr,
    output logic [7:0] palette_wr_data,
    output logic [9:0] palette_rd_addr,
    input  logic [7:0] palette_rd_q,

    output logic sprite_wr,
    output logic [15:0] sprite_wr_addr,
    output logic [7:0] sprite_wr_data,
    output logic [15:0] sprite_rd_addr,
    input  logic [7:0] sprite_rd_q,

    output logic sound_latch_wr,
    output logic [7:0] sound_latch_data,
    output logic [7:0] rom_bank_latch,
    output logic [2:0] sprite_bank,
    output logic [1:0] work_ram_bank,
    output logic palette_bank,
    output logic flip_screen,
    output logic nmi_enable,
    output logic palette_write_enable,
    output logic [2:0] gfx_bank_latch,
    output logic [7:0] protection_2_prev_state,
    output logic [7:0] protection_2_state,
    output logic soundlatch2_clear,
    output logic [1:0] start_leds,
    output logic [1:0] coin_counters,
    output logic [1:0] coin_lockouts
);

    import suna8_bus_pkg::*;

    // Registered (one cycle of latency) rather than combinational: Quartus
    // cannot map a combinational read onto Cyclone V's M10K block RAM and
    // reports this array "uninferred due to asynchronous read logic" when
    // the read sits under a condition (here, "if (work_selected)"), same
    // root cause as suna8_sprite_ram.sv and suna8_sound_memory.sv (see
    // those files for the fuller rationale). The main CPU only runs on
    // ce_cpu = ce_pix (1 in 4 raw clk cycles, see suna8_core.sv's u_main_cpu
    // instantiation), so the extra raw-clk cycle of read latency resolves
    // well before the CPU's own next sample point.
    //
    // The write side also needs a single, uniformly-shaped write port: this
    // array used to be written from two structurally different sites (the
    // normal "work_ram[work_addr] <= cpu_dout" under work_selected, and a
    // second, independent "work_ram[14'h599] <= 8'hff" sranger protection
    // poke at a hardcoded address, both inside the same always_ff). Quartus
    // never classifies an array with more than one differently-shaped write
    // expression as a RAM candidate at all -- unlike the read-side case
    // above, this failure is completely silent (no "uninferred" info line
    // anywhere in the synthesis log), and it was overflowing this device's
    // LAB budget by itself (131,092 registers, one per array bit, for just
    // this 16 KiB array -- confirmed via the Aug 2026 fit failure: sys_top
    // needed 9076 LABs against 4191 available, almost entirely attributable
    // to suna8_main_memory's 73,345 ALMs). work_wr_en/addr/data below fold
    // both write sites into one muxed write port so Quartus can infer this
    // as block RAM the same way it already does for suna8_sprite_ram.sv and
    // suna8_sound_memory.sv.
    logic [7:0] work_ram [0:16383];
    logic [7:0] work_ram_q;
    logic work_wr_en;
    logic [13:0] work_wr_addr;
    logic [7:0] work_wr_data;
    logic [7:0] protection_val;
    logic [7:0] protection_2;
    logic [7:0] protection_2_prev;

    assign protection_2_prev_state = protection_2_prev;
    assign protection_2_state = protection_2;
    logic [1:0] start_led_state;
    logic [1:0] coin_counter_state;
    logic [1:0] coin_lockout_state;
    assign start_leds = start_led_state;
    assign coin_counters = coin_counter_state;
    assign coin_lockouts = coin_lockout_state;
    logic [7:0] hardhead_input_select;
    logic [7:0] sprite_bank_latch;
    logic [7:0] rom_bank_latch_shadow;
    logic write_disable;
    logic brickzn_work_write_disable;
    logic brickzn_alt_data;
    logic brickzn_opcode_toggle;
    logic brickzn_remap_sound;
    logic cpu_write;
    logic cpu_io_write;
    logic work_selected;
    logic palette_selected;
    logic sprite_selected;
    logic [13:0] work_addr;
    // Work-RAM decode address: the CPU's, or the hiscore module's while it
    // holds the CPU paused. Going through the same per-profile decode
    // (including Hard Head 2's current work-RAM bank) reproduces what
    // MAME's hiscore plugin reads through the program space.
    logic [15:0] ws_addr;
    assign ws_addr = hs_pause ? hs_addr : cpu_addr;
    assign hs_dout = work_ram_q;
    logic [12:0] sprite_offset;
    logic brickzn_cheat_read;
    logic brickzn_cheat_read_d;
    // cpu_write is a combinational level held for the whole Z80 write bus
    // phase (~6 raw clk cycles at ce_cpu=1-in-4). The register-write case
    // block below used to run every one of those cycles; most assignments
    // there are idempotent (re-latching the same byte), but a few are not
    // (protection_2_prev/protection_2 form a one-write-behind pair, and
    // brickzn_opcode_toggle is a toggle) and silently corrupted after the
    // second repeat -- protection_2_prev==protection_2 permanently defeats
    // brickzn_work_write_disable/_remap_sound/_alt_data, and the toggle's
    // parity becomes a function of bus timing instead of the program.
    // Edge-qualify the whole block instead of auditing each assignment
    // individually; every other latch there resolves to the same value
    // whether written once or six times, so this changes nothing for them.
    logic cpu_write_d;
    wire cpu_write_edge = cpu_write && !cpu_write_d;
    // MAME's function-local static starts low at process launch and is not
    // cleared by an emulated-machine reset. FPGA configuration is the
    // equivalent launch boundary, so initialize here and only toggle below.
    logic brickzn_cheat_bit2 = 1'b0;

    function automatic logic [7:0] hardhead_protection_read(input logic [7:0] offset);
        begin
            if (protection_val[7])
                hardhead_protection_read =
                    ((~offset[5]) ? 8'h20 : 8'h00) |
                    (protection_val[2] ? 8'h80 : 8'h00) |
                    (protection_val[0] ? 8'h04 : 8'h00);
            else
                hardhead_protection_read =
                    ((~offset[5]) ? 8'h20 : 8'h00) |
                    (((offset[0] ^ protection_val[0])) ? 8'h84 : 8'h00);
        end
    endfunction

    assign cpu_write = !cpu_mreq_n && !cpu_iorq && !cpu_wr_n;
    // Z80 I/O cycles assert IORQ while MREQ remains inactive (high).
    assign cpu_io_write = cpu_mreq_n && cpu_iorq && !cpu_wr_n;
    assign soundlatch2_clear = (profile_id == 3'd1) &&
        !cpu_mreq_n && !cpu_iorq && !cpu_rd_n && (cpu_addr == 16'hc004);
    assign brickzn_cheat_read = (profile_id == 3'd5) && !cpu_mreq_n &&
        !cpu_iorq && !cpu_rd_n && (cpu_addr == 16'hc140);

    always_ff @(posedge clk)
        work_ram_q <= work_ram[work_addr];

    always_comb begin
        work_wr_en = 1'b0;
        work_wr_addr = work_addr;
        work_wr_data = cpu_dout;
        if (hs_pause) begin
            // The paused CPU's own bus cycle (possibly a held write) is
            // locked out of work RAM for the duration.
            work_wr_en = hs_wr && work_selected;
            work_wr_data = hs_din;
        end else if (cpu_write && work_selected &&
            !(profile_id == 3'd5 && brickzn_work_write_disable) &&
            !(profile_id == 3'd2 && write_disable)) begin
            work_wr_en = 1'b1;
        end else if (cpu_write && profile_id == 3'd1 && cpu_addr == 16'hc200) begin
            // sranger_prot_w pokes 0xcd99 directly; that is work_ram offset
            // 0xcd99 - 0xc800 = 0x599. Merged into the same single write
            // port as the normal work_selected write above (not an
            // independent write pattern) -- see the work_wr_en/addr/data
            // declaration comment for why a second, differently-shaped
            // write site defeats block RAM inference.
            work_wr_en = 1'b1;
            work_wr_addr = 14'h599;
            work_wr_data = 8'hff;
        end
    end

    always_comb begin
        main_rom_addr = suna8_main_rom_offset(profile_id, rom_bank_latch, cpu_addr);
        if (profile_id == 3'd2)
            main_rom_addr = suna8_sparkman_addr_scramble(main_rom_addr);
        else if (profile_id == 3'd3)
            main_rom_addr = suna8_starfigh_addr_scramble(main_rom_addr);
        else if (profile_id == 3'd4)
            main_rom_addr = suna8_hardhea2_addr_scramble(main_rom_addr);
        opcode_rom_addr = main_rom_addr;

        work_selected = 1'b0;
        work_addr = 14'd0;
        palette_selected = 1'b0;
        sprite_selected = (cpu_addr >= 16'he000);

        if ((profile_id == 3'd0) && (ws_addr >= 16'hc000) && (ws_addr < 16'hd800)) begin
            work_selected = 1'b1;
            work_addr = ws_addr - 16'hc000;
        end else if ((profile_id == 3'd4) && (ws_addr >= 16'hc800) && (ws_addr < 16'he000)) begin
            work_selected = 1'b1;
            work_addr = {work_ram_bank[0], ws_addr[12:0]};
        end else if ((profile_id != 3'd0) && (ws_addr >= 16'hc800) && (ws_addr < 16'he000)) begin
            work_selected = 1'b1;
            work_addr = ws_addr - 16'hc800;
        end

        if ((profile_id == 3'd0) && (cpu_addr >= 16'hd800) && (cpu_addr < 16'hda00)) begin
            palette_selected = 1'b1;
        end else if ((profile_id != 3'd0) && (cpu_addr >= 16'hc600) && (cpu_addr < 16'hc800)) begin
            palette_selected = 1'b1;
        end

        palette_rd_addr = 10'd0;
        if (palette_selected)
            palette_rd_addr = suna8_palette_address(profile_id, palette_bank,
                                                     cpu_addr);

        // The banked sprite device has four 0x2000-byte banks.  Keeping the
        // virtual offset at 13 bits is important: concatenating a 14-bit
        // subtraction would stride by 0x4000 and alias the physical banks.
        sprite_offset = cpu_addr - 16'he000;
        sprite_rd_addr = {1'b0, sprite_bank[1:0], sprite_offset};
        if (profile_id == 3'd0 || profile_id == 3'd1)
            sprite_rd_addr = cpu_addr - 16'he000;

        cpu_din = 8'hff;
        if (suna8_is_fixed_rom(cpu_addr) || suna8_is_banked_rom(cpu_addr)) begin
            if (profile_id == 3'd0 && suna8_is_fixed_rom(cpu_addr))
                cpu_din = suna8_hardhead_descramble(cpu_addr, cpu_m1_n ? main_rom_q : opcode_rom_q);
            else if (profile_id == 3'd2 && suna8_is_fixed_rom(cpu_addr))
                cpu_din = cpu_m1_n
                    ? suna8_sparkman_data_transform(main_rom_q, cpu_addr)
                    : suna8_sparkman_opcode_transform(opcode_rom_q, cpu_addr);
            else if (profile_id == 3'd3 && suna8_is_fixed_rom(cpu_addr))
                cpu_din = cpu_m1_n
                    ? suna8_starfigh_data_transform(main_rom_q, cpu_addr)
                    : suna8_starfigh_opcode_transform(opcode_rom_q, cpu_addr);
            else if (profile_id == 3'd4 && suna8_is_fixed_rom(cpu_addr))
                cpu_din = cpu_m1_n
                    ? suna8_hardhea2_data_transform(main_rom_q, cpu_addr)
                    : suna8_hardhea2_opcode_transform(opcode_rom_q, cpu_addr);
            else if (profile_id == 3'd5) begin
                if (cpu_m1_n) begin
                    // The newer Brick Zone protection sequence can select a
                    // second banked-data view.  MAME materializes it at a
                    // hidden ROM offset as raw_byte ^ 44; apply that exact
                    // transform here without overlapping the flat MRA image.
                    if (brickzn_alt_data && suna8_is_banked_rom(cpu_addr))
                        cpu_din = suna8_brickzn_alt_data_transform(main_rom_q);
                    else
                        cpu_din = suna8_brickzn_data_transform(main_rom_q, main_rom_addr);
                end else if (brickzn_opcode_toggle && suna8_is_fixed_rom(cpu_addr)) begin
                    // The protection device toggles the low opcode map
                    // between MAME's decrypted view and the post-data-
                    // permutation ROM view.  The latter is the same
                    // transform used for a fixed-ROM data read.
                    cpu_din = suna8_brickzn_data_transform(opcode_rom_q, main_rom_addr);
                end else begin
                    cpu_din = suna8_brickzn_opcode_transform(opcode_rom_q, main_rom_addr);
                end
            end
            else
                cpu_din = cpu_m1_n ? main_rom_q : opcode_rom_q;
        end else if (work_selected) begin
            cpu_din = work_ram_q;
        end else if (palette_selected) begin
            cpu_din = palette_rd_q;
        end else if (sprite_selected) begin
            cpu_din = sprite_rd_q;
        end else begin
            case (profile_id)
                3'd0: begin
                    if (cpu_addr == 16'hda00) begin
                        case (hardhead_input_select[1:0])
                            2'd0: cpu_din = input_p1;
                            2'd1: cpu_din = input_p2;
                            2'd2: cpu_din = dip_1;
                            default: cpu_din = dip_2;
                        endcase
                    end else if (cpu_addr == 16'hda80)
                        cpu_din = soundlatch2_in;
                    else if (cpu_addr >= 16'hdd80 && cpu_addr < 16'hde00)
                        cpu_din = hardhead_protection_read(cpu_addr - 16'hdd80);
                end
                3'd1: begin
                    case (cpu_addr)
                        // rranger_map: $C000 is the watchdog's
                        // reset_r/reset_w-shared address (read side-effect
                        // re-arms it, matching cpu_read_c000_sranger
                        // below). suna8.cpp never calls
                        // unmap_value_high(), so MAME's address_map default
                        // (m_unmapval=0, addrmap.cpp) makes
                        // watchdog_timer_device::reset_r()'s
                        // `return space.unmap();` read as 0x00, not the
                        // 0xFF this case previously fell through to.
                        16'hc000: cpu_din = 8'h00;
                        16'hc002: cpu_din = input_p1;
                        16'hc003: cpu_din = input_p2;
                        16'hc004: cpu_din = 8'h02;
                        // $C200 is rranger_map's protection address
                        // (.nopr() -- AMH_NOP read handler type, which
                        // also resolves to the address_map's default
                        // m_unmapval=0, same as $C000 above). Read 786
                        // times per this profile's own copy loop at
                        // $0853-0858 (LD A,($C200)/LD (HL),A/INC HL/DJNZ) --
                        // an 0xFF-vs-0x00 mismatch here fills that loop's
                        // destination buffer with the wrong constant byte,
                        // which downstream code reads back as data.
                        16'hc200: cpu_din = 8'h00;
                        16'hc280: cpu_din = dip_1;
                        16'hc2c0: cpu_din = dip_2;
                        default: cpu_din = 8'hff;
                    endcase
                end
                // sparkman_map: inputs at c000-c003, BUTTONS mirrored at
                // c080/c081, and the copyright-timer parity bit at c0a3.
                3'd2: begin
                    case (cpu_addr)
                        16'hc000: cpu_din = input_p1;
                        16'hc001: cpu_din = input_p2;
                        16'hc002: cpu_din = dip_1;
                        16'hc003: cpu_din = dip_2;
                        16'hc080, 16'hc081: cpu_din = buttons;
                        16'hc0a3: cpu_din = frame_counter[0] ? 8'h80 : 8'h00;
                        default: begin
                            // sparkman_map's $C200-C57F ranges
                            // (spritebank_w/rombank_latch_w/
                            // spritebank_latch_w/write_disable_w/
                            // rombank_w+leds/coin_counter_w/
                            // starfigh_sound_latch_w) are all write-only in
                            // MAME -- no .r() handler at all -- so a CPU
                            // read anywhere in that span hits the address
                            // map's default unmap value (0, since
                            // suna8.cpp never calls unmap_value_high()),
                            // not 0xFF. Confirmed genuinely read (not just
                            // written) at several offsets within this span
                            // in a real attract-mode trace ($C200, $C280,
                            // $C292, $C300, $C343, $C380, $C388, $C3BF,
                            // $C3C4, $C400, $C480, $C500).
                            if (cpu_addr >= 16'hc200 && cpu_addr < 16'hc600)
                                cpu_din = 8'h00;
                            else
                                cpu_din = 8'hff;
                        end
                    endcase
                end
                // starfigh_map: inputs at c000-c003; c080 is CHEATS, not
                // BUTTONS. No spinners, no c0a3, no c140 on this profile.
                // CHEATS bit 6 ($40) is not a real input bit -- suna8.cpp's
                // starfigh INPUT_PORTS_START wires it directly to the
                // screen's live vblank line (PORT_READ_LINE_DEVICE_MEMBER
                // ("screen", screen_device::vblank), IP_ACTIVE_HIGH).
                3'd3: begin
                    case (cpu_addr)
                        16'hc000: cpu_din = input_p1;
                        16'hc001: cpu_din = input_p2;
                        16'hc002: cpu_din = dip_1;
                        16'hc003: cpu_din = dip_2;
                        16'hc080: cpu_din = {cheats[7], vblank, cheats[5:0]};
                        default: begin
                            // starfigh_map's $C200-C500 write-only ranges
                            // (spritebank_w/rombank_latch_w/flipscreen_w/
                            // spritebank_latch_w/leds_w/sound_latch_w) have
                            // no .r() handler in MAME, same as sparkman's
                            // equivalent span -- reads there hit the
                            // address map's default unmap value (0), not
                            // 0xFF. Confirmed genuinely read at several
                            // offsets in a real attract-mode trace ($C200,
                            // $C280, $C286, $C2D1, $C300, $C380, $C389,
                            // $C393, $C397, $C3B4, $C3B9, $C3C2, $C3D1,
                            // $C3E3, $C400, $C480, $C500).
                            if (cpu_addr >= 16'hc200 && cpu_addr < 16'hc600)
                                cpu_din = 8'h00;
                            else
                                cpu_din = 8'hff;
                        end
                    endcase
                end
                // hardhea2_map: inputs at c000-c003, BUTTONS at c080 only.
                // BUTTONS bit 6 ($40) is likewise wired to live vblank in
                // suna8.cpp's hardhea2 INPUT_PORTS_START, not a real button.
                3'd4: begin
                    case (cpu_addr)
                        16'hc000: cpu_din = input_p1;
                        16'hc001: cpu_din = input_p2;
                        16'hc002: cpu_din = dip_1;
                        16'hc003: cpu_din = dip_2;
                        16'hc080: cpu_din = {buttons[7], vblank, buttons[5:0]};
                        default: cpu_din = 8'hff;
                    endcase
                end
                // brickzn_map: inputs move to c100-c103 (c000-c003 are
                // unmapped for this profile); spinners and cheats add on.
                default: begin
                    case (cpu_addr)
                        16'hc100: cpu_din = input_p1;
                        16'hc101: cpu_din = input_p2;
                        16'hc102: cpu_din = dip_1;
                        16'hc103: cpu_din = dip_2;
                        16'hc108: cpu_din = spinner_1;
                        16'hc10c: cpu_din = spinner_2;
                        // MAME's brickzn_cheats_r toggles bit 2 before each
                        // returned value. Present the next state immediately
                        // on entry to the Z80 read cycle, then latch it once;
                        // the read strobe lasts several raw clocks here.
                        16'hc140: cpu_din = {
                            cheats[7:3],
                            (brickzn_cheat_read && !brickzn_cheat_read_d)
                                ? ~brickzn_cheat_bit2 : brickzn_cheat_bit2,
                            cheats[1:0]
                        };
                        default: begin
                            // brickzn_map's register span ($C040 rombank,
                            // $C060 sprbank+protection, $C0A0 the multiplexed
                            // palbank/soundlatch/leds, $C0C0 protection 2) is
                            // write-only in MAME -- no .r() handler at all --
                            // so a CPU read anywhere in $C000-$C5FF that is
                            // not one of the input/spinner/cheat addresses
                            // above returns the address map's default unmap
                            // value (0, since suna8.cpp never calls
                            // unmap_value_high()), not 0xFF. Returning 0xFF
                            // made the protection handshake write the exact
                            // bitwise complement of MAME's values from
                            // frame ~862 on (0xff for 0x00, 0x07 for 0xf8,
                            // confirmed by diffing the two register-write
                            // streams), which sent the CPU down a different
                            // path at level entry: a garbage sprite list, the
                            // palette left in bank 1, and a fully white
                            // screen. sparkman and starfigh already carry
                            // this same correction for their own write-only
                            // spans; Brick Zone's starts at $C000 rather
                            // than $C200 because its registers sit lower.
                            if (cpu_addr >= 16'hc000 && cpu_addr < 16'hc600)
                                cpu_din = 8'h00;
                            else
                                cpu_din = 8'hff;
                        end
                    endcase
                end
            endcase
        end

        palette_wr = cpu_write && palette_selected && palette_write_enable;
        palette_wr_addr = suna8_palette_address(profile_id, palette_bank,
                                                cpu_addr);
        palette_wr_data = cpu_dout;

        // Both Spark Man C380 and Brick Zone C0C0 gate only work RAM
        // (C800-DFFF).  Banked sprite RAM at E000-FFFF remains writable.
        sprite_wr = cpu_write && sprite_selected;
        sprite_wr_addr = sprite_rd_addr;
        sprite_wr_data = cpu_dout;

        sound_latch_wr = 1'b0;
        if (cpu_write) begin
            if ((profile_id == 3'd0 && cpu_addr == 16'hdb00) ||
                (profile_id == 3'd1 && cpu_addr == 16'hc000) ||
                (profile_id == 3'd4 && cpu_addr == 16'hc500) ||
                // MAME tests m_rombank_latch (the raw latch written at
                // $C280-$C2FF), not the applied bank -- suna8.cpp:1077-1084.
                // rom_bank_latch is only copied from rom_bank_latch_shadow
                // on a later $C400 write, so testing rom_bank_latch here
                // used a stale disable bit between those two writes.
                (profile_id == 3'd3 && cpu_addr == 16'hc500 && !rom_bank_latch_shadow[5]) ||
                (profile_id == 3'd2 && cpu_addr >= 16'hc500 && cpu_addr < 16'hc580 &&
                 !rom_bank_latch_shadow[5]) ||
                (profile_id == 3'd5 && cpu_addr == 16'hc0a0 &&
                 ((protection_val & 8'hfc) == 8'h90)))
                sound_latch_wr = 1'b1;
        end
        sound_latch_data = cpu_dout;
        if (profile_id == 3'd5 && brickzn_remap_sound)
            sound_latch_data = suna8_brickzn_sound_transform(cpu_dout);
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            rom_bank_latch <= 8'd0;
            sprite_bank_latch <= 8'd0;
            rom_bank_latch_shadow <= 8'd0;
            sprite_bank <= 3'd0;
            work_ram_bank <= 2'd0;
            palette_bank <= 1'b0;
            flip_screen <= 1'b0;
            nmi_enable <= 1'b0;
            palette_write_enable <= 1'b1;
            write_disable <= 1'b0;
            brickzn_work_write_disable <= 1'b0;
            brickzn_alt_data <= 1'b0;
            brickzn_opcode_toggle <= 1'b0;
            brickzn_remap_sound <= 1'b0;
            // Hard Head's protection latch is a zero-initialized member in
            // the original driver; Brick Zone explicitly resets its latch
            // high.  Keep the profile-specific power-on state instead of
            // applying the Brick Zone value to every board.
            protection_val <= (profile_id == 3'd0) ? 8'h00 : 8'hff;
            protection_2 <= 8'hff;
            protection_2_prev <= 8'hff;
            hardhead_input_select <= 8'd0;
            gfx_bank_latch <= 3'd0;
            brickzn_cheat_read_d <= 1'b0;
            cpu_write_d <= 1'b0;
            start_led_state <= 2'b00;
            coin_counter_state <= 2'b00;
            coin_lockout_state <= 2'b00;
        end else begin
            brickzn_cheat_read_d <= brickzn_cheat_read;
            if (brickzn_cheat_read && !brickzn_cheat_read_d)
                brickzn_cheat_bit2 <= ~brickzn_cheat_bit2;

            if (work_wr_en)
                work_ram[work_wr_addr] <= work_wr_data;

            cpu_write_d <= cpu_write;
            if (cpu_write_edge) begin
                case (profile_id)
                    3'd0: begin
                        if (cpu_addr == 16'hda00)
                            hardhead_input_select <= cpu_dout;
                        if (cpu_addr == 16'hda80)
                            rom_bank_latch <= cpu_dout;
                        if (cpu_addr == 16'hdb80) begin
                            flip_screen <= cpu_dout[2];
                            // hardhead_flipscreen_w: bits 4:3 are the two
                            // coin-lockout outputs.
                            coin_lockout_state <= cpu_dout[4:3];
                        end
                        if (cpu_addr >= 16'hdd80 && cpu_addr < 16'hde00)
                            protection_val <= cpu_dout[7] ? cpu_dout : cpu_addr[0];
                    end
                    3'd1: begin
                        if (cpu_addr == 16'hc002) begin
                            rom_bank_latch <= cpu_dout;
                            flip_screen <= cpu_dout[5];
                            // rranger's shared bank/flip handler drives both
                            // coin-lockout lines on bits 7:6.
                            coin_lockout_state <= cpu_dout[7:6];
                        end
                        // cpu_addr == 16'hc200 (sranger_prot_w's work_ram
                        // poke) is handled by the work_wr_en/addr/data mux
                        // above, not here -- see that declaration's comment.
                    end
                    3'd2: begin
                        if (cpu_addr >= 16'hc280 && cpu_addr < 16'hc300)
                            rom_bank_latch_shadow <= cpu_dout;
                        if (cpu_addr >= 16'hc200 && cpu_addr < 16'hc280)
                            sprite_bank <= suna8_sprite_bank(profile_id, sprite_bank_latch, cpu_dout);
                        if (cpu_addr >= 16'hc300 && cpu_addr < 16'hc380) begin
                            sprite_bank_latch <= cpu_dout;
                            flip_screen <= cpu_dout[0];
                        end
                        if (cpu_addr >= 16'hc380 && cpu_addr < 16'hc400) begin
                            // sparkman_write_disable_w: bit 0 disables RAM
                            // writes, bit 5 is NMI enable.
                            write_disable <= cpu_dout[0];
                            nmi_enable <= cpu_dout[5];
                        end
                        if (cpu_addr >= 16'hc400 && cpu_addr < 16'hc480) begin
                            rom_bank_latch <= rom_bank_latch_shadow;
                            start_led_state <= cpu_dout[1:0];
                        end
                        if (cpu_addr == 16'hc480)
                            coin_counter_state[0] <= cpu_dout[0];
                    end
                    3'd3: begin
                        if (cpu_addr >= 16'hc280 && cpu_addr < 16'hc300)
                            rom_bank_latch_shadow <= cpu_dout;
                        if (cpu_addr == 16'hc200)
                            sprite_bank <= sprite_bank_latch[2] ? 3'd1 : 3'd0;
                        // hardhea2_flipscreen_w is mapped at the single
                        // address 0xc300 only; starfigh_spritebank_latch_w
                        // is a separate register at 0xc380-0xc3ff. MAME does
                        // not gate starfigh work/sprite RAM writes from
                        // this byte.
                        if (cpu_addr == 16'hc300)
                            flip_screen <= cpu_dout[0];
                        if (cpu_addr >= 16'hc380 && cpu_addr < 16'hc400) begin
                            sprite_bank_latch <= cpu_dout;
                            nmi_enable <= cpu_dout[5];
                            // starfigh_spritebank_latch_w (suna8.cpp:1086-1094)
                            // implements only m_spritebank_latch and
                            // m_nmi_enable. Its "bit 1 = disable RAM writes"
                            // comment describes the board with no code
                            // behind it -- unlike sparkman_write_disable_w
                            // (profile 2, above), which is a real register.
                            // A starfigh_work_write_disable gate here was
                            // dropping $C800-$DFFF writes MAME never drops.
                        end
                        if (cpu_addr >= 16'hc400 && cpu_addr < 16'hc480) begin
                            rom_bank_latch <= rom_bank_latch_shadow;
                            start_led_state <= cpu_dout[1:0];
                            coin_counter_state[0] <= cpu_dout[2];
                            // starfigh_leds_w (suna8.cpp:1118): bit 3
                            // selects an alternate gfx bank ("bosses"),
                            // consumed by suna8_bus_pkg.sv's sprite decode
                            // when gfx_bank==3 (see gfx_bank_latch's use in
                            // suna8_sprite_decode.sv).
                            gfx_bank_latch <= cpu_dout[3] ? 3'd4 : 3'd0;
                        end
                    end
                    3'd4: begin
                        if (cpu_addr == 16'hc280 || cpu_addr == 16'hc28c)
                            rom_bank_latch <= cpu_dout;
                        if (cpu_addr == 16'hc200)
                            sprite_bank <= cpu_dout[1:1];
                        if (cpu_addr == 16'hc300)
                            flip_screen <= cpu_dout[0];
                        if (cpu_addr == 16'hc380)
                            nmi_enable <= cpu_dout[0];
                        if (cpu_addr == 16'hc400) begin
                            start_led_state <= cpu_dout[1:0];
                            coin_counter_state[0] <= cpu_dout[2];
                        end
                        if (cpu_addr == 16'hc507 || cpu_addr == 16'hc556 || cpu_addr == 16'hc560)
                            work_ram_bank <= 2'd1;
                        if (cpu_addr == 16'hc522 || cpu_addr == 16'hc528 || cpu_addr == 16'hc533)
                            work_ram_bank <= 2'd0;
                        if (cpu_addr == 16'hc50f)
                            sprite_bank <= 3'd1;
                        if (cpu_addr == 16'hc508)
                            sprite_bank <= 3'd0;
                    end
                    default: begin
                        if (cpu_addr == 16'hc040)
                            rom_bank_latch <= cpu_dout;
                        if (cpu_addr == 16'hc060) begin
                            // brickzn_sprbank_w (suna8.cpp:714): spritebank
                            // is a single bit, (data>>1)&1 -- not the raw
                            // 2-bit field cpu_dout[1:0].
                            sprite_bank <= {2'b00, cpu_dout[1]};
                            flip_screen <= cpu_dout[0];
                            protection_val <= cpu_dout;
                        end
                        if (cpu_addr == 16'hc0a0) begin
                            // brickzn_multi_w dispatches the write according
                            // to the protection select latched at C060.
                            if (((protection_val & 8'hfc) == 8'h88) ||
                                ((protection_val & 8'hfc) == 8'h8c))
                                palette_bank <= cpu_dout[0];
                            if ((protection_val & 8'h1f) == 8'h1c)
                                brickzn_opcode_toggle <= ~brickzn_opcode_toggle;
                            if ((protection_val & 8'hfc) == 8'h04) begin
                                start_led_state <= cpu_dout[1:0];
                                coin_counter_state[0] <= cpu_dout[2];
                            end
                        end
                        // The brickzn11 map exposes the same three bits at
                        // C080 instead of through the protection dispatcher.
                        if (cpu_addr == 16'hc080) begin
                            start_led_state <= cpu_dout[1:0];
                            coin_counter_state[0] <= cpu_dout[2];
                        end
                        if (cpu_addr == 16'hc0c0) begin
                            brickzn_work_write_disable <=
                                ((protection_2 ^ cpu_dout) == 8'h24);
                            brickzn_remap_sound <=
                                ((protection_2 ^ cpu_dout) == 8'hf8);
                            brickzn_alt_data <=
                                (protection_2 == (cpu_dout | 8'hdc));
                            protection_2_prev <= protection_2;
                            protection_2 <= cpu_dout;
                        end
                    end
                endcase
            end

            // Brick Zone's I/O map gates palette RAM writes with two
            // write-only ports.  These are independent of the C0A0 palette
            // bank selector and remain latched until the opposite command.
            if (profile_id == 3'd5 && cpu_io_write) begin
                if (cpu_addr[7:0] == 8'h00)
                    palette_write_enable <= 1'b0;
                else if (cpu_addr[7:0] == 8'ha1)
                    palette_write_enable <= 1'b1;
            end
        end
    end

endmodule
