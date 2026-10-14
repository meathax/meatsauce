// TUMBLE game interface. The first implementation slice brings up the
// 68000, Tumble Pop bootleg address map, work RAM and board-visible I/O.
module tumble_game(
    input      [ 7:0] config_id,
    input      [ 7:0] tile_xform,
    input      [ 7:0] sprite_xform,
    input      [ 7:0] main_xform,
    input      [23:0] tile_len_bytes,
    input      [23:0] sprite_len_bytes,
    input      [ 1:0] dwnld_mask,
    input             dwnld_en,
    output     [ 1:0] post_mask,
    output            hiscore_paused,
    `include "jtframe_game_ports.inc"
);

import tumble_profiles::*;
`include "chokchok_mcu_image.svh"

wire [2:0] map_id = profile_map(config_id);
wire [2:0] palette_mode = profile_palette(config_id);
wire [2:0] sound_id = profile_sound(config_id);
wire [2:0] mcu_id = profile_mcu(config_id);
wire [8:0] mame_vblank_start = profile_vbstart(config_id);
wire [8:0] mame_vblank_end = profile_vbend(config_id);
wire [1:0] tile_mode = profile_tile(config_id);
wire [3:0] scroll_mode = profile_scroll(config_id);
wire is_family_c = map_id == 3'd3;
wire is_family_d = map_id == 3'd4;
wire is_suprtrio = map_id == 3'd5;
wire is_funkyjet = map_id == 3'd6;
wire is_tumblepba = config_id == CFG_TUMBLEPBA;
// Most SemiCom profiles need the measured +2-pixel sprite bias. Metal Saver
// uses the base DECO sprite origin; removing the adjustment reduces its
// MAME title-screen mismatch. Chok-Chok retains the shared +2 setting.
wire [3:0] family_d_sprite_x_bias = is_family_d &&
                                    config_id != CFG_METLSAVR ? 4'd2 : 4'd0;
wire has_protdata = is_family_d && (mcu_id == 3'd2);
wire chokchok_mcu_hle = is_family_d && (mcu_id == 3'd3);
wire is_magipur = config_id == CFG_MAGIPUR;
// Both photographed PM-102 Tumble Pop boards have a 12.000 MHz oscillator
// beside the 68000. Its CLK routing is not measured; retain MAME's 14 MHz
// default and offer 12 MHz only for these two bootleg program profiles.
wire pm102_cpu_12 = status[28] &&
                    (config_id == CFG_TUMBLEB || config_id == CFG_TUMBLEB2);
wire [6:0] cpu_num = (map_id == 3'd4) ? 7'd5 :
                     (pm102_cpu_12 || map_id == 3'd2 || map_id == 3'd3) ? 7'd1 : 7'd7;
wire [7:0] cpu_den = (map_id == 3'd4) ? 8'd16 :
                     (pm102_cpu_12 || map_id == 3'd2 || map_id == 3'd3) ? 8'd4 : 8'd24;

wire [23:1] cpu_addr;
wire cpu_bus_grant;
wire hiscore_active = hiscore_pause && cpu_bus_grant;
assign hiscore_paused = hiscore_active;
wire [15:0] cpu_dout;
wire        cpu_rnw, UDSn, LDSn, ASn;
wire [2:0]  FC;
wire        bus_valid = !ASn && !(UDSn && LDSn) && !(&FC);
wire        program_rom = is_family_c ?
                          (is_magipur ? cpu_addr[23:20] == 4'hf : cpu_addr[23:20] == 4'h0) :
                          ((map_id == 3'd4) ? cpu_addr[23:20] == 4'h0 : cpu_addr[23:19] == 5'd0);
wire        rom_select = bus_valid && cpu_rnw && program_rom;
reg  [63:0] magipur_vector_hi_written, magipur_vector_lo_written;
// MAME copies the first 0x80 ROM bytes into Magipur RAM at reset. Leave each
// vector byte ROM-backed until the CPU writes it, preserving the copied value
// in the other lane after a byte write.
wire        magipur_vector_rom = bus_valid && cpu_rnw && is_magipur &&
                                 cpu_addr[23:7] == 17'd0 &&
                                 ((!UDSn && !magipur_vector_hi_written[cpu_addr[6:1]]) ||
                                  (!LDSn && !magipur_vector_lo_written[cpu_addr[6:1]]));
wire        main_rom_select = rom_select || magipur_vector_rom;
reg         protdata_loading;
reg  [7:0]  protdata_index;
reg         funky_pic_loading;
reg  [10:0] funky_pic_load_index;
reg  [11:0] funky_pic_rom [0:2047];
// The ROM slot's ready flag is registered: for one cycle after the address
// changes it still reads ready with the previous word. The preloads step the
// address on every write, so each write must wait for ready to settle.
reg  [1:0]  preload_gap = 2'd2;
wire        preload_ready = main_ok && preload_gap == 2'd0;
wire        funky_pic_preload_write = funky_pic_loading && preload_ready;
wire        bus_busy = main_rom_select && !(rom_ok_dly && main_ok) ||
                       (pic_cmd_strobe && pic_cmd_pending && !pic_cmd_strobe_d);
reg         rom_ok_dly;

reg         irq_pending;
reg  [8:0]  vdump;
reg  [8:0]  vrender, vrender1, hcount;
wire        Hinit, Vinit;
wire        video_lhbl, video_lvbl, video_hs, video_vs;
wire [11:0]  pf1_render_addr, pf2_render_addr;
wire [10:0]  pf1_rowscroll_addr;
wire [15:0]  pf1_rowscroll_data;
wire [15:0]  pf1_render_data, pf1_render_data2;
wire [15:0]  pf2_render_data, pf2_render_data2;
wire [ 8:0]  pf1_pixel, pf2_pixel;
wire [12:0]  object_pixel;
wire [10:0]  object_scan_addr, object_dma_addr;
wire [ 1:0]  object_dma_we;
reg          video_lvbl_d;
reg          mame_vblank_d;
reg  [8:0]  vdump_l;
wire        mame_vblank = (vdump >= mame_vblank_start) ||
                          ((mame_vblank_end != 0) && (vdump < mame_vblank_end));
wire        irq_vblank = (vdump == mame_vblank_start) && (vdump_l != mame_vblank_start);

// Family A and the SemiCom maps share the 16 KiB work RAM window. Family C
// (Fancy World) has 64 KiB RAM at FF0000; Magipur moves that RAM to address 0.
wire is_work = is_family_c ?
               (is_magipur ? cpu_addr[23:16] == 8'h00 : cpu_addr[23:16] == 8'hff) :
               is_suprtrio ? cpu_addr[23:15] == 9'h1e0 :
               is_funkyjet ? cpu_addr[23:14] == 10'h050 :
               cpu_addr[23:14] == 10'h048;
wire [14:0] work_mem_index = (is_family_c || is_suprtrio) ? cpu_addr[15:1] :
                             {2'b0,cpu_addr[13:1]};
wire is_palette = is_family_c ? cpu_addr[23:12] == 12'h140 :
                  is_suprtrio ? (cpu_addr[23:11] == 13'h19e0 && cpu_addr[10:1] <= 10'h2ff) :
                  is_funkyjet ? cpu_addr[23:11] == 13'h240 :
                                cpu_addr[23:11] == 13'h280;
wire [10:0] palette_mem_index = is_family_c ? cpu_addr[11:1] : {1'b0,cpu_addr[10:1]};
wire is_sprite = is_tumblepba ? (cpu_addr[23:11] == 13'h340) :
                 is_family_d ? (cpu_addr[23:12] == 12'h160) :
                 is_suprtrio ? (cpu_addr[23:12] == 12'h700) :
                               (cpu_addr[23:11] == 13'h2c0);
wire is_tumblepba_extra = is_tumblepba &&
                          (cpu_addr[23:12] == 12'h1a1 || cpu_addr[23:12] == 12'h200);
wire [11:0] tumblepba_extra_index = {cpu_addr[23:12] == 12'h200,cpu_addr[11:1]};
// The bootleg program keeps coin/input bookkeeping in plain RAM at
// 0x242000-0x2427ff (it copies the DIP word into 0x242102 and compares
// previous input states stored there), not in MAME's invented SYSTEM port.
wire is_funkyjet_extra = is_funkyjet &&
                         (cpu_addr[23:11] == 13'h400 ||
                          cpu_addr[23:12] == 12'h340 && cpu_addr[11:1] <= 11'h5ff ||
                          cpu_addr[23:11] == 13'h484);
wire [11:0] funkyjet_extra_index = cpu_addr[23:12] == 12'h340 ?
                                   12'h400 + cpu_addr[11:1] :
                                   cpu_addr[23:12] == 12'h242 ?
                                   12'hc00 + {2'b0,cpu_addr[10:1]} : {2'b0,cpu_addr[10:1]};
wire is_board_extra = is_tumblepba_extra || is_funkyjet_extra;
wire [11:0] board_extra_index = is_funkyjet ? funkyjet_extra_index : tumblepba_extra_index;
wire is_input = !is_suprtrio && !is_funkyjet && cpu_addr[23:4] == 20'h18000; // common Tumble input window
wire is_tumblepba_bank = is_tumblepba && is_input && cpu_addr[3:1] == 3'd2;
wire is_tumblepba_oki = is_tumblepba && is_input && cpu_addr[3:1] == 3'd3;
wire is_aux = is_family_d ? (cpu_addr[23:12] == 12'h1a0) :
              (is_tumblepba || is_funkyjet) ? 1'b0 :
                             (cpu_addr[23:11] == 13'h340);
// htchctch-family boards decode 8 KiB of extra RAM at 0x341000-0x342fff.
wire is_family_d_extra_ram = is_family_d &&
                             (cpu_addr[23:12] == 12'h341 || cpu_addr[23:12] == 12'h342);
wire is_pf_ctrl = !is_tumblepba &&
                  (is_suprtrio ? cpu_addr[23:4] == 20'ha0000 :
                                 cpu_addr[23:4] == 20'h30000); // board control window
wire is_pf_pair = tile_mode != 2'd0;
wire is_pangpang = tile_mode == 2'd2;
wire is_pf1 = is_suprtrio ? (cpu_addr[23:12] == 12'ha20) :
              (is_pf_pair || is_family_d) ? (cpu_addr[23:13] == 11'h190) :
                                             (cpu_addr[23:12] == 12'h320); // pair: 0x320000-0x321fff
wire is_pf2 = is_suprtrio ? (cpu_addr[23:12] == 12'ha22) :
              is_pangpang ? (cpu_addr[23:13] == 11'h1a0) :
              is_pf_pair ? (cpu_addr[23:13] == 11'h191) :
                           (cpu_addr[23:12] == 12'h322); // Pangpang PF2: 0x340000-0x341fff
wire [11:0] pf1_mem_index = (is_pf_pair || is_family_d) ? cpu_addr[12:1] : {1'b0,cpu_addr[11:1]};
wire [11:0] pf2_mem_index = is_pf_pair ? cpu_addr[12:1] : {1'b0,cpu_addr[11:1]};
wire is_protection = cpu_addr[23:1] == 23'h080000;
wire is_family_c_ym = is_family_c && cpu_addr[23:2] == 22'h040000;
wire is_family_c_oki = is_family_c && cpu_addr[23:1] == 23'h080002;
wire is_family_d_soundcmd = is_family_d && cpu_addr[23:1] == 23'h080000;
wire is_suprtrio_soundcmd = is_suprtrio && cpu_addr[23:1] == 23'h760000;
wire is_tilebank = is_family_d && cpu_addr[23:1] == 23'h080001;
wire is_suprtrio_players = is_suprtrio && cpu_addr[23:1] == 23'h700000;
wire is_suprtrio_system = is_suprtrio && cpu_addr[23:1] == 23'h720000;
wire is_suprtrio_dsw = is_suprtrio && cpu_addr[23:1] == 23'h740001;
wire is_suprtrio_tilebank = is_suprtrio_players;
wire is_suprtrio_protlatch = is_suprtrio && cpu_addr[23:1] == 23'h770000;
wire is_funkyjet_dsw = is_funkyjet && cpu_addr[23:1] == 23'h0e81c1;
// The program reads 0x242100 into both player-state structures. Its adjacent
// SYSTEM read is documented by MAME; this player decode is ROM-derived.
// The program's input reads (tests in the coin routine at 0x100 and the
// vblank wait at 0xc0e4): 0x1d000c = joysticks/buttons/start (active low,
// P1 low byte, P2 high byte), 0x1d0778 = SYSTEM (coin1, coin2, service,
// vblank on bit 3). The current 0x1d010a PIC-latch route is provisional;
// the dumped PALs lack pin assignments proving its board decode.
wire is_funkyjet_players = is_funkyjet && cpu_addr[23:1] == 23'h0e8006;
wire is_funkyjet_system = is_funkyjet && cpu_addr[23:1] == 23'h0e83bc;
wire is_funkyjet_soundcmd = is_funkyjet && cpu_addr[23:1] == 23'h0e8085;
wire write_cycle = bus_valid && !cpu_rnw && !hiscore_active;
wire protdata_write = protdata_loading && (!has_protdata || preload_ready);
wire [1:0] byte_write = {~UDSn,~LDSn};
wire direct_oki = sound_id == 3'd0;
wire has_oki = direct_oki || sound_id == 3'd1 || sound_id == 3'd2 || sound_id == 3'd3 ||
               sound_id == 3'd5 || is_family_d || is_funkyjet;
reg [3:0] funky_pic_oki_bank;
reg [7:0] funky_pic_data, funky_pic_oki_din;
reg funky_pic_pending, funky_pic_oki_wr;
reg funky_cmd_strobe_d;
wire funky_cmd_strobe = write_cycle && is_funkyjet_soundcmd && !LDSn;
wire semicom_oki_wr_n;
wire [7:0] semicom_oki_din;
reg pic_oki_active, pic_oki_phase;
reg [7:0] pic_oki_wait;
reg pic_cmd_strobe_d, pic_cmd_pending, jump_cmd_strobe_d;
reg [7:0] pic_cmd_data;
reg [3:0] pic_next_music_bank;
wire pic_cmd_strobe = sound_id == 3'd1 && is_protection && write_cycle;
wire jump_cmd_strobe = sound_id == 3'd2 && is_protection && write_cycle && !LDSn;
reg [1:0] pic_oki_index, pic_oki_length;
reg [7:0] pic_oki_queue [0:2];
reg [7:0] pic_music_state, pic_music_sample;
reg [3:0] pic_music_bank;
wire pic_hle_write = sound_id == 3'd1 && pic_oki_active && !pic_oki_phase;
wire oki_write = (direct_oki && is_protection || sound_id == 3'd3 && is_family_c_oki && !LDSn ||
                  is_tumblepba_oki && !LDSn) && write_cycle ||
                 is_family_d && !semicom_oki_wr_n ||
                 sound_id == 3'd2 && !jumpkids_oki_wr_n ||
                 sound_id == 3'd5 && !trio_oki_wr_n || pic_hle_write || funky_pic_oki_wr;
// Tumbleb's direct handler takes the low byte for word writes and the high
// byte for an upper-only write. Unico and Playmark map only the low lane.
wire [7:0] oki_cpu_din = direct_oki && !UDSn && LDSn ? cpu_dout[15:8] : cpu_dout[7:0];
wire [7:0] oki_din = is_family_d ? semicom_oki_din :
                     sound_id == 3'd2 ? jumpkids_oki_din :
                     sound_id == 3'd5 ? trio_oki_din :
                     is_funkyjet ? funky_pic_oki_din :
                     pic_oki_active && sound_id == 3'd1 ? pic_oki_queue[pic_oki_index] : oki_cpu_din;
wire [7:0] oki_dout;
wire [17:0] oki_rom_addr;
reg [1:0] tumblepba_oki_bank;
wire [21:0] semicom_oki_addr;
wire signed [13:0] oki_audio;
wire [1:0] oki_cen_bus;
reg [7:0] sound_latch;
reg jumpkids_irq;
wire jumpkids_irq_ack;
wire [15:0] semicom_snd_addr, jumpkids_snd_addr, trio_snd_addr;
wire semicom_snd_cs, jumpkids_snd_cs, trio_snd_cs;
wire [7:0] jumpkids_oki_din, jumpkids_oki_bank, trio_oki_din, trio_sample_bank;
wire jumpkids_oki_wr_n, trio_oki_wr_n;
wire [18:0] jumpkids_oki2_addr;
wire jumpkids_oki2_read = sound_id == 3'd2 && oki_rom_addr >= 18'h20000;
wire [7:0] oki_rom_data = jumpkids_oki2_read ? oki2_data : oki1_data;
wire oki_rom_ok = jumpkids_oki2_read ? oki2_ok : oki1_ok;
wire [7:0] semicom_ym_din;
wire [7:0] semicom_sample_bank;
wire [7:0] board_sample_bank = is_family_d ? semicom_sample_bank : trio_sample_bank;
wire [7:0] semicom_ym_dout;
wire semicom_ym_irq_n, semicom_ym_cs_n, semicom_ym_rd_n, semicom_ym_wr_n, semicom_ym_a0;
// Unico maps both YM ports on the 68000's low byte lane only.
wire family_c_ym_cycle = is_family_c && is_family_c_ym && bus_valid && !LDSn;
wire opm_cs_n = is_family_d ? semicom_ym_cs_n : !family_c_ym_cycle;
wire opm_rd_n = is_family_d ? semicom_ym_rd_n : !cpu_rnw;
wire opm_wr_n = is_family_d ? semicom_ym_wr_n : !write_cycle;
wire opm_a0 = is_family_d ? semicom_ym_a0 : cpu_addr[1];
wire [7:0] opm_din = is_family_d ? semicom_ym_din :
                     cpu_dout[7:0];
wire [21:0] semicom_oki_addr_raw =
    oki_rom_addr < 18'h30000 ? {4'd0,oki_rom_addr} :
    22'h040000 + {2'd0,board_sample_bank[3:0],16'd0} + ({4'd0,oki_rom_addr} - 22'h030000);
wire [21:0] pic_oki_addr = oki_rom_addr < 18'h38000 ? {4'd0,oki_rom_addr} :
    22'h0b8000 + {3'd0,pic_music_bank,15'd0} + {4'd0,(oki_rom_addr - 18'h38000)};
// MAME selects one of four complete 0x40000 OKI pages. The supplied 0x80000
// sample image is reloaded into the upper half of its 0x100000 region.
wire [21:0] tumblepba_oki_addr = {2'd0,tumblepba_oki_bank,oki_rom_addr};
wire [21:0] funky_pic_oki_addr = oki_rom_addr < 18'h38000 ?
    {4'd0,oki_rom_addr} : {3'd0,funky_pic_oki_bank,15'd0} +
                         {4'd0,(oki_rom_addr - 18'h38000)};
wire [11:0] funky_pic_pc;
// Registered program read. The PIC advances once per 48 clk cycles, so the
// next instruction settles long before its following clock enable.
reg  [11:0] funky_pic_ir;
wire [7:0] funky_pic_portb, funky_pic_portc, funky_pic_do;
wire funky_pic_pa_we, funky_pic_pb_we, funky_pic_pc_we;
reg [5:0] funky_pic_div;
wire funky_pic_cen = funky_pic_div == 6'd47;
wire [1:0] semicom_opm_cen;
wire signed [15:0] semicom_opm_l, semicom_opm_r;

// Board RAMs are block RAMs with registered reads and byte-lane writes. The
// 68000 samples its data bus several clk cycles after the address settles and
// the renderers already expected a registered playfield read, so the extra
// read cycle is hidden. Asynchronous array reads here previously prevented
// M10K inference and expanded these RAMs into registers during synthesis.
wire [15:0] work_q, palette_q, palette_pixel_q, aux_q, board_extra_q, family_d_extra_q;
wire [15:0] pf1_even_q, pf1_odd_q, pf2_even_q, pf2_odd_q;
wire [15:0] pf1_even_render_q, pf1_odd_render_q, pf2_even_render_q, pf2_odd_render_q;
reg [2047:0] palette_written;
reg [15:0] pf_ctrl     [0:7];
integer pf_ctrl_reset_index;
reg [15:0] tilebank_reg;
reg [3:0] suprtrio_prot_latch;
// MAME tests control_0[6] with 0x0080, i.e. bit 7 of the 16-bit word.
// MAME's screen_update_suprtrio draws only the 16x16 layers and sprites; it
// never enables the 8x8 character layer and ignores the flip control bit.
wire        pf1_chars = pf_ctrl[6][7] & ~is_suprtrio;
wire        pf_flip   = pf_ctrl[0][7] & ~is_suprtrio;
wire [10:0] aux_mem_index = is_family_d ? cpu_addr[11:1] : {1'b0,cpu_addr[10:1]};
wire [11:0] family_d_extra_ram_index = cpu_addr[13:1] - 13'h0800;

// MiSTer hiscore.v supplies MAME's byte address. Read and restore through the
// same backing RAMs used by the matching board map.
wire [23:1] hs_cpu_addr = hiscore_addr[23:1];
wire hs_is_work = is_family_c ?
                  (is_magipur ? hs_cpu_addr[23:16] == 8'h00 : hs_cpu_addr[23:16] == 8'hff) :
                  is_suprtrio ? hs_cpu_addr[23:15] == 9'h1e0 :
                  is_funkyjet ? hs_cpu_addr[23:14] == 10'h050 :
                  hs_cpu_addr[23:14] == 10'h048;
wire [14:0] hs_work_index = (is_family_c || is_suprtrio) ? hs_cpu_addr[15:1] :
                            {2'b0,hs_cpu_addr[13:1]};
wire hs_is_family_d_extra_ram = is_family_d &&
                                (hs_cpu_addr[23:12] == 12'h341 || hs_cpu_addr[23:12] == 12'h342);
wire [11:0] hs_extra_index = hs_cpu_addr[13:1] - 13'h0800;
// MAME init_chokchok() installs the same data<<1 tile-bank handler for both
// Metal Saver and Chok-Chok.
wire [15:0] tilebank = is_suprtrio ? {tilebank_reg[1:0],14'd0} :
                      (config_id == CFG_METLSAVR || config_id == CFG_CHOKCHOK) ?
                      {tilebank_reg[14:0],1'b0} : tilebank_reg;
wire [10:0]  palette_index;
wire [15:0]  family_c_default_palette = {
    4'h0,
    palette_index_q[0] ? 4'hf : 4'h0,
    palette_index_q[1] ? 4'hf : 4'h0,
    palette_index_q[2] ? 4'hf : 4'h0
};
// The palette display port is registered; align the Family C default-colour
// fallback and its written flag with the same read cycle.
reg  [10:0]  palette_index_q;
reg          palette_written_q;
always @(posedge clk) begin
    palette_index_q <= palette_index;
    palette_written_q <= palette_written[palette_index];
end
wire [15:0]  palette_pixel = family_c_transparent && !palette_written_q
    ? family_c_default_palette : palette_pixel_q;

// Playfield RAM is split into even/odd word banks so the paired-tile formats
// can read both words of one tile in a single registered display read.
reg pf1_render_odd, pf2_render_odd;
always @(posedge clk) begin
    pf1_render_odd <= pf1_render_addr[0];
    pf2_render_odd <= pf2_render_addr[0];
end
wire [10:0] pf1_render_bank_addr = is_pf_pair ? pf1_render_addr[10:0] : pf1_render_addr[11:1];
wire [10:0] pf2_render_bank_addr = is_pf_pair ? pf2_render_addr[10:0] : pf2_render_addr[11:1];
assign pf1_render_data  = (!is_pf_pair && pf1_render_odd) ? pf1_odd_render_q : pf1_even_render_q;
assign pf1_render_data2 = is_pf_pair ? pf1_odd_render_q : 16'd0;
assign pf2_render_data  = (!is_pf_pair && pf2_render_odd) ? pf2_odd_render_q : pf2_even_render_q;
assign pf2_render_data2 = is_pf_pair ? pf2_odd_render_q : 16'd0;

function automatic [15:0] write_lanes(
    input [15:0] old_data,
    input [15:0] new_data,
    input [1:0]  lanes
);
begin
    write_lanes = old_data;
    if (lanes[1]) write_lanes[15:8] = new_data[15:8];
    if (lanes[0]) write_lanes[7:0]  = new_data[7:0];
end
endfunction

// MAME's tumbleb2 PIC HLE lookup. 0 means no operation and 0xfe denotes a
// music/bank command; the remaining values are OKI sample numbers.
function automatic [7:0] pic_sound_lookup(input [7:0] command);
begin
    pic_sound_lookup = 8'h00;
    case (command)
        8'h01, 8'h04, 8'h05, 8'h06, 8'h07, 8'h08, 8'h09,
        8'h0a, 8'h0b, 8'h0c, 8'h0d, 8'h0f, 8'h10, 8'h12:
            pic_sound_lookup = 8'hfe;
        default: begin
            if (command >= 8'h29 && command <= 8'h30)
                pic_sound_lookup = command - 8'h17;
            else if (command >= 8'h32 && command <= 8'h4a)
                pic_sound_lookup = command - 8'h18;
        end
    endcase
end
endfunction

function automatic [3:0] pic_music_bank_for(input [7:0] command);
begin
    case (command)
        8'h04: pic_music_bank_for = 4'd1;
        8'h05: pic_music_bank_for = 4'd6;
        8'h06, 8'h0a: pic_music_bank_for = 4'd2;
        8'h07, 8'h09: pic_music_bank_for = 4'd4;
        8'h08: pic_music_bank_for = 4'd3;
        8'h0b: pic_music_bank_for = 4'd5;
        8'h0c: pic_music_bank_for = 4'd6;
        8'h0d: pic_music_bank_for = 4'd7;
        8'h0f, 8'h12: pic_music_bank_for = 4'd0;
        8'h10: pic_music_bank_for = 4'd8;
        default: pic_music_bank_for = 4'd8;
    endcase
end
endfunction

function automatic [7:0] pic_music_sample_for(input [7:0] command);
begin
    case (command)
        8'h0f: pic_music_sample_for = 8'h33;
        8'h12: pic_music_sample_for = 8'h34;
        default: pic_music_sample_for = 8'h38;
    endcase
end
endfunction
wire [7:0] pic_bus_command = (!UDSn && LDSn) ? cpu_dout[15:8] : cpu_dout[7:0];
wire [7:0] pic_cpu_command = pic_cmd_data;
wire [7:0] pic_sound_command = pic_sound_lookup(pic_cpu_command);

// JTFRAME supplies active-low controls in MAME order. Bit 6 is Button 3 on
// Fancy World/Magipur, S.D. Fighters, B.C. Story, Metal Saver and Super Trio.
// Funky Jet's bootleg input definition uses the two-button Tumble Pop port;
// keep Button 3 inactive until the bootleg board wiring is established.
wire player_has_button3 = is_family_c || is_suprtrio ||
    (is_family_d && (config_id == CFG_SDFIGHT || config_id == CFG_BCSTRY ||
                     config_id == CFG_BCSTRYA || config_id == CFG_METLSAVR));
wire [7:0] player1 = {cab_1p[0],player_has_button3 ? joystick1[6] : 1'b1,joystick1[5:0]};
wire [7:0] player2 = {cab_1p[1],player_has_button3 ? joystick2[6] : 1'b1,joystick2[5:0]};
wire [15:0] players = {player2,player1};
// MAME's 8-bit SYSTEM port occupies the low byte; vblank is active-high on
// bit 3, which the bootleg polls at 0x180009.
// Bit 2 is SERVICE1 on the Tumble Pop bootleg and Unico boards only; the
// SemiCom boards leave it unconnected.
wire        service_n = is_family_d ? 1'b1 : service;
wire [15:0] system_port = {8'h00,4'hf,mame_vblank,service_n,coin[1],coin[0]};
wire [15:0] dip_port = dipsw[15:0];

// MAME installs bcstory_1a0_read for both B.C. Story sets and SD Fighters.
// It returns 0x01a0 only at PC=0x560, B.C. Story's interrupt-handler poll.
// SD Fighters instead polls the ordinary vblank bit with a byte read.
// FX68K has prefetched that following opcode when it reads the operand of
// MOVE.W $180008.L at 0x55a. Keep normal SYSTEM inputs at every other site.
wire bcstory_poll_hack = is_family_d && (config_id == CFG_SDFIGHT ||
                         config_id == CFG_BCSTRY || config_id == CFG_BCSTRYA);
reg [23:1] last_pfetch;
always @(posedge clk) begin
    if (rst) last_pfetch <= 23'd0;
    else if (!ASn && cpu_rnw && FC[1:0] == 2'b10) last_pfetch <= cpu_addr;
end
wire bcstory_1a0_read = bcstory_poll_hack && !UDSn && !LDSn &&
                        last_pfetch == 23'h0002b0;

reg [15:0] read_mux;
always @* begin
    if (hiscore_active) begin
        if (hs_is_work) read_mux = work_q;
        else if (hs_is_family_d_extra_ram) read_mux = family_d_extra_q;
        else read_mux = 16'hffff;
    end else if (magipur_vector_rom) begin
        read_mux = {magipur_vector_hi_written[cpu_addr[6:1]] ? work_q[15:8] : main_data[15:8],
                    magipur_vector_lo_written[cpu_addr[6:1]] ? work_q[7:0] : main_data[7:0]};
    end else if (program_rom) begin
        read_mux = main_data;
    end else if (is_work) begin
        read_mux = work_q;
    end else if (is_palette) begin
        read_mux = palette_q;
    end else if (is_sprite) begin
        read_mux = obj_dout;
    end else if (is_board_extra) begin
        read_mux = board_extra_q;
    end else if (is_family_c_oki) begin
        read_mux = {8'hff,oki_dout};
    end else if (is_family_c_ym) begin
        read_mux = {8'hff,semicom_ym_dout};
    end else if (is_suprtrio_players) begin
        read_mux = players;
    end else if (is_suprtrio_system) begin
        read_mux = {8'hff,suprtrio_prot_latch,3'b111,coin[0]};
    end else if (is_suprtrio_dsw) begin
        read_mux = dip_port;
    end else if (is_funkyjet_dsw) begin
        read_mux = dip_port;
    end else if (is_funkyjet_players) begin
        read_mux = players;
    end else if (is_funkyjet_system) begin
        read_mux = system_port;
    end else if (is_input) begin
        case (cpu_addr[3:1])
            3'd0: read_mux = players;
            3'd1: read_mux = dip_port;
            3'd4: read_mux = bcstory_1a0_read ? 16'h01a0 : system_port;
            default: read_mux = 16'h0000;
        endcase
    end else if (is_family_d_extra_ram) begin
        read_mux = family_d_extra_q;
    end else if (is_aux) begin
        read_mux = aux_q;
    end else if (is_pf_ctrl) begin
        read_mux = pf_ctrl[cpu_addr[3:1]];
    end else if (is_pf1) begin
        read_mux = pf1_mem_index[0] ? pf1_odd_q : pf1_even_q;
    end else if (is_pf2) begin
        read_mux = pf2_mem_index[0] ? pf2_odd_q : pf2_even_q;
    end else if (is_protection) begin
        read_mux = 16'hffff;
    end else begin
        read_mux = 16'hffff;
    end
end
assign hiscore_dout = hiscore_addr[0] ? read_mux[7:0] : read_mux[15:8];

jtframe_vtimer #(
    // The renderer blanks the non-visible rows 248..273 and 0..7. MAME's
    // CPU-visible vblank window and IRQ are timed separately per profile.
    .VB_START ( 9'd248 ), .VB_END   ( 9'd7 ),
    .VS_START ( 9'd250 ), .VS_END   ( 9'd253 ),
    .VCNT_END ( 9'd273 ),
    .HB_END   ( 9'd441 ), .HB_START ( 9'd320 ),
    .HS_START ( 9'd341 ), .HS_END   ( 9'd368 ),
    .H_VB     ( 9'd320 ), .H_VS     ( 9'd341 ),
    .H_VNEXT  ( 9'd341 ), .HINIT    ( 9'd341 ),
    .HCNT_END ( 9'd441 )
) u_vtimer(
    .clk      ( clk       ),
    .pxl_cen  ( pxl_cen   ),
    .vdump    ( vdump     ),
    .vrender  ( vrender   ),
    .vrender1 ( vrender1  ),
    .H        ( hcount    ),
    .Hinit    ( Hinit     ),
    .Vinit    ( Vinit     ),
    .LHBL     ( video_lhbl ),
    .LVBL     ( video_lvbl ),
    .HS       ( video_hs   ),
    .VS       ( video_vs   )
);

wire object_copy = pxl_cen && mame_vblank_d && !mame_vblank;

// Funky Jet's tiles use the opposite plane-pair order after the shared
// Tumble download rearrangement. Restore the pen bits for both playfields;
// its sprite planes already have the ordinary order.
wire [31:0] pf1_gfx_data = is_funkyjet ? {scr2_data[15:0],scr2_data[31:16]} : scr2_data;
wire [31:0] pf2_gfx_data = is_funkyjet ? {scr3_data[15:0],scr3_data[31:16]} : scr3_data;

tumble_video_tiles u_video_tiles(
    .rst          ( rst              ),
    .clk          ( clk              ),
    .pxl_cen      ( pxl_cen          ),
    .hs           ( video_hs         ),
    .hdump        ( hcount           ),
    .vdump        ( vdump            ),
    .flip         ( pf_flip          ),
    .pf1_chars    ( pf1_chars        ),
    .tile_mode    ( tile_mode        ),
    .scroll_mode  ( scroll_mode      ),
    .tilebank     ( tilebank         ),
    .pf1_scrollx  ( pf_ctrl[1]       ),
    .pf1_scrolly  ( pf_ctrl[2]       ),
    .pf2_scrollx  ( pf_ctrl[3]       ),
    .pf2_scrolly  ( pf_ctrl[4]       ),
    .pf1_rowscroll( is_funkyjet && pf_ctrl[6][6] ),
    .pf1_rsram_addr( pf1_rowscroll_addr ),
    .pf1_rsram_data( pf1_rowscroll_data ),
    .pf1_ram_addr ( pf1_render_addr  ),
    .pf1_ram_data ( pf1_render_data  ),
    .pf1_ram_data2( pf1_render_data2 ),
    .pf2_ram_addr ( pf2_render_addr  ),
    .pf2_ram_data ( pf2_render_data  ),
    .pf2_ram_data2( pf2_render_data2),
    .pf1_rom_cs   ( scr2_cs          ),
    .pf1_rom_addr ( scr2_addr        ),
    .pf1_rom_data ( pf1_gfx_data     ),
    .pf1_rom_ok   ( scr2_ok          ),
    .pf2_rom_cs   ( scr3_cs          ),
    .pf2_rom_addr ( scr3_addr        ),
    .pf2_rom_data ( pf2_gfx_data     ),
    .pf2_rom_ok   ( scr3_ok          ),
    .pf1_pixel    ( pf1_pixel        ),
    .pf2_pixel    ( pf2_pixel        )
);

// Family A uses 0x100/0x200 tile palette bases and transparent pen 0.
// Family C uses 0x400 for PF2 and PF1's 8x8 character map, but 0x200 for
// PF1's 16x16 tile map (matching the three MAME gfxdecode entries).
wire family_c_transparent = palette_mode == 3'd1;
wire pf1_opaque = family_c_transparent ? pf1_pixel[3:0] != 4'hf : pf1_pixel[3:0] != 4'h0;
wire object_opaque = object_pixel[12] &&
                     (family_c_transparent ? object_pixel[3:0] != 4'hf : object_pixel[3:0] != 4'h0);
wire [10:0] pf1_palette_index = family_c_transparent ?
                                (pf1_chars ? 11'd1024 : 11'd512) + {2'd0,pf1_pixel} :
                                11'd256 + {3'd0,pf1_pixel[7:0]};
wire [10:0] pf2_palette_index = family_c_transparent ?
                                11'd1024 + {2'd0,pf2_pixel} :
                                11'd512 + {3'd0,pf2_pixel[7:0]};
wire [10:0] object_palette_index = family_c_transparent ?
                                   {2'd0,object_pixel[8:0]} : {3'd0,object_pixel[7:0]};
assign palette_index = pf1_opaque
    ? (object_opaque ? object_palette_index : pf1_palette_index)
    : (object_opaque ? object_palette_index : pf2_palette_index);

// All TUMBLE profiles use MAME's DECO-Sprite bootleg mode: multi-tile sprites
// preserve the programmed base code instead of aligning it to their height.
jtcninja_obj #(.NSPRITES(512), .XBIAS(304), .HFLIP_END(319), .ALIGN_MULTITILE_CODES(0)) u_objects(
    .rst        ( rst              ),
    .clk        ( clk              ),
    .pxl_cen    ( pxl_cen          ),
    .flip       ( pf_flip          ),
    .dseal      ( 1'b0             ),
    .cbust      ( 1'b0             ),
    .x_bias_adj ( family_d_sprite_x_bias ),
    .transparent_pen ( family_c_transparent ? 4'hf : 4'h0 ),
    .spr512     ( is_family_d || is_suprtrio ),
    .HS         ( video_hs         ),
    .LHBL       ( video_lhbl       ),
    .LVBL       ( video_lvbl       ),
    .vrender    ( vrender          ),
    .hdump      ( hcount           ),
    .obj_copy   ( object_copy      ),
    .oram_addr  ( object_scan_addr ),
    .oram_dout  ( oram_dout        ),
    .dma_addr   ( object_dma_addr  ),
    .dma_we     ( object_dma_we    ),
    .rom_cs     ( objrom_cs        ),
    .rom_addr   ( objrom_addr      ),
    .rom_data   ( objrom_data      ),
    .rom_ok     ( objrom_ok        ),
    .pxl        ( object_pixel     )
);

always @(posedge clk or posedge rst) begin
    if (rst) begin
        rom_ok_dly <= 1'b0;
        vdump_l <= 9'd0;
        video_lvbl_d <= 1'b0;
        mame_vblank_d <= 1'b0;
        irq_pending <= 1'b0;
    end else begin
        rom_ok_dly <= main_ok;
        vdump_l <= vdump;
        if (pxl_cen) video_lvbl_d <= video_lvbl;
        if (pxl_cen) mame_vblank_d <= mame_vblank;
        if (irq_vblank) irq_pending <= 1'b1;
        if (!ASn && (&FC)) irq_pending <= 1'b0;
    end
end

wire wram_hs_write  = hiscore_active && hiscore_we && hs_is_work;
wire wram_cpu_write = write_cycle && is_work;

always @(posedge clk) begin
    if (rst) begin
        palette_written <= {2048{1'b0}};
        magipur_vector_hi_written <= 64'd0;
        magipur_vector_lo_written <= 64'd0;
        // Tumblepba has no mapped control writes. Give its scroll/flip inputs
        // the same deterministic power-on zero state as MAME's control RAM.
        for (pf_ctrl_reset_index = 0; pf_ctrl_reset_index < 8; pf_ctrl_reset_index = pf_ctrl_reset_index + 1)
            pf_ctrl[pf_ctrl_reset_index] <= 16'd0;
        tilebank_reg <= 16'd0;
        suprtrio_prot_latch <= 4'd0;
        sound_latch <= 8'd0;
        jumpkids_irq <= 1'b0;
        tumblepba_oki_bank <= 2'd0;
        pic_oki_active <= 1'b0;
        pic_oki_phase <= 1'b0;
        pic_oki_wait <= 8'd0;
        pic_cmd_strobe_d <= 1'b0;
        jump_cmd_strobe_d <= 1'b0;
        pic_cmd_pending <= 1'b0;
        pic_cmd_data <= 8'd0;
        pic_next_music_bank <= 4'd0;
        pic_oki_index <= 2'd0;
        pic_oki_length <= 2'd0;
        pic_music_state <= 8'd0;
        pic_music_sample <= 8'h38;
        pic_music_bank <= 4'd0;
        pic_oki_queue[0] <= 8'd0;
        pic_oki_queue[1] <= 8'd0;
        pic_oki_queue[2] <= 8'd0;
        protdata_loading <= has_protdata || chokchok_mcu_hle;
        protdata_index <= 8'd0;
        funky_pic_loading <= is_funkyjet;
        funky_pic_load_index <= 11'd0;
        preload_gap <= 2'd2;
    end else begin
        if (protdata_write || funky_pic_preload_write) preload_gap <= 2'd2;
        else if (preload_gap != 2'd0) preload_gap <= preload_gap - 2'd1;
        if (!pic_cmd_strobe) pic_cmd_strobe_d <= 1'b0;
        else if (!pic_cmd_pending) pic_cmd_strobe_d <= 1'b1;
        jump_cmd_strobe_d <= jump_cmd_strobe;
        if (pic_cmd_strobe && !pic_cmd_strobe_d && !pic_cmd_pending) begin
            pic_cmd_data <= pic_bus_command;
            pic_cmd_pending <= 1'b1;
        end
        if (jumpkids_irq_ack) jumpkids_irq <= 1'b0;
        if (pic_oki_active) begin
            if (!pic_oki_phase) begin
                pic_oki_phase <= 1'b1;
                // JT6295 applies stop/start at its serialized voice boundary.
                // Keep each command intact for one complete 132-clock sample
                // period before sending another byte or changing a music bank.
                pic_oki_wait <= 8'd132;
            end else if (pic_oki_wait != 0) begin
                if (oki_cen_bus[0]) pic_oki_wait <= pic_oki_wait - 8'd1;
            end else if (pic_oki_index + 1'b1 < pic_oki_length) begin
                if (pic_oki_length == 3 && pic_oki_index == 0)
                    pic_music_bank <= pic_next_music_bank;
                pic_oki_index <= pic_oki_index + 1'b1;
                pic_oki_phase <= 1'b0;
            end else begin
                pic_oki_active <= 1'b0;
                pic_oki_phase <= 1'b0;
                pic_oki_index <= 2'd0;
            end
        end else if (sound_id == 3'd1 && pic_cmd_pending) begin
            pic_cmd_pending <= 1'b0;
            if (pic_sound_command == 8'hfe) begin
                if (pic_cpu_command == 8'h01) begin
                    if (oki_dout[3]) begin
                        pic_oki_queue[0] <= 8'h40;
                        pic_oki_length <= 2'd1;
                        pic_oki_active <= 1'b1;
                        pic_oki_phase <= 1'b0;
                        pic_oki_index <= 2'd0;
                        pic_music_state <= 8'd0;
                    end
                end else if (pic_music_state != pic_cpu_command) begin
                    pic_music_state <= pic_cpu_command;
                    pic_next_music_bank <= pic_music_bank_for(pic_cpu_command);
                    pic_music_sample <= pic_music_sample_for(pic_cpu_command);
                    pic_oki_queue[0] <= 8'h40;
                    pic_oki_queue[1] <= 8'h80 | pic_music_sample_for(pic_cpu_command);
                    pic_oki_queue[2] <= 8'h82;
                    pic_oki_length <= 2'd3;
                    pic_oki_active <= 1'b1;
                    pic_oki_phase <= 1'b0;
                    pic_oki_index <= 2'd0;
                end
            end else if (pic_sound_command != 8'h00) begin
                if (!oki_dout[0]) begin
                    pic_oki_queue[0] <= 8'h80 | pic_sound_command;
                    pic_oki_queue[1] <= 8'h12;
                    pic_oki_length <= 2'd2;
                    pic_oki_active <= 1'b1;
                    pic_oki_phase <= 1'b0;
                    pic_oki_index <= 2'd0;
                end else if (!oki_dout[1]) begin
                    pic_oki_queue[0] <= 8'h80 | pic_sound_command;
                    pic_oki_queue[1] <= 8'h22;
                    pic_oki_length <= 2'd2;
                    pic_oki_active <= 1'b1;
                    pic_oki_phase <= 1'b0;
                    pic_oki_index <= 2'd0;
                end else if (!oki_dout[2]) begin
                    pic_oki_queue[0] <= 8'h80 | pic_sound_command;
                    pic_oki_queue[1] <= 8'h42;
                    pic_oki_length <= 2'd2;
                    pic_oki_active <= 1'b1;
                    pic_oki_phase <= 1'b0;
                    pic_oki_index <= 2'd0;
                end
            end
        end else if (sound_id == 3'd1 && irq_vblank && pic_music_state != 0 && !oki_dout[3]) begin
            pic_oki_queue[0] <= 8'h80 | pic_music_sample;
            pic_oki_queue[1] <= 8'h82;
            pic_oki_length <= 2'd2;
            pic_oki_active <= 1'b1;
            pic_oki_phase <= 1'b0;
            pic_oki_index <= 2'd0;
        end
        if (protdata_write) begin
            if (protdata_index == 8'hff) begin
                protdata_loading <= 1'b0;
                protdata_index <= 8'd0;
            end else begin
                protdata_index <= protdata_index + 1'b1;
            end
        end
        if (funky_pic_preload_write) begin
            if (funky_pic_load_index == 11'h7ff)
                funky_pic_loading <= 1'b0;
            else
                funky_pic_load_index <= funky_pic_load_index + 1'b1;
        end
        if (write_cycle) begin
            if (jump_cmd_strobe && !jump_cmd_strobe_d) begin
                sound_latch <= cpu_dout[7:0];
                jumpkids_irq <= 1'b1;
            end
            if (is_tumblepba_bank && !LDSn) tumblepba_oki_bank <= cpu_dout[5:4];
            if (is_family_d_soundcmd && !LDSn) sound_latch <= cpu_dout[7:0];
            if (is_suprtrio_soundcmd && !LDSn) sound_latch <= cpu_dout[7:0];
            if (is_funkyjet_soundcmd && !LDSn) sound_latch <= cpu_dout[7:0];
            if (is_suprtrio_protlatch && !LDSn) suprtrio_prot_latch <= cpu_dout[3:0];
            if (is_palette) palette_written[palette_mem_index] <= 1'b1;
            if (is_pf_ctrl) pf_ctrl[cpu_addr[3:1]] <= write_lanes(pf_ctrl[cpu_addr[3:1]], cpu_dout, byte_write);
            if (is_tilebank || is_suprtrio_tilebank)
                tilebank_reg <= write_lanes(tilebank_reg, cpu_dout, byte_write);
        end
        if (!protdata_write && !wram_hs_write && wram_cpu_write &&
            is_magipur && cpu_addr[23:7] == 17'd0)
            begin
                if (!UDSn) magipur_vector_hi_written[cpu_addr[6:1]] <= 1'b1;
                if (!LDSn) magipur_vector_lo_written[cpu_addr[6:1]] <= 1'b1;
            end
    end
end

// Work RAM: the preload, high-score and CPU writers keep their original
// priority. The high-score engine owns the address while the CPU is paused.
wire [14:0] wram_addr = protdata_write ? {7'd0,protdata_index} :
                        wram_hs_write  ? hs_work_index :
                        wram_cpu_write ? work_mem_index :
                        hiscore_active ? hs_work_index : work_mem_index;
wire [15:0] wram_din  = protdata_write ? (has_protdata ? main_data : chokchok_mcu_ram_word(protdata_index)) :
                        wram_hs_write  ? {hiscore_din,hiscore_din} : cpu_dout;
wire [ 1:0] wram_we   = protdata_write ? 2'b11 :
                        wram_hs_write  ? (hiscore_addr[0] ? 2'b01 : 2'b10) :
                        wram_cpu_write ? byte_write : 2'b00;

jtframe_ram16 #(.AW(15)) u_work_ram(
    .clk  ( clk      ), .data ( wram_din ), .addr ( wram_addr ),
    .we   ( wram_we  ), .q    ( work_q   )
);

wire        dxram_hs_write  = hiscore_active && hiscore_we && hs_is_family_d_extra_ram;
wire        dxram_cpu_write = write_cycle && is_family_d_extra_ram;
wire [11:0] dxram_addr = dxram_hs_write  ? hs_extra_index :
                         dxram_cpu_write ? family_d_extra_ram_index :
                         hiscore_active ? hs_extra_index : family_d_extra_ram_index;
wire [ 1:0] dxram_we   = dxram_hs_write  ? (hiscore_addr[0] ? 2'b01 : 2'b10) :
                         dxram_cpu_write ? byte_write : 2'b00;

jtframe_ram16 #(.AW(12)) u_family_d_extra_ram(
    .clk  ( clk ), .data ( dxram_hs_write ? {hiscore_din,hiscore_din} : cpu_dout ),
    .addr ( dxram_addr ), .we ( dxram_we ), .q ( family_d_extra_q )
);

jtframe_ram16 #(.AW(11)) u_aux_ram(
    .clk  ( clk ), .data ( cpu_dout ), .addr ( aux_mem_index ),
    .we   ( (write_cycle && is_aux) ? byte_write : 2'b00 ), .q ( aux_q )
);

// CPU bookkeeping and the 0x340000 row table share the existing backing
// store. Give the tile producer a registered second port at table base 0x400;
// rendering must not borrow the CPU port or maintain a stale table copy.
jtframe_dual_ram16 #(.AW(12)) u_board_extra_ram(
    .clk0 ( clk ), .data0 ( cpu_dout ), .addr0 ( board_extra_index ),
    .we0  ( (write_cycle && is_board_extra) ? byte_write : 2'b00 ), .q0 ( board_extra_q ),
    .clk1 ( clk ), .data1 ( 16'd0 ), .addr1 ( 12'h400 + {1'b0,pf1_rowscroll_addr} ),
    .we1  ( 2'b00 ), .q1 ( pf1_rowscroll_data )
);

// Port 0: 68000. Port 1: colour lookup for the mixed pixel.
jtframe_dual_ram16 #(.AW(11)) u_palette_ram(
    .clk0 ( clk ), .data0 ( cpu_dout ), .addr0 ( palette_mem_index ),
    .we0  ( (write_cycle && is_palette) ? byte_write : 2'b00 ), .q0 ( palette_q ),
    .clk1 ( clk ), .data1 ( 16'd0 ), .addr1 ( palette_index ),
    .we1  ( 2'b00 ), .q1 ( palette_pixel_q )
);

wire [1:0] pf1_cpu_we = (write_cycle && is_pf1) ? byte_write : 2'b00;
wire [1:0] pf2_cpu_we = (write_cycle && is_pf2) ? byte_write : 2'b00;

jtframe_dual_ram16 #(.AW(11)) u_pf1_even(
    .clk0 ( clk ), .data0 ( cpu_dout ), .addr0 ( pf1_mem_index[11:1] ),
    .we0  ( pf1_mem_index[0] ? 2'b00 : pf1_cpu_we ), .q0 ( pf1_even_q ),
    .clk1 ( clk ), .data1 ( 16'd0 ), .addr1 ( pf1_render_bank_addr ),
    .we1  ( 2'b00 ), .q1 ( pf1_even_render_q )
);

jtframe_dual_ram16 #(.AW(11)) u_pf1_odd(
    .clk0 ( clk ), .data0 ( cpu_dout ), .addr0 ( pf1_mem_index[11:1] ),
    .we0  ( pf1_mem_index[0] ? pf1_cpu_we : 2'b00 ), .q0 ( pf1_odd_q ),
    .clk1 ( clk ), .data1 ( 16'd0 ), .addr1 ( pf1_render_bank_addr ),
    .we1  ( 2'b00 ), .q1 ( pf1_odd_render_q )
);

jtframe_dual_ram16 #(.AW(11)) u_pf2_even(
    .clk0 ( clk ), .data0 ( cpu_dout ), .addr0 ( pf2_mem_index[11:1] ),
    .we0  ( pf2_mem_index[0] ? 2'b00 : pf2_cpu_we ), .q0 ( pf2_even_q ),
    .clk1 ( clk ), .data1 ( 16'd0 ), .addr1 ( pf2_render_bank_addr ),
    .we1  ( 2'b00 ), .q1 ( pf2_even_render_q )
);

jtframe_dual_ram16 #(.AW(11)) u_pf2_odd(
    .clk0 ( clk ), .data0 ( cpu_dout ), .addr0 ( pf2_mem_index[11:1] ),
    .we0  ( pf2_mem_index[0] ? pf2_cpu_we : 2'b00 ), .q0 ( pf2_odd_q ),
    .clk1 ( clk ), .data1 ( 16'd0 ), .addr1 ( pf2_render_bank_addr ),
    .we1  ( 2'b00 ), .q1 ( pf2_odd_render_q )
);

// The 0x1000-byte PIC region is staged as little-endian 12-bit opcodes in
// bank 0 at byte 0x140000. Preload it through the existing main SDRAM port
// while the 68000 and PIC are held in reset.
always @(posedge clk) begin
    if (funky_pic_preload_write)
        funky_pic_rom[funky_pic_load_index] <= {main_data[3:0],main_data[15:8]};
    funky_pic_ir <= funky_pic_rom[funky_pic_pc[10:0]];
end

always @(posedge clk) begin
    if (rst) begin
        funky_pic_div <= 6'd0;
        funky_pic_oki_bank <= 4'd0;
        funky_pic_data <= 8'hff;
        funky_pic_oki_din <= 8'd0;
        funky_pic_pending <= 1'b0;
        funky_cmd_strobe_d <= 1'b0;
        funky_pic_oki_wr <= 1'b0;
    end else begin
        funky_pic_oki_wr <= 1'b0;
        if (funky_pic_cen) funky_pic_div <= 6'd0;
        else funky_pic_div <= funky_pic_div + 1'b1;
        if (funky_pic_pa_we) funky_pic_oki_bank <= funky_pic_do[3:0];
        if (funky_pic_pb_we) funky_pic_data <= funky_pic_do;
        funky_cmd_strobe_d <= funky_cmd_strobe;
        if (funky_pic_pc_we) begin
            if (!funky_pic_do[2]) begin
                if (!funky_pic_do[0])
                    funky_pic_data <= oki_dout;
                else if (!funky_pic_do[1]) begin
                    funky_pic_oki_din <= funky_pic_data;
                    funky_pic_oki_wr <= 1'b1;
                end
            end
            if (!funky_pic_do[4]) funky_pic_data <= sound_latch;
            if (!funky_pic_do[5]) funky_pic_pending <= 1'b0;
        end
        // A fresh CPU command wins an acknowledgement of the older latch.
        if (funky_cmd_strobe && !funky_cmd_strobe_d) funky_pic_pending <= 1'b1;
    end
end

PIC16C5x u_funky_pic(
    .POR    ( rst || funky_pic_loading ),
    .Clk    ( clk ),
    .ClkEn  ( funky_pic_cen && is_funkyjet && !funky_pic_loading ),
    .PC     ( funky_pic_pc ),
    .IR     ( funky_pic_ir ),
    .TRISA  ( ), .PORTA ( ), .PA_DI ( 4'hf ),
    .TRISB  ( ), .PORTB ( funky_pic_portb ), .PB_DI ( funky_pic_data ),
    .TRISC  ( ), .PORTC ( funky_pic_portc ),
    .PC_DI  ( {1'b0,funky_pic_pending,6'd0} ),
    .PA_WE  ( funky_pic_pa_we ),
    .PB_WE  ( funky_pic_pb_we ),
    .PC_WE  ( funky_pic_pc_we ),
    .MCLR   ( 1'b0 ), .T0CKI ( 1'b0 ), .WDTE ( 1'b0 ),
    .Err    ( ), .OPTION ( ), .dIR ( ), .ALU_Op ( ), .KI ( ),
    .Skip   ( ), .TOS ( ), .NOS ( ), .W ( ), .FA ( ),
    .DO     ( funky_pic_do ), .DI ( ), .TMR0 ( ), .FSR ( ),
    .STATUS ( ), .T0CKI_Pls ( ), .WDTClr ( ), .WDT ( ),
    .WDT_TC ( ), .WDT_TO ( ), .PSCntr ( ), .PSC_Pls ( )
);

tumble_main u_main(
    // dip_pause is JTFRAME's active-low Pause button.
    .rst      ( rst || protdata_loading || funky_pic_loading ), .clk ( clk ),
    .haltn    ( dip_pause ),
    .bus_req  ( hiscore_pause ), .bus_grant ( cpu_bus_grant ),
    .cpu_num  ( cpu_num   ), .cpu_den ( cpu_den   ), .din     ( read_mux  ),
    .bus_cs   ( main_rom_select || pic_cmd_strobe ), .bus_busy( bus_busy  ),
    .IPLn     ( irq_pending ? 3'b001 : 3'b111 ),
    .addr     ( cpu_addr  ), .dout    ( cpu_dout  ), .rnw    ( cpu_rnw   ),
    .UDSn     ( UDSn      ), .LDSn    ( LDSn      ), .ASn    ( ASn       ),
    .FC       ( FC        )
);

assign main_cs   = main_rom_select || (protdata_loading && has_protdata) || funky_pic_loading;
assign main_addr = funky_pic_loading ? (20'ha0000 + {9'd0,funky_pic_load_index}) :
                   (protdata_loading && has_protdata) ?
                   (20'h91000 + {12'd0,protdata_index}) : {1'b0,cpu_addr[19:1]};
assign main_dout = cpu_dout;

// Direct-OKI boards and Unico's 68000-driven YM/OKI board use the main CPU.
// SemiCom profiles route the same YM/OKI devices through their sound-board Z80.
assign oki1_cs = has_oki && !jumpkids_oki2_read;
assign semicom_oki_addr = (is_family_d || is_suprtrio) ? semicom_oki_addr_raw : {4'd0,oki_rom_addr};
assign oki1_addr = (is_family_d || is_suprtrio) ? semicom_oki_addr :
                   sound_id == 3'd1 ? pic_oki_addr :
                   is_funkyjet ? funky_pic_oki_addr :
                   is_tumblepba ? tumblepba_oki_addr : {4'd0,oki_rom_addr};
assign oki2_cs = jumpkids_oki2_read;
assign jumpkids_oki2_addr = {jumpkids_oki_bank[1:0],oki_rom_addr[16:0]};
assign oki2_addr = jumpkids_oki2_read ? jumpkids_oki2_addr : 19'd0;
assign char_cs = 1'b0; assign char_addr = 15'd0;
assign scr1_cs = 1'b0; assign scr1_addr = 17'd0;
assign snd_addr = is_family_d ? semicom_snd_addr :
                  sound_id == 3'd2 ? jumpkids_snd_addr :
                  is_suprtrio ? trio_snd_addr : 16'd0;
assign snd_cs = is_family_d ? semicom_snd_cs :
                sound_id == 3'd2 ? jumpkids_snd_cs :
                is_suprtrio && trio_snd_cs;

tumble_semicom_z80 u_semicom_z80(
    .clk             ( clk                    ),
    .rst             ( rst                    ),
    .enable          ( is_family_d            ),
    .command         ( sound_latch            ),
    .rom_data        ( snd_data               ),
    .rom_ok          ( snd_ok                 ),
    .ym_data         ( semicom_ym_dout        ),
    .ym_irq_n        ( semicom_ym_irq_n       ),
    .oki_data        ( oki_dout               ),
    .rom_addr        ( semicom_snd_addr       ),
    .rom_cs          ( semicom_snd_cs         ),
    .ym_din          ( semicom_ym_din         ),
    .ym_cs_n         ( semicom_ym_cs_n        ),
    .ym_rd_n         ( semicom_ym_rd_n        ),
    .ym_wr_n         ( semicom_ym_wr_n        ),
    .ym_a0           ( semicom_ym_a0          ),
    .oki_din         ( semicom_oki_din        ),
    .oki_wr_n        ( semicom_oki_wr_n       ),
    .sample_bank     ( semicom_sample_bank    )
);

tumble_jumpkids_z80 u_jumpkids_z80(
    .clk             ( clk                    ),
    .rst             ( rst                    ),
    .enable          ( sound_id == 3'd2       ),
    .irq             ( jumpkids_irq           ),
    .command         ( sound_latch            ),
    .rom_data        ( snd_data               ),
    .rom_ok          ( snd_ok                 ),
    .oki_data        ( oki_dout               ),
    .rom_addr        ( jumpkids_snd_addr      ),
    .rom_cs          ( jumpkids_snd_cs        ),
    .oki_din         ( jumpkids_oki_din       ),
    .oki_wr_n        ( jumpkids_oki_wr_n      ),
    .irq_ack         ( jumpkids_irq_ack       ),
    .sample_bank     ( jumpkids_oki_bank      )
);

tumble_semicom_z80 #(.YM_ENABLE(0),.CPU_4M(1)) u_suprtrio_z80(
    .clk             ( clk                    ),
    .rst             ( rst                    ),
    .enable          ( is_suprtrio            ),
    .command         ( sound_latch            ),
    .rom_data        ( snd_data               ),
    .rom_ok          ( snd_ok                 ),
    .ym_data         ( 8'hff                  ),
    .ym_irq_n        ( 1'b1                   ),
    .oki_data        ( oki_dout               ),
    .rom_addr        ( trio_snd_addr          ),
    .rom_cs          ( trio_snd_cs            ),
    .ym_din          (                         ),
    .ym_cs_n         (                         ),
    .ym_rd_n         (                         ),
    .ym_wr_n         (                         ),
    .ym_a0           (                         ),
    .oki_din         ( trio_oki_din           ),
    .oki_wr_n        ( trio_oki_wr_n          ),
    .sample_bank     ( trio_sample_bank       )
);

jtframe_frac_cen #(.W(2),.WC(12)) u_semicom_opm_cen(
    .clk  ( clk ),
    .n    ( is_family_c ? 12'd1 : config_id == CFG_METLSAVR ? 12'd105 : 12'd5 ),
    .m    ( is_family_c ? 12'd12 : config_id == CFG_METLSAVR ? 12'd1408 : 12'd64 ),
    .cen  ( semicom_opm_cen ),
    .cenb (       )
);

`ifdef TUMBLE_SIM_NOAUDIO
// Simulation speed only: the YM2151 does not influence video. Its timers are
// not modelled, so sound-CPU code that waits on them will not progress.
assign semicom_ym_dout = 8'h00;
assign semicom_ym_irq_n = 1'b1;
assign semicom_opm_l = 16'sd0;
assign semicom_opm_r = 16'sd0;
`else
jtikaopm u_semicom_opm(
    .rst    ( rst                    ),
    .clk    ( clk                    ),
    .cen    ( (is_family_d || is_family_c) ? semicom_opm_cen[0] : 1'b0 ),
    .cs_n   ( opm_cs_n               ),
    .rd_n   ( opm_rd_n               ),
    .wr_n   ( opm_wr_n               ),
    .a0     ( opm_a0                 ),
    .din    ( opm_din                ),
    .dout   ( semicom_ym_dout        ),
    .ct1    (                         ),
    .ct2    (                         ),
    .irq_n  ( semicom_ym_irq_n       ),
    .left   ( semicom_opm_l          ),
    .right  ( semicom_opm_r          )
);
`endif

jtframe_frac_cen #(.W(2),.WC(10)) u_oki_cen(
    .clk  ( clk       ),
    .n    ( is_family_d ? 10'd8 : 10'd1 ),
    .m    ( is_family_d ? 10'd375 :
             (config_id == CFG_PANGPANG || sound_id == 3'd2 || sound_id == 3'd3 || sound_id == 3'd5) ? 10'd48 : 10'd60 ),
    .cen  ( oki_cen_bus ),
    .cenb (           )
);

`ifdef TUMBLE_SIM_NOAUDIO
assign oki_dout = 8'h00;
assign oki_rom_addr = 18'd0;
assign oki_audio = 14'sd0;
`else
jt6295 #(.INTERPOL(0)) u_oki(
    .rst      ( rst           ),
    .clk      ( clk           ),
    .cen      ( oki_cen_bus[0]),
    .ss       ( 1'b1          ),
    .wrn      ( ~oki_write     ),
    .din      ( oki_din       ),
    .dout     ( oki_dout      ),
    .rom_addr ( oki_rom_addr  ),
    .rom_data ( oki_rom_data  ),
    .rom_ok   ( oki_rom_ok    ),
    .sound    ( oki_audio     ),
    .sample   (               )
);
`endif

tumble_dwnld u_dwnld_remap(
    .prog_addr       ( prog_addr       ),
    .prog_mask       ( dwnld_mask      ),
    .dwnld_en        ( dwnld_en        ),
    .prog_ba         ( prog_ba         ),
    .tile_xform      ( tile_xform      ),
    .sprite_xform    ( sprite_xform    ),
    .main_xform      ( main_xform      ),
    .tile_len_bytes  ( tile_len_bytes  ),
    .sprite_len_bytes( sprite_len_bytes),
    .post_addr       ( post_addr       ),
    .post_mask       ( post_mask       )
);
assign dip_flip = 1'b0;
wire [3:0] pal_r_nib = family_c_transparent ? palette_pixel[11:8] : palette_pixel[3:0];
wire [3:0] pal_g_nib = palette_pixel[7:4];
wire [3:0] pal_b_nib = family_c_transparent ? palette_pixel[3:0] : palette_pixel[11:8];
wire [7:0] pal_r = palette_mode == 3'd2 ? {palette_pixel[4:0],palette_pixel[4:2]} : {pal_r_nib,pal_r_nib};
wire [7:0] pal_g = palette_mode == 3'd2 ? {palette_pixel[9:5],palette_pixel[9:7]} : {pal_g_nib,pal_g_nib};
wire [7:0] pal_b = palette_mode == 3'd2 ? {palette_pixel[14:10],palette_pixel[14:12]} : {pal_b_nib,pal_b_nib};
assign red = pal_r;
assign green = pal_g;
assign blue = pal_b;
assign LHBL = video_lhbl;
assign LVBL = video_lvbl;
assign HS = video_hs;
assign VS = video_vs;
assign opn = 16'sd0;
assign psg = 10'd0;
assign opm_l = (is_family_d || is_family_c) ? semicom_opm_l : 16'sd0;
assign opm_r = (is_family_d || is_family_c) ? semicom_opm_r : 16'sd0;
assign pcm1 = has_oki ? oki_audio : 14'sd0;
assign pcm2 = 14'sd0;
assign debug_view = 8'd0;

assign dma_addr = object_dma_addr;
assign dma_we = object_dma_we;
assign objcpu_addr = (is_family_d || is_suprtrio) ? cpu_addr[11:1] : {1'b0,cpu_addr[10:1]};
assign objcpu_we = {2{write_cycle && is_sprite}} & byte_write;
assign oram_addr = object_scan_addr;
assign work_we = 2'b00;
assign sndram_we = 1'b0; assign sndram_din = 8'd0; assign sndram_addr = 13'd0;
assign pal_addr = 12'd0;
assign palrw_we = 2'b00; assign palrw_addr = 12'd0;

`ifdef JTFRAME_STATUS
assign st_dout = 8'd0;
`endif
`ifdef JTFRAME_IOCTL_RD
assign ioctl_din = 8'd0;
`endif

endmodule
