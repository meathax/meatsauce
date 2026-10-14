/*
 * Metamorphic Force K055673 integration boundary.
 *
 * The scanner/drawer behind this boundary is the GPL JTCORES Simson
 * K053246/K053247 implementation. The donor is preserved under
 * hdl/donor_k055673/. The wrapper supplies the Metamorphic Force map,
 * K055673 RNG 4-bpp configuration, native K053252 counters and the JTFRAME
 * object-ROM port.
 * MAME's eight-word object format and RNG layout remain the reference contract;
 * coordinate and packed-ROM timing differences are intentionally exposed as
 * evidence items rather than hidden in a presentation offset.
 */
module jtviostorm_k055673(
    input             rst,
    input             clk,
    input             pxl_cen,
    input             pxl2_cen,

    // Native K053252 counters; translate them into the GX sprite bitmap
    // coordinate system below, before the line-buffer readout.
    input      [ 8:0] hpos,
    input      [ 8:0] vpos,
    input             lhbl,
    input             lvbl,
    input             hs,

    // K053247 object RAM at 0x210000-0x210fff.
    input             obj_cs,
    input             obj_we,
    input      [12:1] obj_addr,
    input      [15:0] obj_din,
    input      [ 1:0] obj_dsn,
    output     [15:0] obj_dout,

    // K053246/OBJSET1 register window at 0x240000-0x240007 and
    // K055673/OBJSET2 window at 0x240010-0x24001f.
    input             reg_cs,
    input             reg_we,
    input      [ 3:0] reg_addr,
    input      [15:0] reg_din,
    input      [ 1:0] reg_dsn,

    // OBJSET2 (0x244010-0x24401f) is write-only on the board. Keep all
    // eight physical words and byte lanes. Register 6 bit 4 is verified by
    // MAME as OPSET PRI and is consumed below to reverse K055673 Z sorting;
    // other title-unused/unknown GX fields remain stored without invented use.
    input             objset2_cs,
    input             objset2_we,
    input      [ 2:0] objset2_addr,
    input      [15:0] objset2_din,
    input      [ 1:0] objset2_dsn,

    // Shared 32-bit packed sprite ROM port.
    output     [22:2] rom_addr,
    output            rom_cs,
    input      [31:0] rom_data,
    input             rom_ok,

    // The real OBJCHA line is a title-programmed register bit. Keep it
    // asserted for the normal renderer path; CPU ROM readback is still
    // exposed through the separate control/readback contract below.
    input             objcha_n,
    input      [ 2:0] rom_read_offset,

    output     [ 1:0] shadow,
    output     [ 2:0] shadow_prio,
    output     [ 4:0] prio,
    output     [ 8:0] pixel,
    output            dma_irq_enabled,
    output            dma_busy,
    output            ln_done
);
    logic [15:0] objset2_regs [0:7];
    // OBJSET1 register 5 is the low byte of the third 16-bit register
    // pair.  Keep a project-owned mirror of the documented screen-flip
    // controls so the line-buffer readout can consume bit 0 without
    // changing the imported scanner's register implementation.
    logic [7:0] objset1_cfg;
    integer objset2_i;

    always_ff @(posedge clk) begin
        if (rst) begin
            objset1_cfg <= 8'h00;
            for (objset2_i = 0; objset2_i < 8; objset2_i = objset2_i + 1)
                objset2_regs[objset2_i] <= 16'h0000;
        end else begin
            if (reg_cs && reg_we && (reg_addr[2:1] == 2'd2) && !reg_dsn[0])
                objset1_cfg <= reg_din[7:0];
            if (objset2_cs && objset2_we) begin
                if (!objset2_dsn[1]) objset2_regs[objset2_addr][15:8] <= objset2_din[15:8];
                if (!objset2_dsn[0]) objset2_regs[objset2_addr][7:0]  <= objset2_din[7:0];
            end
        end
    end

    // Metamorphic's active raw HCT208 maps to MAME bitmap x24. The pixel
    // bundle delays RGB/DE together; this is a renderer read address, not an
    // output-image shift. The title line buffer uses natural 9-bit wrap.
    wire [8:0] hdump = hpos - 9'd184;
    wire [8:0] vdump = vpos;
    // HS swaps the line buffers and latches the scanner's current VCT.
    // Visible VCT272 therefore consumes the line scanned at VCT271.
    // MAME's GX path applies oy -= dy before inversion (dy=-24), and its
    // visible bitmap starts at y15. The scanner adds the duplicated VCT
    // top bit: -dy - (271-15) - 512 = -744 = 280 modulo1024.
    wire [9:0] voffset = 10'd280;
    wire [22:2] donor_rom_addr;
    wire        donor_rom_cs;
    wire [15:0] donor_cpu_dout;
    wire [22:1] rmrd_addr;

    // Viostorm selects K055673_LAYOUT_RNG (4bpp). MAME's generic readback
    // aligns the composed address to a four-word block, returns words 2..5
    // for offsets 0..3, and words 0..3 for offsets 4..7. The JTFRAME object
    // port returns two adjacent 16-bit words per 32-bit request.
    wire [20:0] read_romofs = rmrd_addr[21:1];
    wire [20:0] read_base   = {read_romofs[20:2],2'b00};
    wire [21:0] read_word   = rom_read_offset[2] ?
                               ({1'b0,read_base} +
                                {20'd0,rom_read_offset[1:0]}) :
                               ({1'b0,read_base} + 22'd2 +
                                {20'd0,rom_read_offset[1:0]});
    wire [22:2] read_rom_addr = read_word[21:1];
    wire [15:0] read_cpu_dout = read_word[0] ? rom_data[31:16] : rom_data[15:0];

    assign rom_addr = !objcha_n ? read_rom_addr : donor_rom_addr;
    assign rom_cs   = !objcha_n | donor_rom_cs;
    assign obj_dout = !objcha_n ? read_cpu_dout : donor_cpu_dout;

    // The donor's K55673=1 path selects the K055673 descriptor/DMA rules.
    // Metamorphic itself is K055673_LAYOUT_RNG and its pixel drawer is 4bpp;
    // do not confuse K55673 selection with the separate 5bpp layout mode.
    // HOFFSET is kept explicit
    // so a later corpus can change one title-local parameter without altering
    // the shared scanner source.
    jtsimson_obj #(
        .RAMW             (12),
        .PACKED           (0),
        .SHADOW           (1),
        .K55673           (1),
        .K55673_DESC_SORT (1),
        // The chip starts the object DMA by itself in vertical blank while
        // register 5 bit 4 is set. The DMA raises the level-5 interrupt whose
        // handler clears that bit, so an edge-triggered DMA would never start.
        .EDGE_TRIGGER     (0),
        // GX x = (raw_x + dx - offx) modulo1024, then subtract halfwidth.
        // The scanner implements the same addition with dx=-51 encoded973.
        .HOFFSET          (10'd973)
    ) u_obj(
        .rst        (rst),
        .clk        (clk),
        .ln_done    (ln_done),
        .dma_enabled_o(dma_irq_enabled),
        .pxl_cen    (pxl_cen),
        .pxl2_cen   (pxl2_cen),
        .simson     (1'b0),
        .hdump      (hdump),
        .vdump      (vdump),
        .voffset    (voffset),
        .screen_hflip(objset1_cfg[0]),
        .sd0en      (objset1_cfg[5]),
        // MAME OPSET PRI clear makes low raw Z closest. The donor draws
        // ascending sorted slots with the final solid pixel winning, so
        // normal mode requires descending raw Z; OPSET PRI reverses it.
        .k55673_desc_sort(~objset2_regs[6][4]),
        .hs         (hs),
        .lvbl       (lvbl),
        .ram_cs     (obj_cs),
        .reg_cs     (reg_cs),
        .mmr_we     (reg_we),
        .mmr_addr   (reg_addr),
        .mmr_din    (reg_din),
        .mmr_dsn    (reg_dsn),
        .ram_din    (obj_din),
        .ram_we     ({2{obj_we}} & ~obj_dsn),
        .ram_addr   (obj_addr),
        .cpu_din    (donor_cpu_dout),
        .dma_bsy    (dma_busy),
        .rom_addr   (donor_rom_addr),
        .rom_data   (rom_data),
        .rom_cs     (donor_rom_cs),
        .rom_ok     (rom_ok && objcha_n),
        .rmrd_addr_o( rmrd_addr ),
        .objcha_n   (objcha_n),
        .shd        (shadow),
        .shd_prio   (shadow_prio),
        .prio       (prio),
        .pxl        (pixel),
        .gfx_en     (4'hf),
        .ioctl_ram  (1'b0),
        .ioctl_addr (14'd0),
        .dump_ram   (),
        .dump_reg   (),
        .debug_bus  (8'd0)
    );
`ifdef VS_REPLAY
    integer dbg_rom=0, dbg_pix=0, dbg_dma=0, dbg_ram=0; reg dbg_lvbl=0;
    always @(posedge clk) begin
        dbg_lvbl <= lvbl;
        if (donor_rom_cs) dbg_rom <= dbg_rom+1;
        if (pixel!=0 && pxl_cen) dbg_pix <= dbg_pix+1;
        if (dma_busy) dbg_dma <= dbg_dma+1;
        if (obj_cs && obj_we) dbg_ram <= dbg_ram+1;
        if (dbg_lvbl && !lvbl) begin
            $display("SPR rom=%0d pix=%0d dmabusy=%0d ramw=%0d dmairq=%b", dbg_rom, dbg_pix, dbg_dma, dbg_ram, dma_irq_enabled);
            dbg_rom<=0; dbg_pix<=0; dbg_dma<=0; dbg_ram<=0;
        end
    end
`endif
endmodule
