// SPDX-License-Identifier: GPL-3.0-or-later
// Board shell derived from the pinned local Violent Storm donor.
// Gaiapolis map/IRQ/EEPROM/collision/ROZ readback replace title-specific glue.
// Video/sound donor adaptations and persistence are tracked in progress.md.
module jtgaiapolis_game(
    input wire monster,
    input wire cen_pixel,
    output wire [14:0] wram_cpu_addr,
    output wire [12:0] wram_restore_row,
    output wire [2:0] wram_restore_lane,
    output wire wram_restore_select,
    `include "jtframe_game_ports.inc"
);
    // The header is written at96MHz while game logic runs at48MHz.
    // Sample its board selection locally during the existing download reset;
    // long game address paths then have a complete48MHz clock period.
    reg monster_48;
    always @(posedge clk48) monster_48 <= monster;
    // The ROM cache selects its returned word at96MHz. Register data and
    // validity together there before the48/24MHz consumers, giving cache
    // selection a full SDRAM-clock period and preserving response ownership.
    (* dont_retime *) reg [15:0] main_data_96q;
    (* dont_retime *) reg main_ok_96q;
    (* dont_retime *) reg [7:0] snd_data_96q;
    (* dont_retime *) reg snd_ok_96q;
    (* dont_retime *) reg [7:0] pcma_data_96q;
    (* dont_retime *) reg pcma_ok_96q;
    (* dont_retime *) reg [7:0] pcmb_data_96q;
    (* dont_retime *) reg pcmb_ok_96q;
    (* dont_retime *) reg [31:0] rozchar_data_96q;
    (* dont_retime *) reg rozchar_ok_96q;
    (* dont_retime *) reg [7:0] rozmap_data_96q;
    (* dont_retime *) reg rozmap_ok_96q;
    (* dont_retime *) reg [31:0] tile_data_96q;
    (* dont_retime *) reg tile_ok_96q;
    (* dont_retime *) reg [31:0] obj_data_96q;
    (* dont_retime *) reg obj_ok_96q;
    always @(posedge clk) begin
        main_data_96q <= main_data;
        main_ok_96q <= !rst48 && main_ok && main_cs;
        snd_data_96q <= snd_data;
        snd_ok_96q <= !rst48 && snd_ok && snd_cs;
        pcma_data_96q <= pcma_data;
        pcma_ok_96q <= !rst48 && pcma_ok && pcma_cs;
        pcmb_data_96q <= pcmb_data;
        pcmb_ok_96q <= !rst48 && pcmb_ok && pcmb_cs;
        rozchar_data_96q <= rozchar_data;
        rozchar_ok_96q <= !rst48 && rozchar_ok && rozchar_cs;
        rozmap_data_96q <= rozmap_data;
        rozmap_ok_96q <= !rst48 && rozmap_ok && rozmap_cs;
        tile_data_96q <= tile_data;
        tile_ok_96q <= !rst48 && tile_ok && tile_cs;
        obj_data_96q <= obj_data;
        obj_ok_96q <= !rst48 && obj_ok && obj_cs;
    end
    // Publish the complete sprite ROM response between the aligned 96 MHz
    // and 48 MHz rising edges. Cache selection still has a full 96 MHz cycle.
    (* dont_retime *) reg [31:0] obj_data_96n;
    (* dont_retime *) reg obj_ok_96n;
    always @(negedge clk) begin
        obj_data_96n <= obj_data_96q;
        obj_ok_96n <= obj_ok_96q;
    end
    // Re-register at the 48 MHz edge so the sprite engine and CPU readback
    // see the response on a full 48 MHz cycle, not the 96 MHz half cycle.
    (* dont_retime *) reg [31:0] obj_data_48q;
    (* dont_retime *) reg obj_ok_48q;
    always @(posedge clk48) begin
        obj_data_48q <= obj_data_96n;
        obj_ok_48q <= obj_ok_96n;
    end
    wire [22:2] base_tile_addr;
    wire base_tile_cs,base_tile_ok;
    wire [31:0] base_tile_data,sprite5_data;
    wire [18:0] sprite5_addr;
    wire sprite5_cs,sprite5_ok;
    gaiapolis_rom_arb #(.ADDR_WIDTH(21),.DATA_WIDTH(32)) u_sprite5_arb(
        .clk(clk48),.rst(rst_main),
        .a_cs(base_tile_cs),.a_addr(base_tile_addr),.a_data(base_tile_data),.a_ok(base_tile_ok),
        .b_cs(sprite5_cs),.b_addr(21'h180000+{2'd0,sprite5_addr}),
        .b_data(sprite5_data),.b_ok(sprite5_ok),
        .rom_cs(tile_cs),.rom_addr(tile_addr),.rom_data(tile_data_96q),.rom_ok(tile_ok_96q)
    );
    // Main 68000 bus. JTFRAME's game clock is clk48 for CPU/video-control
    // logic while SDRAM arbitration remains in the generated wrapper.
    wire [23:1] cpu_a;
    wire [ 2:0] cpu_fc;
    wire [15:0] cpu_din;
    wire [15:0] cpu_dout_i;
    wire        cpu_rnw, cpu_asn, cpu_uds_n, cpu_lds_n;
    wire        cpu_dtack_n, cpu_vpa_n, cpu_reset_n, cpu_bg_n;
    wire        cpu_cen, cpu_cenb;
    wire [ 2:0] cpu_ipln;
    wire        cpu_bus_active = !cpu_asn && !(cpu_uds_n && cpu_lds_n);
    wire [23:0] real_cpu_byte_addr = {cpu_a[23:1],1'b0};
    wire [23:0] cpu_byte_addr = prot_req ? prot_addr : real_cpu_byte_addr;
    wire [ 1:0] cpu_dsn = {cpu_uds_n,cpu_lds_n};
    wire        bus_cs;
    wire        bus_busy;
    wire        bus_dtack_n;
    reg  [15:0] bus_din;
    reg  [15:0] cpu_din_r;
    reg         rst_main;
    wire        main_ok_dly;

    wire prot_cs=monster_48 && cpu_bus_active && real_cpu_byte_addr[23:6]==18'h1a000;
    wire prot_req,prot_busy,prot_ready,prot_rnw;
    wire [23:0] prot_addr;
    wire [15:0] prot_data,prot_q;
    wire [1:0] prot_dsn;
    wire [23:1] dev_a=cpu_byte_addr[23:1];
    wire [15:0] dev_dout=prot_req ? prot_data : cpu_dout_i;
    wire [1:0] dev_dsn=prot_req ? prot_dsn : cpu_dsn;
    wire dev_rnw=prot_req ? prot_rnw : cpu_rnw;
    wire dev_asn=prot_req ? 1'b0 : cpu_asn;
    wire dev_bus_active=prot_req || cpu_bus_active;
    wire device_busy;
    gaiapolis_k055550 u_protection(
        .clk(clk48),.rst(rst_main),.cen(1'b1),.cs(prot_cs),.rnw(cpu_rnw),
        .addr(cpu_a[5:1]),.din(cpu_dout_i),.dsn(cpu_dsn),.dout(prot_q),
        .dtack(prot_ready),.busy(prot_busy),.bus_req(prot_req),
        .bus_addr(prot_addr),.bus_rnw(prot_rnw),.bus_dout(prot_data),.bus_dsn(prot_dsn),
        .bus_ack(prot_req && !device_busy),.bus_din(bus_din)
    );
    // Drain real CPU/PCM/EEPROM transactions before holding gameplay. Scanout
    // and the shared ROM controller retain their clocks throughout the hold.
    wire pause_main_halt_n, pause_sound_busrq_n;
    wire pause_main_ce_run, pause_sound_ce_run, pause_pcm_quiesce;
    wire gameplay_freeze, gameplay_irq_run, pause_ack, pause_boundary_fault;
    wire pause_sound_busak_n, pause_sound_mreq_n, pause_sound_iorq_n;
    wire pause_sound_rd_n, pause_sound_wr_n, pause_sound_pending;
    wire [1:0] pause_pcm_idle;
    wire unused_nvram_safe_grant48, restore_cancel_seed;
    wire unused_nvram_dirty_toggle;
`ifdef JTFRAME_SAVEGAME
    wire nvram_freeze_req = sav_ack;
    wire nvram_restore_pending = sav_wr[0];
    wire unused_nvram_safe_grant96;
    wire [32:0] unused_legacy_sav_inputs = {sav_wr[1],sav_dout,sav_addr};
    gaiapolis_pause_nvram u_nv_bridge(
        .clk(clk), .rst(rst48), .freeze_req(nvram_freeze_req),
        .safe_grant48(unused_nvram_safe_grant48 && !hs_pause_request),
        .dirty_toggle48(unused_nvram_dirty_toggle),
        .safe_grant96(unused_nvram_safe_grant96),
        .sav_wait(sav_wait), .sav_change(sav_change)
    );
    // EEPROM plus high-score shadow use the generated 384-byte IOCTL dump port.
    assign sav_din = 16'h0000;
    assign sav_done = 1'b0;
`else
    wire nvram_freeze_req = 1'b0;
    wire nvram_restore_pending = 1'b0;
`endif


    wire cs_main, cs_ram, cs_obj, cs_vram, cs_palette, cs_tile_read;
    wire cs_k053252, cs_k054321, cs_k054338, cs_k055555, cs_sound_irq;
    wire k056832_b_cs, k056832_reg_cs;
    wire sprite_mmr_cs, sprite_cpu_rom_read, sprite_objset2_cs;
    wire cs_roz_ctrl, cs_roz_line, cs_roz_clip, cs_roz_enable;
    wire cs_roz_map0, cs_roz_map1, cs_roz_tiles, cs_collision;
    wire cs_inputs, cs_eeprom_read, cs_eeprom_write, cs_watchdog;
    wire bus_rd, bus_wr, in1_rd, p2_rd, sprite_chip_sel;
    wire [1:0] byte_mask;
    wire [10:0] sprite_chip_addr;
    wire [4:0] window_id;
    wire [20:0] window_offset;
    wire cs_any;
    gaiapolis_decode u_decode(
        .monster(monster_48),
        .addr(cpu_byte_addr), .as_n(dev_asn), .rnw(dev_rnw),
        .uds_n(dev_dsn[1]), .lds_n(dev_dsn[0]),
        .rd(bus_rd), .wr(bus_wr), .byte_mask(byte_mask),
        .mapped(cs_any), .window_id(window_id), .offset_word(window_offset),
        .cs_rom(cs_main), .cs_workram(cs_ram), .cs_sprite_ram(cs_obj),
        .cs_tile_ram(cs_vram), .cs_palette(cs_palette),
        .cs_sprite_ctrl(sprite_mmr_cs), .cs_sprite_rom(sprite_cpu_rom_read),
        .cs_sprite_reg(sprite_objset2_cs), .cs_tile_rom(cs_tile_read),
        .cs_tile_ctrl(k056832_reg_cs), .cs_tile_bctrl(k056832_b_cs),
        .cs_ccu(cs_k053252), .cs_sound(cs_k054321),
        .cs_mixer(cs_k054338), .cs_priority(cs_k055555),
        .cs_sound_irq(cs_sound_irq), .cs_collision(cs_collision),
        .cs_inputs(cs_inputs), .cs_eeprom_read(cs_eeprom_read),
        .cs_eeprom_write(cs_eeprom_write), .cs_watchdog(cs_watchdog),
        .cs_roz_ctrl(cs_roz_ctrl), .cs_roz_line(cs_roz_line),
        .cs_roz_clip(cs_roz_clip), .cs_roz_enable(cs_roz_enable),
        .cs_roz_map0(cs_roz_map0), .cs_roz_map1(cs_roz_map1),
        .cs_roz_tiles(cs_roz_tiles), .in1_rd(in1_rd), .p2_rd(p2_rd),
        .sprite_chip_sel(sprite_chip_sel), .sprite_chip_addr(sprite_chip_addr)
    );
    wire k056832_we = (k056832_b_cs || k056832_reg_cs) && bus_wr;
    wire sprite_obj_cs = cs_obj && sprite_chip_sel;
    wire sprite_obj_we = sprite_obj_cs && bus_wr;
    wire sprite_objset2_we = sprite_objset2_cs && bus_wr;
    wire [15:0] k056832_dout;
    wire [17:1] k056832_vram_addr;
    wire [1:0]  k056832_vram_we;
    wire        k056832_tile_cs, k056832_tile_wait;
    wire [22:2] k056832_tile_addr;
    wire [4:0]  k056832_selected_page;
    wire [8:0]  k056832_rom_bank;
    wire        k056832_mode_5bpp;

    wire [15:0] sprite_cpu_dout;
    wire sprite_cpu_rom_ready;
    wire [22:2] sprite_rom_addr;
    wire        sprite_rom_cs;
    wire        sprite_dma_busy, sprite_ln_done;
    wire [1:0]  unused_sprite_shadow;
    wire [2:0]  unused_sprite_shadow_prio;
    wire [4:0]  unused_sprite_priority;
    wire [1:0] unused_sprite_priority_padding = unused_sprite_priority[4:3];
    wire [9:0]  sprite_pixel;
    wire [1:0] sprite_mix;
    wire        sprite_objcha_n = !sprite_cpu_rom_read;


    // BRAM CPU stores retain the actual board-visible address/byte enables.
    assign main_addr = dev_a[21:1];
    assign main_cs = cs_main;
    assign cpu_dout = dev_dout;
    reg [15:1] wram_addr_q;
    reg ram_ok;
    always @(posedge clk48) begin
        wram_addr_q <= dev_a[15:1];
        ram_ok <= cs_ram && dev_a[15:1] == wram_addr_q;
    end
    wire [15:0] ram_data = wram_dout;

    // Classify persistent storage before letting POST run. File ownership only
    // inhibits a new restoration; an existing restoration drains under pause.
    reg [1:0] hs_file_hold;
    always @(posedge clk48) begin
        if (rst48) hs_file_hold <= 2'b00;
        else hs_file_hold <= {hs_file_hold[0], nvram_freeze_req};
    end
    wire [6:0] hs_core_addr;
    wire [15:0] hs_core_data;
    wire [1:0] hs_core_we;
    wire hs_pause_request, hs_boot_ready, hs_dirty;
    wire hs_shadow_valid, hs_table_initialized, hs_boundary_fault;
    wire hs_cpu_commit, hs_restore_owns_ram;
    wire [7:0] hs_restored_words;
    wire [12:0] unused_hiscore_status = {hs_shadow_valid, hs_table_initialized,
        hs_boundary_fault, hs_cpu_commit, hs_restore_owns_ram, hs_restored_words};
    assign wram_cpu_addr = dev_a[15:1];
    assign wram_restore_select = hs_restore_owns_ram;
    gaiapolis_hiscore_bus u_hiscore(
        .monster(monster_48),
        .clk(clk48), .rst(nvram_hold_reset), .restore_inhibit(hs_file_hold[1]),
        .pause_safe(pause_ack), .cpu_ram_selected(cs_ram), .cpu_bus_write(bus_wr),
        .cpu_ram_ready(ram_ok), .cpu_addr(dev_a), .cpu_data(dev_dout),
        .cpu_we(byte_mask), .wram_addr(wram_addr), .wram_data(wram_din),
        .restore_row(wram_restore_row), .restore_lane(wram_restore_lane),
        .wram_we(wram_we), .hs_addr(hs_core_addr), .hs_data(hs_core_data),
        .hs_we(hs_core_we), .hs_dout(hscore_dout), .pause_request(hs_pause_request),
        .boot_ready(hs_boot_ready), .hs_dirty(hs_dirty), .shadow_valid(hs_shadow_valid),
        .table_initialized(hs_table_initialized), .boundary_fault(hs_boundary_fault),
        .restored_words(hs_restored_words), .cpu_commit(hs_cpu_commit),
        .restore_owns_ram(hs_restore_owns_ram)
    );
    // Loading another image invalidates the old marker. Soft reset retains it.
    assign hscore_addr = nvram_image_load ? 7'd127 : hs_core_addr;
    assign hscore_din = nvram_image_load ? 16'd0 : hs_core_data;
    assign hscore_we = nvram_image_load ? 2'b11 : hs_core_we;

    // The 64KiB scattered CPU window contains compact chip words and backing
    // RAM. Only offset word bits 6:3 == 0 reach K053247's 4KiB store.
    // Preserve the full64KiB CPU window and one-edge OLD_DATA read contract.
    // Packed5-bit planes retain both byte lanes without off-chip traffic.
    wire [15:0] scatter_dout;
    reg scatter_ready;
    reg [14:0] scatter_addr_q;
    always @(posedge clk48) begin
        scatter_addr_q <= dev_a[15:1];
        scatter_ready <= cs_obj && scatter_addr_q == dev_a[15:1];
    end
    gaiapolis_word_ram_packed #(.AW(15)) u_scatter_ram(
        .clk(clk48), .addr(dev_a[15:1]), .data(dev_dout),
        .we(byte_mask & {2{cs_obj && bus_wr}}), .q(scatter_dout),
        .cpu_addr(15'd0), .restore_row(13'd0), .restore_lane(3'd0), .restore_select(1'b0));
    wire [12:1] uv_addr = k056832_vram_addr[12:1];
    wire [1:0] uv_we = k056832_vram_we;
    wire [15:0] uv_din = dev_dout;
    wire        unp_sel = k056832_selected_page[4];
    reg  [ 7:0] unp_hi [0:4095];
    reg  [ 7:0] unp_lo [0:4095];
    reg  [15:0] unp_dout;
    reg         unp_sel_q;
    always @(posedge clk48) begin
        unp_sel_q <= unp_sel;
        unp_dout  <= {unp_hi[uv_addr], unp_lo[uv_addr]};
        if (unp_sel && uv_we[1]) unp_hi[uv_addr] <= uv_din[15:8];
        if (unp_sel && uv_we[0]) unp_lo[uv_addr] <= uv_din[7:0];
    end
    wire [15:0] vram_cpu_dout = unp_sel_q ? unp_dout : vmem_dout;
    assign vmem_addr = k056832_vram_addr[16:1];
    // Decode each owner before the ownership mux. This is the same tile
    // window/lane/write predicate, without address-mux -> decode -> chip WE.
    wire [1:0] cpu_vmem_we = (!cpu_asn && !cpu_rnw &&
        real_cpu_byte_addr[23:14]==10'h104) ? ~cpu_dsn : 2'b00;
    wire [1:0] prot_vmem_we = (!prot_rnw &&
        prot_addr[23:14]==10'h104) ? ~prot_dsn : 2'b00;
    assign vmem_we = (prot_req ? prot_vmem_we : cpu_vmem_we) & {2{~unp_sel}};
    assign vram_addr = video_vram_addr;

    assign cpalh_addr = dev_a[12:2];
    assign cpall_addr = cpalh_addr;
    assign cpalh_we = {2{cs_palette && bus_wr && !dev_a[1]}} & byte_mask;
    assign cpall_we = {2{cs_palette && bus_wr &&  dev_a[1]}} & byte_mask;
    assign palh_addr = palette_index[10:0];
    assign pall_addr = palette_index[10:0];
    assign base_tile_addr = k056832_tile_cs ? k056832_tile_addr : video_tile_addr;
    assign base_tile_cs = k056832_tile_cs || video_tile_cs;
    assign obj_addr = sprite_rom_addr;
    assign obj_cs = sprite_rom_cs;

    wire k054338_we = cs_k054338 && bus_wr;
    wire k055555_we = cs_k055555 && bus_wr;
    // This board maps K054321 on UDS, unlike the primary donor board.
    wire k054321_we = cs_k054321 && bus_wr;
    wire sound_irq_we = cs_sound_irq && bus_wr;
    wire [7:0] k054321_dout, k054321_active, sound_st_dout;
    wire k054321_irq_n;
    wire [6:0] k054321_volume;
    wire [7:0] k053252_dout;
    wire k053252_lhbl, k053252_lvbl, k053252_hs, k053252_vs;
    wire [8:0] k053252_hpos, k053252_vpos;
    wire k053252_int1, k053252_int2;
    wire sprite_dma_enabled;
    // Gaiapolis asserts level 5 once per vblank. An interrupt acknowledge
    // clears the pending level; CCU and object DMA do not generate IRQ6.
    reg lvbl_q, irq5_latched;
    wire cpu_iack = !cpu_asn && cpu_fc == 3'b111;
    always @(posedge clk48) begin
        lvbl_q <= k053252_lvbl;
        if (rst_main) irq5_latched <= 1'b0;
        else if (lvbl_q && !k053252_lvbl && gameplay_irq_run) irq5_latched <= 1'b1;
        else if (cpu_iack) irq5_latched <= 1'b0;
    end
    assign cpu_ipln = irq5_latched && !rst_main ? 3'b010 : 3'b111;
    assign cpu_vpa_n = !(cpu_iack && !rst_main);
    wire [7:0] priority_code, unused_palette_code, brightness_code;
    wire [3:0] unused_priority_diagnostic_bits = priority_code[7:4];
    wire [7:0] osbri_code, unused_osbri_on_code;
    wire [3:0] unused_osbri_upper_bits = osbri_code[7:4];
    wire [7:0] shadow_priority1, shadow_priority2, shadow_priority3;
    wire [31:0] sprite_order, unused_sprite_shadow_order;
    wire [7:0] sprite_shadow_ops_valid, unused_sprite_shadow_priority_full;
    wire [15:0] sprite_shadow_ops_mode;
    wire [255:0] sprite_shadow_ops_order;
    wire sprite_line_overrun, sprite_shadow_ops_overflow;
    wire [7:0] layer_priority0, layer_priority1, layer_priority2, layer_priority3;
    wire [7:0] input_enables;
    wire [1:0] unused_unpopulated_sub_inputs = input_enables[7:6];
    wire [11:0] object_palette_base;
    wire [11:0] roz_palette_base;
    wire [7:0] roz_priority, sub2_priority;
    wire [1:0] roz_mix;
    wire [7:0] unused_k055555_state_data;
    wire [3:0] unused_mix_code, unused_shadow_code;
    wire [7:0] tile_blend, tile_blend_on;
    wire [3:1] unused_transparent_mixes;
    wire [7:0] colour_r, colour_g, colour_b;
    wire [3:0] k056832_page0, k056832_page1, k056832_page2, k056832_page3;
    // Full 16-bit signed K056832 scroll registers -- see Fix 4, jtviostorm_k056832.sv.
    wire signed [15:0] k056832_dx0, k056832_dx1, k056832_dx2, k056832_dx3;
    wire signed [15:0] k056832_dy0, k056832_dy1, k056832_dy2, k056832_dy3;
    wire [1:0] k056832_flip0, k056832_flip1, k056832_flip2, k056832_flip3;
    // Global screen flip (REG0 bits 5/4) + correction registers 0x3c/0x3a --
    // see port comments in jtviostorm_k056832.sv / jtviostorm_k056832_video.sv.
    wire        k056832_gflip_x, k056832_gflip_y;
    wire [511:0] k056832_config_regs;
    wire signed [12:0] k056832_corr_x;
    wire signed [11:0] k056832_corr_y;
    wire [16:1] video_vram_addr;
    wire        video_tile_cs;
    wire [22:2] video_tile_addr;
    // Donor pixel interface retains five pen bits; the Gaiapolis renderer
    // supplies a zero fifth bit and the real four-bit pen below it.
    wire [8:0]  lyrf_pxl, lyra_pxl, lyrb_pxl, lyrc_pxl;
    wire [1:0]  lyrf_mix, lyra_mix, lyrb_mix, lyrc_mix;
    wire [11:0] palette_index;
    wire [11:0] layer_palette0, layer_palette1, layer_palette2, layer_palette3;

    wire [7:0] io_p1 = {cab_1p[0],joystick1[6:4],joystick1[3:0]};
    wire [7:0] io_p2 = {cab_1p[1],joystick2[6:4],joystick2[3:0]};
    // Runtime MAME masks: coins D8/9, test D11, service credits D12/13.
    wire [7:0] io_in0 = {2'b11,~status[24],service,dip_test,1'b1,coin[1:0]};
    wire [30:0] unused_platform_status = {status[31:25],status[23:0]};
    wire eep_do, eep_rdy;
    wire [7:0] io_in1 = {dipsw[7:4],dip_test,1'b0,eep_rdy,eep_do};
    reg [2:0] eep_ctrl_r;
    always @(posedge clk48) begin
        if (rst_main) eep_ctrl_r <= 3'b0;
        else if (cs_eeprom_write && bus_wr) eep_ctrl_r <= dev_dout[2:0];
    end
    wire [6:0] eep_mem_addr;
    wire [7:0] eep_mem_din;
    wire eep_mem_we;
    // Copy a new image's factory seed once. The generated dump mux owns
    // restore writes; a soft reset must retain the already initialized BRAM.
    wire seed_active;
    wire [6:0] seed_addr;
    wire nvram_hold_reset;
    wire unused_nvram_init_busy, nvram_initialized;
    wire nvram_image_load = (prog_we || prom_we) && !ioctl_ram;
    gaiapolis_nvram_init u_nvram_init(
        .clk(clk), .reset(rst48), .image_load(nvram_image_load),
        .restore_session(ioctl_ram || restore_cancel_seed),
        .restore_write(ioctl_wr && ioctl_ram),
        .seed_data(nvseed_data), .seed_addr(seed_addr),
        .eeprom_addr(eep_mem_addr), .eeprom_data(eep_mem_din),
        .eeprom_write(eep_mem_we),
        .nvram_addr(nvram_addr), .nvram_data(nvram_din),
        .nvram_write(nvram_we), .hold_reset(nvram_hold_reset),
        .init_busy(unused_nvram_init_busy), .initialized(nvram_initialized),
        .seed_active(seed_active)
    );
    assign nvseed_addr = seed_addr;
    always @(posedge clk48) rst_main <= nvram_hold_reset || !hs_boot_ready;
    gaiapolis_pause_controller u_pause(
        .clk(clk48), .rst(rst48), .pause_req(!dip_pause || hs_pause_request),
        .nv_freeze_req(nvram_freeze_req), .restore_pending(nvram_restore_pending),
        .nv_initialized(nvram_initialized), .seed_active(seed_active),
        .core_reset(rst_main), .main_phi1(cpu_cen), .main_phi2(cpu_cenb),
        .main_as_n(cpu_asn), .main_uds_n(cpu_uds_n), .main_lds_n(cpu_lds_n),
        .main_pending(bus_busy), .sound_busak_n(pause_sound_busak_n),
        .sound_mreq_n(pause_sound_mreq_n), .sound_iorq_n(pause_sound_iorq_n),
        .sound_rd_n(pause_sound_rd_n), .sound_wr_n(pause_sound_wr_n),
        .sound_pending(pause_sound_pending), .pcm_idle(pause_pcm_idle),
        .eeprom_cs(eep_ctrl_r[1]), .eeprom_ready(eep_rdy),
        .eeprom_write(eep_mem_we),
        .eeprom_control_write(cs_eeprom_write && bus_wr),
        .nv_write_pending(nvram_we), .eeprom_commit((eep_mem_we && nvram_we) || hs_dirty),
        .main_halt_n(pause_main_halt_n), .sound_busrq_n(pause_sound_busrq_n),
        .main_ce_run(pause_main_ce_run), .sound_ce_run(pause_sound_ce_run),
        .pcm_quiesce(pause_pcm_quiesce), .gameplay_freeze(gameplay_freeze),
        .gameplay_irq_run(gameplay_irq_run), .pause_ack(pause_ack),
        .nv_safe_grant(unused_nvram_safe_grant48), .restore_cancel_seed(restore_cancel_seed),
        .dirty_toggle(unused_nvram_dirty_toggle), .boundary_fault(pause_boundary_fault)
    );
    gaiapolis_eeprom #(.PROG(0)) u_eeprom(
        .rst(rst_main), .clk(clk48), .sclk(eep_ctrl_r[2]),
        .sdi(eep_ctrl_r[0]), .sdo(eep_do), .rdy(eep_rdy),
        .scs(eep_ctrl_r[1]), .mem_addr(eep_mem_addr),
        .mem_din(eep_mem_din), .mem_we(eep_mem_we), .mem_dout(nvram_dout),
        .dump_clr(1'b0), .dump_flag()
    );
    wire [7:0] collision_dout;
    wire collision_ready;
    reg collision_cycle_q;
    always @(posedge clk48) begin
        if (rst_main || !cs_collision) collision_cycle_q <= 1'b0;
        else collision_cycle_q <= 1'b1;
    end
    gaiapolis_k054000 u_collision(
        .clk(clk48), .rst(rst_main), .cs(cs_collision),
        .addr(dev_a[5:1]), .we(bus_wr && !collision_cycle_q),
        .din(dev_dout[7:0]), .dout(collision_dout), .ready(collision_ready),
        .state_addr(5'd0), .state_dout()
    );
    wire [15:0] roz_cpu_dout;
    wire roz_cpu_ready, roz_enabled;
    wire [15:0] roz_ctrl_data, roz_line_data, roz_clip_rect;
    wire roz_clip_enabled;
    wire [3:0] roz_ctrl_addr;
    wire [10:0] roz_line_addr;
    wire [19:0] roz_cpu_map_addr, roz_render_map_addr;
    wire roz_cpu_map_cs, roz_cpu_map_ok, roz_render_map_cs, roz_render_map_ok;
    wire [7:0] roz_cpu_map_data, roz_render_map_data;
    wire [20:0] roz_cpu_char_addr, roz_render_char_addr;
    wire [1:0] unused_roz_character_alignment = roz_render_char_addr[1:0];
    wire roz_cpu_char_cs, roz_cpu_char_ok, roz_render_char_cs, roz_render_char_ok;
    wire [31:0] roz_cpu_char_word, roz_render_char_word;
    wire [7:0] roz_cpu_char_data = roz_cpu_char_word[{roz_cpu_char_addr[1:0],3'b000} +: 8];
    // The physical SWAB=1 SDRAM stream stores address byte0 in bits7:0.
    // The ROZ renderer's canonical packed pixels put byte0 in bits31:24.
    wire [31:0] roz_render_char_data = {roz_render_char_word[7:0],
        roz_render_char_word[15:8],roz_render_char_word[23:16],roz_render_char_word[31:24]};
    wire [4:0] roz_palette;
    wire [3:0] roz_pen;
    wire [7:0] roz_pen8;
    wire roz_pixel_valid, roz_underflow;
    // LHBL opens at hpos 106/200, where tile column 0 = bitmap x40/x24. The
    // ROZ reads at the pxl_cen edge that ends period hpos for display in
    // period hpos+1, so its column is bitmap x = hpos+1-66 (Monster -176).
    wire [8:0] roz_hpos = k053252_hpos - (monster_48 ? 9'd175 : 9'd65);
    wire [8:0] roz_vpos = k053252_vpos - 9'd255;
    gaiapolis_roz_regs u_roz_regs(
        .monster(monster_48),
        .clk(clk48), .rst(rst_main), .addr(cpu_byte_addr[20:1]),
        .wr(bus_wr), .byte_mask(byte_mask), .din(dev_dout),
        .cs_ctrl(cs_roz_ctrl), .cs_line(cs_roz_line),
        .cs_clip(cs_roz_clip), .cs_enable(cs_roz_enable),
        .cs_map0(cs_roz_map0), .cs_map1(cs_roz_map1), .cs_tiles(cs_roz_tiles),
        .cpu_dout(roz_cpu_dout), .cpu_ready(roz_cpu_ready),
        .map_addr(roz_cpu_map_addr), .map_cs(roz_cpu_map_cs),
        .map_data(roz_cpu_map_data), .map_ok(roz_cpu_map_ok),
        .char_addr(roz_cpu_char_addr), .char_cs(roz_cpu_char_cs),
        .char_data(roz_cpu_char_data), .char_ok(roz_cpu_char_ok),
        .render_ctrl_addr(roz_ctrl_addr), .render_ctrl_data(roz_ctrl_data),
        .render_line_addr(roz_line_addr), .render_line_data(roz_line_data),
        .enabled(roz_enabled), .clip_enabled(roz_clip_enabled), .clip_rect(roz_clip_rect)
    );
    gaiapolis_rom_arb #(.ADDR_WIDTH(20),.DATA_WIDTH(8)) u_roz_map_arb(
        .clk(clk48), .rst(rst_main),
        .a_cs(roz_cpu_map_cs), .a_addr(roz_cpu_map_addr),
        .a_data(roz_cpu_map_data), .a_ok(roz_cpu_map_ok),
        .b_cs(roz_render_map_cs), .b_addr(roz_render_map_addr),
        .b_data(roz_render_map_data), .b_ok(roz_render_map_ok),
        .rom_cs(rozmap_cs), .rom_addr(rozmap_addr),
        .rom_data(rozmap_data_96q), .rom_ok(rozmap_ok_96q)
    );
    gaiapolis_rom_arb #(.ADDR_WIDTH(19),.DATA_WIDTH(32)) u_roz_char_arb(
        .clk(clk48), .rst(rst_main),
        .a_cs(roz_cpu_char_cs), .a_addr(roz_cpu_char_addr[20:2]),
        .a_data(roz_cpu_char_word), .a_ok(roz_cpu_char_ok),
        .b_cs(roz_render_char_cs), .b_addr(roz_render_char_addr[20:2]),
        .b_data(roz_render_char_word), .b_ok(roz_render_char_ok),
        .rom_cs(rozchar_cs), .rom_addr(rozchar_addr),
        .rom_data(rozchar_data_96q), .rom_ok(rozchar_ok_96q)
    );
    gaiapolis_roz u_roz_video(
        .monster(monster_48),
        .clk(clk48), .rst(rst_main), .pxl_cen(cen_pixel),
        .hpos(roz_hpos), .vpos(roz_vpos),
        // The first fetch (bitmap x40) happens on the edge ending the last
        // blank period, so gate only vertically; H_FIRST/H_LAST bound x.
        .active_video(k053252_lvbl),
        .enabled(roz_enabled && input_enables[5]),
        .clip_enabled(roz_clip_enabled), .clip_rect(roz_clip_rect),
        .ctrl_addr(roz_ctrl_addr), .ctrl_data(roz_ctrl_data),
        .line_addr(roz_line_addr), .line_data(roz_line_data),
        .map_addr(roz_render_map_addr), .map_cs(roz_render_map_cs),
        .map_data(roz_render_map_data), .map_ok(roz_render_map_ok),
        .char_addr(roz_render_char_addr), .char_cs(roz_render_char_cs),
        .char_data(roz_render_char_data), .char_ok(roz_render_char_ok),
        .palette(roz_palette), .pen(roz_pen), .pen8(roz_pen8),
        .pixel_valid(roz_pixel_valid), .underflow(roz_underflow)
    );

    gaiapolis_k055555 u_k055555(
        .monster(monster_48),
        .clk             ( clk48 ),
        .rst             ( rst_main ),
        .we              ( k055555_we ),
        .addr            ( cpu_byte_addr[7:1] ),
        .dsn             ( dev_dsn ),
        .din             ( dev_dout ),
        .priority_code   ( priority_code ),
        .palette_code    ( unused_palette_code ),
        .mix_code        ( unused_mix_code ),
        .tile_blend      ( tile_blend ),
        .tile_blend_on   ( tile_blend_on ),
        .shadow_code     ( unused_shadow_code ),
        .shadow_priority1(shadow_priority1), .shadow_priority2(shadow_priority2), .shadow_priority3(shadow_priority3),
        .brightness_code ( brightness_code ),
        .osbri_code      ( osbri_code ),
        .osbri_on_code   ( unused_osbri_on_code ),
        .layer_palette0  ( layer_palette0 ),
        .layer_palette1  ( layer_palette1 ),
        .layer_palette2  ( layer_palette2 ),
        .layer_palette3  ( layer_palette3 ),
        .layer_priority0 ( layer_priority0 ),
        .layer_priority1 ( layer_priority1 ),
        .layer_priority2 ( layer_priority2 ),
        .layer_priority3 ( layer_priority3 ),
        .input_enables   ( input_enables ),
        .object_palette_base( object_palette_base ),
        .roz_palette_base(roz_palette_base), .roz_priority(roz_priority),
        .unused_sub2_priority(sub2_priority), .roz_mix(roz_mix),
        .state_addr(cpu_byte_addr[7:1]), .state_data(unused_k055555_state_data)
    );
    // Gaiapolis' CCU image opens 385 columns (H=106..490). MAME and the
    // platform geometry show 376 (bitmap x40..415), so the trailing nine
    // columns are blanked for output only. Renderers keep the native counters.
    wire video_lhbl = k053252_lhbl && (monster_48 || k053252_hpos < 9'd482);
    // The clk48 enable is held for two SDRAM clocks. Capture its rising
    // edge once, after the previous pixel's buffered candidates have settled.
    reg colour_cen_q;
    wire colour_capture = cen_pixel && !colour_cen_q;
    wire video_pixel_valid, video_pipeline_busy, video_deadline_overrun;
    wire unused_video_palette_read;
    wire colour_hs, colour_vs, colour_hblank, colour_vblank;
    reg [7:0] video_pxl2_delay;
    always @(posedge clk) begin
        if (rst48) begin
            colour_cen_q <= 1'b0;
            video_pxl2_delay <= 8'd0;
        end else begin
            colour_cen_q <= cen_pixel;
            video_pxl2_delay <= {video_pxl2_delay[6:0],video_pixel_valid};
        end
    end
    // RGB and metadata publish together at capture+29 clk96 cycles.
    // The doubled cadence repeats the same pixel halfway to the next one.
    // jtframe_reset releases game_rst only on pxl_cen. The colour pipeline is
    // held in that same reset, so while in reset fall back to the free-running
    // pixel enable or the reset can never end (no video after boot).
    wire reset_pxl_cen = rst48 && cen_pixel;
    assign pxl_cen = video_pixel_valid || reset_pxl_cen;
    assign pxl2_cen = pxl_cen || (monster_48 ? video_pxl2_delay[7] : video_pxl2_delay[5]);
    gaiapolis_color_pipeline u_colour(
        .monster(monster_48),
        .sprite_mix(sprite_mix),
        .clk                ( clk ),
        .rst                ( rst48 ),
        .cen_pxl            ( colour_capture ),
        .we                 ( k054338_we ),
        .addr               ( cpu_byte_addr[4:1] ),
        .dsn                ( dev_dsn ),
        .din                ( dev_dout ),
        .input_enables      ( input_enables[5:0] ),
        .layer_priority0    ( layer_priority0 ),
        .layer_priority1    ( layer_priority1 ),
        .layer_priority2    ( layer_priority2 ),
        .layer_priority3    ( layer_priority3 ),
        .layer_palette0     ( layer_palette0 ),
        .layer_palette1     ( layer_palette1 ),
        .layer_palette2     ( layer_palette2 ),
        .layer_palette3     ( layer_palette3 ),
        .lyrf_pxl           ( lyrf_pxl ),
        .lyra_pxl           ( lyra_pxl ),
        .lyrb_pxl           ( lyrb_pxl ),
        .lyrc_pxl           ( lyrc_pxl ),
        .lyrf_mix           ( lyrf_mix ),
        .lyra_mix           ( lyra_mix ),
        .lyrb_mix           ( lyrb_mix ),
        .lyrc_mix           ( lyrc_mix ),
        .tile_blend         ( tile_blend ),
        .tile_blend_on      ( tile_blend_on ),
        .brightness_code    ( brightness_code ),
        .osbri_code         ( osbri_code[3:0] ),
        .sprite_pixel       ( sprite_pixel ),
        .sprite_order       ( sprite_order ),
        .shadow_ops_valid   ( sprite_shadow_ops_valid ),
        .shadow_ops_mode    ( sprite_shadow_ops_mode ),
        .shadow_ops_order   ( sprite_shadow_ops_order ),
        .object_palette_base( object_palette_base ),
        .roz_palette_base   ( roz_palette_base ),
        .roz_priority       ( roz_priority ),
        .unused_sub2_priority( sub2_priority ),
        .roz_palette        ( roz_palette ),
        .roz_pen            ( roz_pen ),
        .roz_pen8           ( roz_pen8 ),
        .roz_valid          ( roz_pixel_valid ),
        .roz_mix            ( roz_mix ),
        .hs_in              ( k053252_hs ),
        .vs_in              ( k053252_vs ),
        .hblank_in          ( !video_lhbl ),
        .vblank_in          ( !k053252_lvbl ),
        .palette_index      ( palette_index ),
        .palette_read       ( unused_video_palette_read ),
        .palette_rgb        ( {palh_dout[7:0],pall_dout} ),
        .transparent_mixes  ( unused_transparent_mixes ),
        .red                ( colour_r ),
        .green              ( colour_g ),
        .blue               ( colour_b ),
        .pixel_valid        ( video_pixel_valid ),
        .busy               ( video_pipeline_busy ),
        .deadline_overrun   ( video_deadline_overrun ),
        .hs_out             ( colour_hs ),
        .vs_out             ( colour_vs ),
        .hblank_out         ( colour_hblank ),
        .vblank_out         ( colour_vblank )
    );
    gaiapolis_sound u_sound(
        .rst        ( rst_main ),
        .clk        ( clk48 ),
        .cen_8      ( cen_8 ),
        .cen_pcm    ( cen_pcm ),
        .pause_cpu_run(pause_sound_ce_run), .pause_busrq_n(pause_sound_busrq_n),
        .pause_quiesce(pause_pcm_quiesce), .pause_freeze(gameplay_freeze),
        .pause_busak_n(pause_sound_busak_n), .pause_mreq_n(pause_sound_mreq_n),
        .pause_iorq_n(pause_sound_iorq_n), .pause_rd_n(pause_sound_rd_n),
        .pause_wr_n(pause_sound_wr_n), .pause_pending(pause_sound_pending),
        .pause_pcm_idle(pause_pcm_idle),
        .main_we    ( k054321_we ),
        .main_addr  ( cpu_byte_addr[4:1] ),
        .main_din   ( dev_dout[15:8] ),
        .main_dout  ( k054321_dout ),
        .snd_irq    ( sound_irq_we ),
        .irq_n      ( k054321_irq_n ),
        .active     ( k054321_active ),
        .volume     ( k054321_volume ),
        .snd_addr   ( snd_addr ),
        .snd_cs     ( snd_cs ),
        .snd_data   ( snd_data_96q ),
        .snd_ok     ( snd_ok_96q ),
        .pcma_addr  ( pcma_addr ),
        .pcma_cs    ( pcma_cs ),
        .pcma_data  ( pcma_data_96q ),
        .pcma_ok    ( pcma_ok_96q ),
        .pcmb_addr  ( pcmb_addr ),
        .pcmb_cs    ( pcmb_cs ),
        .pcmb_data  ( pcmb_data_96q ),
        .pcmb_ok    ( pcmb_ok_96q ),
        .pcm0_l     ( pcm0_l ),
        .pcm0_r     ( pcm0_r ),
        .pcm1_l     ( pcm1_l ),
        .pcm1_r     ( pcm1_r ),
        .debug_bus  ( debug_bus ),
        .st_dout    ( sound_st_dout ),
        .mute       ( gameplay_freeze )
    );
    gaiapolis_k056832 u_k056832(
        .monster(monster_48),
        .clk            ( clk48 ),
        .rst            ( rst_main ),
        .reg_cs         ( k056832_reg_cs ),
        .b_cs           ( k056832_b_cs ),
        .vram_cs        ( cs_vram && dev_bus_active ),
        .romrd_cs       ( cs_tile_read && dev_bus_active ),
        .cpu_we         ( k056832_we ||
                          (cs_vram && dev_bus_active && !dev_rnw) ),
        .cpu_rnw        ( dev_rnw ),
        .reg_addr       ( cpu_byte_addr[5:1] ),
        .b_addr         ( cpu_byte_addr[2:1] ),
        .vram_cpu_addr  ( dev_a[12:1] ),
        .rom_cpu_addr   ( dev_a[13:1] ),
        .cpu_din        ( dev_dout ),
        .cpu_dsn        ( dev_dsn ),
        .cpu_dout       ( k056832_dout ),
        .vram_addr      ( k056832_vram_addr ),
        .vram_we        ( k056832_vram_we ),
        .vram_dout      ( vram_cpu_dout ),
        .tile_cs        ( k056832_tile_cs ),
        .tile_addr      ( k056832_tile_addr ),
        .tile_data      ( base_tile_data ),
        .tile_ok        ( base_tile_ok ),
        .tile_wait      ( k056832_tile_wait ),
        .selected_page  ( k056832_selected_page ),
        .rom_bank       ( k056832_rom_bank ),
        .mode_5bpp      ( k056832_mode_5bpp ),
        .layer_page0    ( k056832_page0 ),
        .layer_page1    ( k056832_page1 ),
        .layer_page2    ( k056832_page2 ),
        .layer_page3    ( k056832_page3 ),
        .layer_dx0      ( k056832_dx0 ),
        .layer_dx1      ( k056832_dx1 ),
        .layer_dx2      ( k056832_dx2 ),
        .layer_dx3      ( k056832_dx3 ),
        .layer_dy0      ( k056832_dy0 ),
        .layer_dy1      ( k056832_dy1 ),
        .layer_dy2      ( k056832_dy2 ),
        .layer_dy3      ( k056832_dy3 ),
        .layer_flip0    ( k056832_flip0 ),
        .layer_flip1    ( k056832_flip1 ),
        .layer_flip2    ( k056832_flip2 ),
        .layer_flip3    ( k056832_flip3 ),
        .gflip_x        ( k056832_gflip_x ),
        .gflip_y        ( k056832_gflip_y ),
        .corr_x         ( k056832_corr_x ),
        .corr_y         ( k056832_corr_y ),
        .config_regs    ( k056832_config_regs )
    );
    jtviostorm_k053252 u_k053252(
        .rst   ( rst48 ),
        .clk   ( clk48 ),
        .cen   ( cen_pixel ),
        .monster( monster_48 ),
        .cs    ( cs_k053252 && dev_bus_active ),
        .rnw   ( dev_rnw ),
        .addr  ( cpu_byte_addr[4:1] ),
        .dsn   ( dev_dsn ),
        .din   ( dev_dout ),
        .dout  ( k053252_dout ),
        .lhbl  ( k053252_lhbl ),
        .lvbl  ( k053252_lvbl ),
        .hs    ( k053252_hs ),
        .vs    ( k053252_vs ),
        .int1  ( k053252_int1 ),
        .int2  ( k053252_int2 ),
        .hpos  ( k053252_hpos ),
        .vpos  ( k053252_vpos )
    );

    gaiapolis_k056832_video u_k056832_video(
        .monster(monster_48),
        .rst       ( rst_main ),
        .clk       ( clk48 ),
        .pxl_cen   ( cen_pixel ),
        .hpos      ( k053252_hpos ),
        .vpos      ( k053252_vpos ),
        .lhbl      ( k053252_lhbl ),
        .lvbl      ( k053252_lvbl ),
        .hs        ( k053252_hs ),
        .vs        ( k053252_vs ),
        .gfx_en    ( gfx_en ),
        .layer_en  ( input_enables[3:0] ),
        .page0     ( k056832_page0 ),
        .page1     ( k056832_page1 ),
        .page2     ( k056832_page2 ),
        .page3     ( k056832_page3 ),
        .dx0       ( k056832_dx0 ),
        .dx1       ( k056832_dx1 ),
        .dx2       ( k056832_dx2 ),
        .dx3       ( k056832_dx3 ),
        .dy0       ( k056832_dy0 ),
        .dy1       ( k056832_dy1 ),
        .dy2       ( k056832_dy2 ),
        .dy3       ( k056832_dy3 ),
        .flip0     ( k056832_flip0 ),
        .flip1     ( k056832_flip1 ),
        .flip2     ( k056832_flip2 ),
        .flip3     ( k056832_flip3 ),
        .gflip_x   ( k056832_gflip_x ),
        .gflip_y   ( k056832_gflip_y ),
        .corr_x    ( k056832_corr_x ),
        .corr_y    ( k056832_corr_y ),
        .rom_bank  ( k056832_rom_bank ),
        .config_regs ( k056832_config_regs ),
        .vram_addr ( video_vram_addr ),
        .vram_dout ( vram_dout ),
        .tile_cs   ( video_tile_cs ),
        .tile_addr ( video_tile_addr ),
        .tile_data ( base_tile_data ),
        .tile_ok   ( base_tile_ok && !k056832_tile_cs ),
        .lyrf_pxl  ( lyrf_pxl ),
        .lyra_pxl  ( lyra_pxl ),
        .lyrb_pxl  ( lyrb_pxl ),
        .lyrc_pxl  ( lyrc_pxl ),
        .lyrf_mix  ( lyrf_mix ),
        .lyra_mix  ( lyra_mix ),
        .lyrb_mix  ( lyrb_mix ),
        .lyrc_mix  ( lyrc_mix )
    );

    gaiapolis_k055673 u_k055673(
        .monster(monster_48),
        .sprite_mix(sprite_mix),
        .cpu_rom_ready(sprite_cpu_rom_ready),
        .sprite5_addr(sprite5_addr),.sprite5_cs(sprite5_cs),
        .sprite5_data(sprite5_data),.sprite5_ok(sprite5_ok),
        .rst        ( rst_main ),
        .clk        ( clk48 ),
        .pxl_cen    ( cen_pixel ),
        .pxl2_cen   ( cen_pixel ),
        .hpos       ( k053252_hpos ),
        .vpos       ( k053252_vpos ),
        .lhbl       ( k053252_lhbl ),
        .lvbl       ( k053252_lvbl ),
        .hs         ( k053252_hs ),
        .obj_cs     ( sprite_obj_cs ),
        .obj_we     ( sprite_obj_we ),
        .obj_addr   ( {1'b0,sprite_chip_addr} ),
        .obj_din    ( dev_dout ),
        .obj_dsn    ( dev_dsn ),
        .obj_dout   ( sprite_cpu_dout ),
        .reg_cs     ( sprite_mmr_cs ),
        .reg_we     ( sprite_mmr_cs && !dev_rnw ),
        .reg_addr   ( cpu_byte_addr[3:0] ),
        .reg_din    ( dev_dout ),
        .reg_dsn    ( dev_dsn ),
        .objset2_cs ( sprite_objset2_cs ),
        .objset2_we ( sprite_objset2_we ),
        .objset2_addr( cpu_byte_addr[3:1] ),
        .objset2_din( dev_dout ),
        .objset2_dsn( dev_dsn ),
        .rom_addr   ( sprite_rom_addr ),
        .rom_cs     ( sprite_rom_cs ),
        .rom_data   ( obj_data_48q ),
        .rom_ok     ( obj_ok_48q ),
        .objcha_n   ( sprite_objcha_n ),
        .rom_read_offset( cpu_byte_addr[3:1] ),
        .shadow_priority1(shadow_priority1), .shadow_priority2(shadow_priority2), .shadow_priority3(shadow_priority3),
        .shadow_priority_full(unused_sprite_shadow_priority_full),
        .solid_order(sprite_order), .shadow_order(unused_sprite_shadow_order),
        .shadow_ops_valid(sprite_shadow_ops_valid), .shadow_ops_mode(sprite_shadow_ops_mode),
        .shadow_ops_order(sprite_shadow_ops_order), .shadow_ops_overflow(sprite_shadow_ops_overflow),
        .line_overrun(sprite_line_overrun),
        .shadow     ( unused_sprite_shadow ),
        .shadow_prio( unused_sprite_shadow_prio ),
        .prio       ( unused_sprite_priority ),
        .pixel      ( sprite_pixel ),
        .dma_irq_enabled( sprite_dma_enabled ),
        .dma_busy   ( sprite_dma_busy ),
        .ln_done    ( sprite_ln_done )
    );


    always @* begin
        bus_din = 16'hffff;
        if (prot_cs && !prot_req) bus_din = prot_q;
        else if (cs_main) bus_din = main_data_96q;
        else if (cs_ram) bus_din = ram_data;
        else if (cs_obj) bus_din = sprite_chip_sel ? sprite_cpu_dout : scatter_dout;
        else if (sprite_cpu_rom_read) bus_din = sprite_cpu_dout;
        else if (cs_vram || cs_tile_read) bus_din = k056832_dout;
        else if (cs_palette) bus_din = dev_a[1] ? cpall_dout : cpalh_dout;
        else if (cs_k053252) bus_din = {8'hff,k053252_dout};
        else if (cs_k054321) bus_din = {k054321_dout,8'hff};
        else if (cs_collision) bus_din = {8'hff,collision_dout};
        else if (cs_inputs) bus_din = {io_in0,io_p1};
        else if (in1_rd) bus_din = {io_in1,8'h00};
        else if (p2_rd) bus_din = {8'h00,io_p2};
        else if (cs_roz_line || cs_roz_map0 || cs_roz_map1 || cs_roz_tiles)
            bus_din = roz_cpu_dout;
    end
    always @(posedge clk48) begin
        if (rst_main) cpu_din_r <= 16'hffff;
        else cpu_din_r <= bus_din;
    end
    assign cpu_din = cpu_din_r;
    assign bus_cs = cs_any || prot_cs;
    assign device_busy = (main_cs && !main_ok_dly) ||
        (cs_ram && !ram_ok) || (cs_obj && !scatter_ready) ||
        (sprite_cpu_rom_read && !sprite_cpu_rom_ready) ||
        (cs_tile_read && k056832_tile_wait) ||
        (cs_collision && bus_rd && dev_a[5:1] == 5'h18 && !collision_ready) ||
        ((cs_roz_map0 || cs_roz_map1 || cs_roz_tiles) && !roz_cpu_ready);
    jtframe_okdly u_main_okdly(
        .rst(rst_main), .clk(clk48), .cs(main_cs), .ok(main_ok_96q), .ok_dly(main_ok_dly)
    );
    wire [15:0] dtack_fave, dtack_fworst;
    jtframe_68kdtack_cen #(.W(6),.RECOVERY(1),.MFREQ(48000)) u_dtack(
        .rst(rst_main), .clk(clk48), .cpu_cen(cpu_cen), .cpu_cenb(cpu_cenb),
        .bus_cs(bus_cs), .bus_busy(bus_busy), .bus_legit(1'b0), .bus_ack(1'b0),
        .ASn(cpu_asn), .DSn(cpu_dsn), .num(5'd1), .den(6'd3),
        .wait2(1'b0), .wait3(1'b0), .DTACKn(bus_dtack_n),
        .fave(dtack_fave), .fworst(dtack_fworst)
    );
    assign bus_busy=device_busy || prot_busy || (prot_cs && !prot_ready);
    assign cpu_dtack_n = bus_dtack_n;
    jtframe_m68k u_cpu(
        .clk     ( clk48 ),
        .rst     ( rst_main ),
        .cpu_cen ( cpu_cen && pause_main_ce_run ),
        .cpu_cenb( cpu_cenb && pause_main_ce_run ),
        .BERRn   ( 1'b1 ),
        .VPAn    ( cpu_vpa_n ),
        .BGACKn  ( 1'b1 ),
        .HALTn   ( pause_main_halt_n & ~rst_main ),
        .RESETn  ( cpu_reset_n ),
        .eab     ( cpu_a ),
        .ASn     ( cpu_asn ),
        .LDSn    ( cpu_lds_n ),
        .UDSn    ( cpu_uds_n ),
        .eRWn    ( cpu_rnw ),
        .DTACKn  ( cpu_dtack_n ),
        .iEdb    ( cpu_din ),
        .oEdb    ( cpu_dout_i ),
        .BRn     ( 1'b1 ),
        .BGn     ( cpu_bg_n ),
        .IPLn    ( cpu_ipln ),
        .FC      ( cpu_fc )
    );
    assign red = colour_r;
    assign green = colour_g;
    assign blue = colour_b;
    assign LHBL = !colour_hblank;
    assign LVBL = !colour_vblank;
    assign HS = colour_hs;
    assign VS = colour_vs;
    // Active-low SW2. The game already controls native geometry through its
    // K056832 writes; this normalized sideband serves platform presentation.
    assign dip_flip = ~dipsw[5];
    assign debug_view = {pause_boundary_fault,pause_ack,irq5_latched,collision_ready,priority_code[3:0]};
    assign ioctl_din = 8'h00;
endmodule
