// ESD16 (SWAT Police) core top: 68000 (fx68k) + hedpanic_map memory/IO + sound + line video block.
// Memory map and IO from MAME 0.289 esd16.cpp (hedpanic_map, io_area_eeprom, vid_attr_area), unchanged from the
// verified frame-based bench version (kept in sim/full/esd16_top_bench.sv):
//   0x000000-0x07FFFF  program ROM (SDRAM, DTACK waits for data)
//   0x100000-0x10FFFF  work RAM (64 KB)
//   0x800000-0x800FFF  palette (xRGB_555)
//   0x900000-0x900FFF  sprite RAM (2 KB, mirrored at +0x800)
//   0xA00000-0xA03FFF  layer 0 VRAM (mirror 0x4000); 0xA20000-0xA23FFF layer 1 VRAM
//   0xB00000-0xB0000F  scroll0 x/y, scroll1 x/y, platform x/y, layersize (write-only)
//   0xC00000-0xC0000F  IO: P1_P2, SYSTEM, EEPROM bit, tilemap colour, sound command (0x0D), EEPROM
//   0xD00008           platform_w: writes layer 1 VRAM at platform_x + 0x40*platform_y
// Clocks: clk = clk_sys (98 MHz); CEs come from esd16_cen (68000 16 MHz with SDRAM-stall recovery).
// Video: esd16_video_line owns the 448x260 raster (pixel enable = clk/14, 7 MHz) and the vblank that raises IRQ6.
module esd16_top (
    input              clk,
    input              rst,               // game reset (held during download / SDRAM init)
    input              vrst,              // raster reset (power/PLL only: the raster runs through game reset)
    input              cen_phi1,
    input              cen_phi2,
    input              cen_z80,
    input              cen_ym,
    input              cen_oki,
    input              nmi_tick,
    output             cpu_wait,          // 68000 bus waits for program ROM data (esd16_cen freezes the CE)
    // inputs, active low, MAME swatpolc port layout (idle P1_P2 and SYSTEM 0xFFFF)
    input       [15:0] in_p1p2_n,
    input       [15:0] in_system_n,
    // 68000 program ROM (esd16_sdram bank 0 reader). Data is the SDRAM word {odd byte, even byte}.
    output             cpu_rom_en,
    output      [18:1] cpu_rom_addr,
    input       [15:0] cpu_rom_data,
    input              cpu_rom_ok,
    // sound ROMs
    output      [17:0] zrom_addr,
    input        [7:0] zrom_data,
    input              zrom_ok,
    output      [17:0] orom_addr,
    input        [7:0] orom_data,
    input              orom_ok,
    // video ROM channels (esd16_video_line: pipelined req/ready, in-order valid), tiles and sprites in parallel
    output             bgrom_req,
    output      [20:0] bgrom_addr,
    input              bgrom_ready,
    input              bgrom_valid,
    input       [31:0] bgrom_data,
    output             sprom_req,
    output      [20:0] sprom_addr,
    input              sprom_ready,
    input              sprom_valid,
    input       [31:0] sprom_data,
    output             sprom2_req,        // second sprite lane (sprite ROM copy in SDRAM bank 3)
    output      [20:0] sprom2_addr,
    input              sprom2_ready,
    input              sprom2_valid,
    input       [31:0] sprom2_data,
    // video out
    output       [7:0] vid_r, vid_g, vid_b,
    output             vid_ce,
    output             vid_hs, vid_vs, vid_hb, vid_vb,
    output             vid_line_overrun,
    input              user_flip,         // OSD 180-degree rotation, XORed with the game's flip bit
    // EEPROM image (NVRAM) host port
    input        [5:0] nv_addr,
    input              nv_wr,
    input       [15:0] nv_din,
    output      [15:0] nv_dout,
    output             nv_changed,
    output signed [15:0] snd
);
    // ---------------- 68000 ----------------
    wire        eRWn, ASn, LDSn, UDSn, FC0, FC1, FC2, BGn, oRESETn, oHALTEDn, VMAn, E;
    wire [15:0] oEdb;
    wire [23:1] eab;
    reg  [15:0] cpu_din;
    reg         dtack_n;
    wire        vpa_n;
    wire  [2:0] fc = {FC2, FC1, FC0};
    reg  [2:0]  ipl_n = 3'b111;
    reg         irq_pending = 1'b0;
    wire        iack = (fc == 3'b111) && !ASn;
    assign vpa_n = iack ? 1'b0 : 1'b1;             // autovector (level 6 = vblank)

    fx68k u_cpu (
        .clk(clk), .HALTn(1'b1), .extReset(rst), .pwrUp(rst),
        .enPhi1(cen_phi1), .enPhi2(cen_phi2),
        .eRWn(eRWn), .ASn(ASn), .LDSn(LDSn), .UDSn(UDSn),
        .E(E), .VMAn(VMAn), .FC0(FC0), .FC1(FC1), .FC2(FC2),
        .BGn(BGn), .oRESETn(oRESETn), .oHALTEDn(oHALTEDn),
        .DTACKn(dtack_n), .VPAn(vpa_n), .BERRn(1'b1), .BRn(1'b1), .BGACKn(1'b1),
        .IPL0n(ipl_n[0]), .IPL1n(ipl_n[1]), .IPL2n(ipl_n[2]),
        .iEdb(cpu_din), .oEdb(oEdb), .eab(eab)
    );
    wire [23:0] addr = {eab, 1'b0};

    wire sel_rom  = (addr[23:19] == 5'd0);
    wire sel_wram = (addr[23:16] == 8'h10);
    wire sel_pal  = (addr[23:12] == 12'h800);
    wire sel_spr  = (addr[23:12] == 12'h900);
    wire sel_v0   = (addr[23:16] == 8'hA0) || (addr[23:16] == 8'hA1);
    wire sel_v1   = (addr[23:16] == 8'hA2) || (addr[23:16] == 8'hA3);
    wire sel_attr = (addr[23:16] == 8'hB0);
    wire sel_io   = (addr[23:16] == 8'hC0);
    wire sel_plat = (addr[23:0]  == 24'hD00008);

    // program ROM: read bus cycles wait (DTACK withheld, CE frozen) until the SDRAM cache has the word
    assign cpu_rom_en   = !ASn && eRWn && sel_rom;
    assign cpu_rom_addr = addr[18:1];
    wire   rom_stall    = cpu_rom_en && !cpu_rom_ok;
    assign cpu_wait     = rom_stall;
    always @* dtack_n = ASn | rom_stall;
    wire [15:0] rom_word = {cpu_rom_data[7:0], cpu_rom_data[15:8]};   // 68000 big endian: even byte high

    // ---------------- memories ----------------
    reg [15:0] attr [0:15];             // 0xB00000 (word index addr[4:1])
    wire  [7:0] tilemap0_color;          // 0xC00008 MAME color/flip register
    wire       eep_do;
    reg        eep_wr = 1'b0;
    reg  [2:0] eep_lines = 3'd0;
    reg        snd_wr = 1'b0;
    reg  [7:0] snd_data = 8'd0;

    wire  [1:0] be         = {~UDSn, ~LDSn};
    // AS/DTACK may precede the data strobes. Commit the first valid write,
    // and require idle AS after reset before accepting a fresh transaction.
    reg         cpu_wr_seen = 1'b1;
    wire        cpu_wr_cyc = !rst && cen_phi2 && !ASn && !eRWn && (|be) && !cpu_wr_seen;
    always @(posedge clk) begin
        if (rst) cpu_wr_seen <= 1'b1;
        else if (ASn) cpu_wr_seen <= 1'b0;
        else if (cpu_wr_cyc) cpu_wr_seen <= 1'b1;
    end
    wire [15:0] plat_off   = attr[4] + 16'd64 * attr[5];

    // MAME tilemap0_color_w takes the color and global flip from C00008.
    esd16_video_control u_video_control (
        .clk(clk), .rst(rst), .cpu_wr_cyc(cpu_wr_cyc), .address(addr),
        .low_byte_write(!LDSn), .data(oEdb), .tilemap0_color(tilemap0_color)
    );

    wire [15:0] wram_q, pal_q_cpu, spr_q_cpu, v0_q_cpu, v1_q_cpu;
    wire [12:0] vram0_addr, vram1_addr;
    wire  [9:0] sram_addr, sram2_addr;
    wire [10:0] pal_addr;
    wire [15:0] vram0_q, vram1_q, sram_q, sram2_q, pal_q;

    esd16_ram16 #(.AW(15)) u_wram (
        .clk(clk), .a_addr(addr[15:1]), .a_din(oEdb), .a_be(be), .a_we(cpu_wr_cyc && sel_wram), .a_q(wram_q),
        .b_addr(15'd0), .b_q());
    esd16_ram16 #(.AW(11)) u_pal (
        .clk(clk), .a_addr(addr[11:1]), .a_din(oEdb), .a_be(be), .a_we(cpu_wr_cyc && sel_pal), .a_q(pal_q_cpu),
        .b_addr(pal_addr), .b_q(pal_q));
    esd16_ram16 #(.AW(10)) u_spr (
        .clk(clk), .a_addr(addr[10:1]), .a_din(oEdb), .a_be(be), .a_we(cpu_wr_cyc && sel_spr), .a_q(spr_q_cpu),
        .b_addr(sram_addr), .b_q(sram_q));
    // Second copy of sprite RAM, written identically, gives the second sprite lane its own read port.
    esd16_ram16 #(.AW(10)) u_spr2 (
        .clk(clk), .a_addr(addr[10:1]), .a_din(oEdb), .a_be(be), .a_we(cpu_wr_cyc && sel_spr), .a_q(),
        .b_addr(sram2_addr), .b_q(sram2_q));
    esd16_ram16 #(.AW(13)) u_vram0 (
        .clk(clk), .a_addr(addr[13:1]), .a_din(oEdb), .a_be(be), .a_we(cpu_wr_cyc && sel_v0), .a_q(v0_q_cpu),
        .b_addr(vram0_addr), .b_q(vram0_q));
    esd16_ram16 #(.AW(13)) u_vram1 (
        .clk(clk),
        .a_addr(sel_plat ? plat_off[12:0] : addr[13:1]), .a_din(oEdb), .a_be(sel_plat ? 2'b11 : be),
        .a_we(cpu_wr_cyc && (sel_v1 || sel_plat)), .a_q(v1_q_cpu),
        .b_addr(vram1_addr), .b_q(vram1_q));

    // IO reads (EEPROM bit 7 of the even byte at 0xC00006)
    always @* begin
        cpu_din = 16'hFFFF;
        if (!ASn && eRWn) begin
            if (sel_rom)       cpu_din = rom_word;
            else if (sel_wram) cpu_din = wram_q;
            else if (sel_pal)  cpu_din = pal_q_cpu;
            else if (sel_spr)  cpu_din = spr_q_cpu;
            else if (sel_v0)   cpu_din = v0_q_cpu;
            else if (sel_v1)   cpu_din = v1_q_cpu;
            else if (sel_io) begin
                case (addr[7:1])
                    7'h01: cpu_din = in_p1p2_n;              // P1_P2
                    7'h02: cpu_din = in_system_n;            // SYSTEM
                    7'h03: cpu_din = {eep_do, 15'h0000};     // EEPROM DO in bit 7 of the even byte (0xC00006)
                    default: cpu_din = 16'h0000;
                endcase
            end
        end
    end

    // Register writes, sampled at phi2 of the bus cycle
    always @(posedge clk) begin
        snd_wr <= 1'b0;
        eep_wr <= 1'b0;
        if (cpu_wr_cyc) begin
            if (sel_attr) attr[addr[4:1]] <= oEdb;
            if (sel_io && addr[7:1] == 7'h07) begin                   // 0xC0000E/F EEPROM lines
                eep_lines <= (!LDSn ? oEdb[2:0] : oEdb[10:8]);
                eep_wr    <= 1'b1;
            end
            if (sel_io && addr[7:1] == 7'h06 && !LDSn) begin           // 0xC0000D (byte)
                snd_data <= oEdb[7:0];
                snd_wr   <= 1'b1;
            end
        end
    end

    // vblank interrupt (level 6, held until IACK); vblank comes from the video raster
    reg vb_d = 1'b0;
    always @(posedge clk) begin
        vb_d <= vid_vb;
        if (rst) irq_pending <= 1'b0;
        else begin
            if (vid_vb && !vb_d) irq_pending <= 1'b1;
            if (iack && cen_phi2) irq_pending <= 1'b0;
        end
    end
    always @* ipl_n = irq_pending ? 3'b001 : 3'b111;

    esd16_eeprom u_eep (
        .clk(clk), .wr(eep_wr), .cs_i(eep_lines[0]), .clk_i(eep_lines[1]), .di_i(eep_lines[2]), .do_o(eep_do),
        .h_addr(nv_addr), .h_wr(nv_wr), .h_din(nv_din), .h_dout(nv_dout), .wr_evt(nv_changed));

    // ---------------- sound ----------------
    esd16_sound u_snd (
        .clk(clk), .rst(rst), .cen_z80(cen_z80), .cen_ym(cen_ym), .cen_oki(cen_oki),
        .nmi_tick(nmi_tick), .cmd_wr(snd_wr), .cmd_data(snd_data),
        .zrom_addr(zrom_addr), .zrom_data(zrom_data), .zrom_ok(zrom_ok),
        .orom_addr(orom_addr), .orom_data(orom_data), .orom_ok(orom_ok),
        .snd(snd)
    );

    // ---------------- video (line based, ROM request/ack channel) ----------------
    // Effective scroll: layer 0 x raw+94, y raw+8; layer 1 x raw+96, y raw+8 (mod 1024)
    wire [15:0] s0x_sum = attr[0] + 16'd94;
    wire [15:0] s0y_sum = attr[1] + 16'd8;
    wire [15:0] s1x_sum = attr[2] + 16'd96;
    wire [15:0] s1y_sum = attr[3] + 16'd8;
    wire [10:0] s0x = {1'b0, s0x_sum[9:0]};
    wire [10:0] s0y = {1'b0, s0y_sum[9:0]};
    wire [10:0] s1x = {1'b0, s1x_sum[9:0]};
    wire [10:0] s1y = {1'b0, s1y_sum[9:0]};

    // MAME frame-number parity for flashing sprites (toggles every vsync)
    reg vs_d = 1'b0, frame_par = 1'b0;
    always @(posedge clk) begin
        vs_d <= vid_vs;
        if (vid_vs && !vs_d) frame_par <= ~frame_par;
    end

    esd16_video_line u_vid (
        .clk(clk), .rst(vrst),
        .cbank0(tilemap0_color[0]), .frame_odd(frame_par),
        .layer_16x16({attr[7][1], attr[7][0]}),
        .flip_screen(tilemap0_color[7] ^ user_flip),
        .scroll0x(s0x), .scroll0y(s0y), .scroll1x(s1x), .scroll1y(s1y),
        .vram0_addr(vram0_addr), .vram0_q(vram0_q),
        .vram1_addr(vram1_addr), .vram1_q(vram1_q),
        .sram_addr(sram_addr), .sram_q(sram_q), .sram2_addr(sram2_addr), .sram2_q(sram2_q),
        .pal_addr(pal_addr), .pal_q(pal_q),
        .bg_rom_req(bgrom_req), .bg_rom_addr(bgrom_addr),
        .bg_rom_ready(bgrom_ready), .bg_rom_valid(bgrom_valid), .bg_rom_data(bgrom_data),
        .sp_rom_req(sprom_req), .sp_rom_addr(sprom_addr),
        .sp_rom_ready(sprom_ready), .sp_rom_valid(sprom_valid), .sp_rom_data(sprom_data),
        .sp2_rom_req(sprom2_req), .sp2_rom_addr(sprom2_addr),
        .sp2_rom_ready(sprom2_ready), .sp2_rom_valid(sprom2_valid), .sp2_rom_data(sprom2_data),
        .r(vid_r), .g(vid_g), .b(vid_b), .ce_pix(vid_ce),
        .hsync(vid_hs), .vsync(vid_vs), .hblank(vid_hb), .vblank(vid_vb),
        .line_overrun(vid_line_overrun), .build_clks_max()
    );
endmodule
