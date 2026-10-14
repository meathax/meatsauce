/*
 * Violent Storm K055673 integration boundary.
 *
 * The scanner/drawer behind this boundary is the GPL JTCORES Simson
 * K053246/K053247 implementation, imported unchanged under
 * hdl/donor_k055673/. The wrapper supplies the Violent Storm map, GX 5-bpp
 * configuration, native K053252 counters and the JTFRAME object-ROM port.
 * MAME's eight-word object format and GX layout remain the reference contract;
 * coordinate and packed-ROM timing differences are intentionally exposed as
 * evidence items rather than hidden in a presentation offset.
 */
module jtviostorm_k055673(
    input             rst,
    input             clk,
    input             pxl_cen,
    input             pxl2_cen,

    // Native K053252 timing. The +0x20 horizontal translation is confirmed
    // (2026-08-18 evidence pass, see ledger): hdump=hpos+32 combined with
    // HOFFSET=10'd962 below reproduces MAME's bitmap-space sprite X position
    // bit-exactly for a live-instrumented sprite. The vertical path is now
    // ALSO confirmed (2026-08-18, ledger "K055673 vertical raster-window
    // fix"): vdump uses vpos directly (no added constant -- the CCU's own
    // raster numbering already matches the scanner's trigger window; the
    // previous +0xF8 pushed the active-display vdump values entirely
    // outside the trigger window, so no sprite could ever be scanned), and
    // voffset=10'd746 supplies the per-title Y additive term (MAME's dy=-23
    // plus the raster/bitmap origin reconciliation), verified bit-exact
    // against a live MAME-instrumented sprite via direct RTL simulation.
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

    // OBJSET2 (0x244010-0x24401f) is write-only on the board. Keep the
    // eight physical words and byte lanes isolated here even though the
    // donor scanner does not yet consume the unresolved GX fields.
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

    wire [8:0] hdump = hpos + 9'd32;
    // vdump: CONFIRMED (2026-08-18, see ledger "K055673 vertical raster-window
    // fix"). Direct Verilator simulation of jtviostorm_k053252 (owned by
    // another agent, read-only here) shows the CCU's vpos counter already
    // spans the raster line numbers jt053246_scan.sv's scan-trigger window
    // expects: vpos==271 the cycle lvbl rises (first active line) through
    // vpos==494 the cycle before lvbl falls, 224 active lines, landing
    // squarely inside the (0x10D,0x1F7]=(269,503] legal trigger window
    // (jtviostorm_jt053246_scan.sv:63-64,192). The previous `vpos+9'h0f8`
    // pushed every active-display vdump value to (vpos+248) mod 512 =
    // [7,230], entirely OUTSIDE the trigger window -- the scan-start
    // condition `vdump>9'h10D && vdump<=BOTTOM` could then never fire during
    // active video, so sprites could not be latched/drawn on ANY line. This
    // was the root cause of "sprites do not render". Removing the added
    // constant (vdump=vpos) restores the trigger for the full 224-line
    // active window with no invented constant -- vpos's own raster numbering
    // already matches the donor scanner's expected window.
    wire [8:0] vdump = vpos;
    // voffset: CONFIRMED (2026-08-18, see ledger). Plays the Y-axis role of
    // HOFFSET: the per-title additive term the scan module's y-pipeline
    // (jtviostorm_jt053246_scan.sv:100,131) needs so that its top-of-sprite
    // raster value lines up with MAME's non-GX
    // k053247_draw_single_sprite_gxcore() vertical transfer function
    // (k053246_k053247_k055673.h:200,212,223,228) evaluated on the same
    // live-captured sprite (offy=635, oy_raw=186, dy=-23, height=32px,
    // zoomy unzoomed): oy=(-186-635)&1023=203; oy-=dy(-23)->226;
    // oy-=(zoomy*height)>>13(16)->oy_final=210 (bitmap space, MAME
    // visarea top=16, mystwarr.cpp:1039). Direct RTL simulation of
    // jtviostorm_k053252 (2026-08-18, tb_viostorm_ccu_probe.sv) shows
    // bitmap row 16 corresponds to vpos=271 (first active line), so the
    // target admission raster is vpos=210+(271-16)=465. The scan module's
    // zone-test compares `y2 + {vlatch[8],vlatch}` (jtviostorm_jt053246_scan.sv:
    // 73,103,144-147) -- for any legal-window vlatch (always >=270, so
    // vlatch[8]=1) this duplicated top bit adds a constant +512, i.e. the
    // admission condition is really `y2 + vlatch + 512 == 0 (mod 1024)`, so
    // the required y2 for vlatch=465 is `512-465=47` (NOT `1024-465`).
    // Direct RTL simulation confirms the sprite's own y2 without voffset is
    // oy_raw+yoffset+ymove=186+635+16=837 (ymove=16 numerically equals
    // MAME's (zoomy*height)>>13 term here, both implementing the same
    // physical K053246 zoom-height hardware, so they cancel and do not
    // enter the general per-title constant). voffset = 47-837 = -790, i.e.
    // dy - (vpos_active_start - visarea_top) - 512 = -23-255-512 = -790,
    // encoded as 10-bit two's complement: 1024-790 = 234 (10'hea).
    wire [9:0] voffset = 10'd234;
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

    // The donor's K55673=1 path selects the ascending descriptor sort and
    // 5-bpp object interface used by the GX layout. HOFFSET is kept explicit
    // so a later corpus can change one title-local parameter without altering
    // the shared scanner source.
    jtsimson_obj #(
        .RAMW             (12),
        .PACKED           (1),
        .SHADOW           (1),
        .K55673           (1),
        .K55673_DESC_SORT (0),
        .EDGE_TRIGGER     (0),
        // HOFFSET plays the algebraic role of MAME's static K055673 dx=-62
        // config constant (mystwarr.cpp:1022, set_config(K055673_LAYOUT_RNG,
        // -62,-23)). jt053246_scan.sv computes x_final = x_raw - xoffset +
        // HOFFSET - halfwidth, term-for-term matching MAME's non-GX
        // k053247_draw_single_sprite_gxcore() (k053246_k053247_k055673.h:
        // ~211-227): ox_final = ((ox_raw - offx) mod 1024, unwrapped) + dx -
        // halfwidth. HOFFSET must therefore encode dx as a 10-bit two's
        // complement quantity: 1024-62 = 962. Confirmed bit-exact against a
        // live MAME instrumented capture (2026-08-18, see ledger): with the
        // live K053246 window register offx=0 (m_kx46_regs[0:1], read via
        // Lua from the ":k055673" device), sprite RAM entry idx=0x00
        // (ox_raw=358, width=4 tiles, zoomx=0x40) gives MAME ox_final=264
        // (bitmap space); the RTL formula with HOFFSET=962 gives the
        // identical 264. The previous 10'd48 (and the donor default 10'd62)
        // are both wrong in magnitude and sign.
        .HOFFSET          (10'd962)
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
        .rom_ok     (rom_ok),
        .rmrd_addr_o( rmrd_addr ),
        .objcha_n   (objcha_n),
        .shd        (shadow),
        .prio       (prio),
        .pxl        (pixel),
        .gfx_en     (4'hf),
        .ioctl_ram  (1'b0),
        .ioctl_addr (14'd0),
        .dump_ram   (),
        .dump_reg   (),
        .debug_bus  (8'd0)
    );
endmodule
