module jtviostorm_game(
    `include "jtframe_game_ports.inc"
);

    wire native_pxl_cen, native_pxl2_cen;
    wire native_pxl_cen_raw, native_pxl2_cen_raw;
    jtframe_frac_cen #(.WC(4),.W(2)) u_native_pixel_cen(
        .clk(clk48), .n(4'd1), .m(4'd4),
        .cen({native_pxl_cen_raw,native_pxl2_cen_raw}), .cenb()
    );
`ifdef VS_REPLAY
    // Simulation-only deterministic-oracle gate. Prefix replay can restore
    // CPU-visible MAME state without advancing the native raster; releasing
    // this gate starts the real 6/12-MHz video pipeline at the chosen frame.
    reg rp_video_en /* verilator public_flat_rw */ = 1'b1;
    assign native_pxl_cen  = native_pxl_cen_raw  & rp_video_en;
    assign native_pxl2_cen = native_pxl2_cen_raw & rp_video_en;
`else
    assign native_pxl_cen  = native_pxl_cen_raw;
    assign native_pxl2_cen = native_pxl2_cen_raw;
`endif

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
    wire [23:0] cpu_byte_addr = {1'b0, cpu_a[22:1], 1'b0};
    wire [ 1:0] cpu_dsn = {cpu_uds_n,cpu_lds_n};
    wire        bus_cs;
    wire        bus_busy;
    wire        bus_dtack_n;
    reg  [15:0] bus_din;
    reg  [15:0] cpu_din_r;
    // Hold the exact SDRAM word that completed the active 68000 ROM request.
    // Physical SDRAM may move main_data again before the delayed DTACK edge;
    // the CPU must see the word associated with main_ok, not a later bus value.
    reg  [15:0] main_data_hold;
    reg         rst_main;
    wire        main_ok_dly;

    // Explicit address decode. The active gate includes AS and byte strobes
    // so an address held during an idle phase cannot create a chip select.
    wire cs_main, cs_ram, cs_obj, cs_extra, cs_sprite_ctl;
    wire cs_scratch, cs_scratch_reg, cs_k054338, cs_k055555, cs_prot;
    wire cs_k053252, cs_sound_irq, cs_k054321, cs_k056832, cs_io;
    wire cs_vram, cs_tile_read, cs_lvc_rom, cs_palette, cs_video, cs_any;
    jtviostorm_decode u_decode(
        .addr           ( cpu_byte_addr ),
        .active         ( cpu_bus_active ),
        .cs_main        ( cs_main ),
        .cs_ram         ( cs_ram ),
        .cs_obj         ( cs_obj ),
        .cs_extra       ( cs_extra ),
        .cs_sprite_ctl  ( cs_sprite_ctl ),
        .cs_scratch     ( cs_scratch ),
        .cs_scratch_reg ( cs_scratch_reg ),
        .cs_k054338     ( cs_k054338 ),
        .cs_k055555     ( cs_k055555 ),
        .cs_prot        ( cs_prot ),
        .cs_k053252     ( cs_k053252 ),
        .cs_sound_irq   ( cs_sound_irq ),
        .cs_k054321     ( cs_k054321 ),
        .cs_k056832     ( cs_k056832 ),
        .cs_io          ( cs_io ),
        .cs_vram        ( cs_vram ),
        .cs_tile_read   ( cs_tile_read ),
        .cs_lvc_rom     ( cs_lvc_rom ),
        .cs_palette     ( cs_palette ),
        .cs_video       ( cs_video ),
        .cs_any         ( cs_any )
    );

    // Metamorphic Force maps 24c000/250000 to the real K053250 below.
    // Violent Storm donor scratch storage is intentionally absent.

    always @(posedge clk48)
        rst_main <= rst48;

    // K055550 bus request/response wires are declared before the memory mux
    // so no implicit nets are created by Verilog's declaration ordering.
    wire [15:0] prot_dout, prot_bus_dout, prot_bus_din;
    wire        prot_dtack, prot_busy, prot_bus_req, prot_bus_ack;
    wire [23:0] prot_bus_addr;
    wire        prot_bus_rnw;
    wire [1:0]  prot_bus_dsn;
    wire k056832_b_cs = cs_k056832 &&
                        (cpu_byte_addr >= 24'h26c000) &&
                        (cpu_byte_addr <= 24'h26c007);
    wire k056832_reg_cs = cs_k056832 &&
                          (cpu_byte_addr >= 24'h270000) &&
                          (cpu_byte_addr <= 24'h27003f);
    wire k056832_we = (k056832_b_cs || k056832_reg_cs) &&
                      cpu_bus_active && !cpu_rnw;
    wire [15:0] k056832_dout;
    wire [17:1] k056832_vram_addr;
    wire [1:0]  k056832_vram_we;
    wire        k056832_tile_cs, k056832_tile_wait;
    wire [21:2] k056832_tile_addr;
    wire [4:0]  k056832_selected_page;
    wire [8:0]  k056832_rom_bank;
    wire        k056832_mode_5bpp;

    // K055673/K053247 object engine. The donor owns its scanline RAM and DMA
    // staging; the wrapper exposes only the verified CPU windows and shared
    // 32-bit sprite-ROM request.
    wire        sprite_obj_cs = cs_obj && cpu_bus_active;
    wire        sprite_obj_we = sprite_obj_cs && !cpu_rnw;
    wire        sprite_mmr_cs = cs_sprite_ctl && cpu_bus_active &&
                                (cpu_byte_addr <= 24'h240007);
    wire        sprite_cpu_rom_read = cs_sprite_ctl && cpu_bus_active &&
                                      cpu_rnw &&
                                      (cpu_byte_addr >= 24'h244000) &&
                                      (cpu_byte_addr <= 24'h24400f);
    wire        sprite_objset2_cs = cs_sprite_ctl && cpu_bus_active &&
                                    (cpu_byte_addr >= 24'h244010) &&
                                    (cpu_byte_addr <= 24'h24401f);
    wire        sprite_objset2_we = sprite_objset2_cs && !cpu_rnw;
    wire [15:0] sprite_cpu_dout;
    wire [22:2] sprite_rom_addr;
    wire        sprite_rom_cs;
    wire        sprite_dma_busy, sprite_ln_done;
    wire [1:0]  sprite_shadow;
    wire [2:0]  sprite_shadow_prio;
    wire [4:0]  sprite_priority;
    wire [8:0]  sprite_pixel;
    // K055673's 0x244000 ROM readback is independent of the normal object
    // renderer. Assert OBJCHA only for that held CPU read cycle; otherwise
    // the scanner remains in its normal pixel-fetch mode.
    wire        sprite_objcha_n = !sprite_cpu_rom_read;

    // CPU-side memory requests. main_addr is also the low-address source for
    // the generated bank-0 RAM slot, matching mem.yaml's physical map.
    // K055550 may own one explicitly decoded writable window while the CPU
    // command cycle is held. Object RAM is a distinct BRAM port and therefore
    // must not be hidden by the bank-0 predicate.
    wire prot_work_req = prot_bus_req &&
                         (prot_bus_addr >= 24'h200000) &&
                         (prot_bus_addr <= 24'h20ffff);
    wire prot_obj_req = prot_bus_req &&
                        (prot_bus_addr >= 24'h210000) &&
                        (prot_bus_addr <= 24'h210fff);
    wire prot_extra_req = prot_bus_req &&
                          (prot_bus_addr >= 24'h211000) &&
                          (prot_bus_addr <= 24'h21ffff);
    wire prot_ram_req = prot_work_req || prot_extra_req;
    // K055550 fills/copies may also target the CPU VRAM window (current K056832 page).
    wire prot_vram_req = prot_bus_req &&
                                (prot_bus_addr >= 24'h300000) &&
                                (prot_bus_addr <= 24'h301fff);
    wire sprite_bus_obj_cs  = sprite_obj_cs || prot_obj_req;
    wire sprite_bus_obj_we  = prot_obj_req ? !prot_bus_rnw : sprite_obj_we;
    wire [12:1] sprite_bus_obj_addr = prot_obj_req ?
                                      prot_bus_addr[12:1] : cpu_a[12:1];
    wire [15:0] sprite_bus_obj_din = prot_obj_req ?
                                      prot_bus_dout : cpu_dout_i;
    wire [1:0] sprite_bus_obj_dsn = prot_obj_req ? prot_bus_dsn : cpu_dsn;
    // K055673's CPU port is a synchronous registered-read RAM.  Keep the
    // protection request asserted for a setup cycle, then acknowledge on the
    // following cycle so reads return the requested word and writes have
    // crossed the RAM edge before the K055550 FSM advances.
    reg  prot_obj_ack_active;
    reg  [23:0] prot_obj_addr_l;
    reg         prot_obj_rnw_l;
    reg  [15:0] prot_obj_dout_l;
    reg  [1:0]  prot_obj_dsn_l;
    wire prot_obj_same = prot_obj_ack_active && prot_obj_req &&
                         (prot_bus_addr == prot_obj_addr_l) &&
                         (prot_bus_rnw  == prot_obj_rnw_l) &&
                         (prot_bus_dout == prot_obj_dout_l) &&
                         (prot_bus_dsn  == prot_obj_dsn_l);
    wire prot_obj_ack = prot_obj_req && prot_obj_ack_active && prot_obj_same;
    always @(posedge clk48) begin
        if (rst_main) begin
            prot_obj_ack_active <= 1'b0;
            prot_obj_addr_l     <= 24'd0;
            prot_obj_rnw_l      <= 1'b0;
            prot_obj_dout_l     <= 16'd0;
            prot_obj_dsn_l      <= 2'b00;
        end else if (!prot_obj_req) begin
            prot_obj_ack_active <= 1'b0;
        end else if (!prot_obj_ack_active) begin
            prot_obj_ack_active <= 1'b1;
            prot_obj_addr_l     <= prot_bus_addr;
            prot_obj_rnw_l      <= prot_bus_rnw;
            prot_obj_dout_l     <= prot_bus_dout;
            prot_obj_dsn_l      <= prot_bus_dsn;
        end else if (!prot_obj_same) begin
            // The FSM changed to a new object operation while the previous
            // acknowledgement was held. Insert one fresh RAM setup cycle.
            prot_obj_ack_active <= 1'b0;
        end
    end
    // Hi-score restore writes into work RAM while the 68000 is held off.
    wire        hs_inj_req, hs_busy;
    wire [23:1] hs_inj_a;
    wire [15:0] hs_inj_d;
    // Work RAM is BRAM: two-cycle handshake (address stable, then data valid).
    wire        wram_sel = (cs_ram || cs_extra) && cpu_bus_active;
    wire        wram_cs  = hs_inj_req || prot_ram_req || wram_sel;
    wire [1:0] hs_inj_dsn;
    wire [1:0]  wram_dsn = hs_inj_req ? hs_inj_dsn : prot_ram_req ? prot_bus_dsn : cpu_dsn;
    wire        wram_wr  = hs_inj_req ? 1'b1 : prot_ram_req ? !prot_bus_rnw : !cpu_rnw;
    assign main_addr = cpu_a[20:1];
    assign main_cs   = cs_main && cpu_rnw;
    assign cpu_dout  = prot_vram_req ? prot_bus_dout : cpu_dout_i;
    assign wram_addr = hs_inj_req ? hs_inj_a[16:1] :
                       prot_ram_req ? prot_bus_addr[16:1] : cpu_a[16:1];
    assign wram_din  = hs_inj_req ? hs_inj_d :
                       prot_ram_req ? prot_bus_dout : cpu_dout_i;
    assign wram_we   = {2{wram_cs && wram_wr}} & ~wram_dsn;
    reg  [16:1] wram_addr_q;
    reg         ram_ok;
    always @(posedge clk48) begin
        wram_addr_q <= wram_addr;
        ram_ok      <= wram_cs && wram_addr == wram_addr_q;
    end
    wire [15:0] ram_data = wram_dout;

    // Metamorphic table and sentinel bytes from MAME hiscore.dat.
    jtmetamrph_hiscore u_hiscore(
        .rst     ( rst_main ),
        .transfer( ioctl_ram ),
        .clk     ( clk48 ),
        .cpu_wr  ( cs_ram && cpu_bus_active && !cpu_rnw ),
        .cpu_a   ( cpu_a ),
        .cpu_dout( cpu_dout_i ),
        .cpu_dsn ( cpu_dsn ),
        .cpu_idle( cpu_asn ),
        .inj_req ( hs_inj_req ),
        .inj_a   ( hs_inj_a ),
        .inj_d   ( hs_inj_d ),
        .inj_dsn ( hs_inj_dsn ),
        .ram_ok  ( ram_ok ),
        .busy    ( hs_busy ),
        .hs_addr ( hs_addr ),
        .hs_din  ( hs_din ),
        .hs_we   ( hs_we ),
        .hs_dout ( hs_dout )
    );

    // Object RAM is the CPU port of the generated dual-port BRAM. The
    // renderer port remains available for the later K055673 pipeline.
    // K055673 owns the object RAM so its DMA scanner sees the same words that
    // the CPU writes. The generated JTFRAME BRAM remains reserved for the
    // later external-memory optimization and is held inactive for now.
    assign omem_addr = 0;
    assign omem_we   = 2'b00;

    // CPU-side and renderer-side VRAM are the two ports of one physical
    // 17-bit K056832 page store. The CPU port retains the selected page;
    // renderer port 0 is driven below by the line fetcher.
    // Pages 0-15 live in the shared dual-port BRAM; the CPU-only unpaged bank
    // (page 16) is a separate 4K-word RAM so the BRAM stays at 64K words.
    // K055550 fills/copies may target the CPU-visible VRAM window
    // (0x300000-0x301fff, current K056832 page), e.g. the tile clear at boot.
    wire [ 1:0] pv_wen = {2{prot_vram_req && !prot_bus_rnw}} & ~prot_bus_dsn;
    reg  [12:1] pv_addr_q;
    reg         pv_ok;
    always @(posedge clk48) begin
        pv_addr_q <= prot_bus_addr[12:1];
        pv_ok     <= prot_vram_req && prot_bus_addr[12:1] == pv_addr_q;
    end
    wire [12:1] uv_addr = prot_vram_req ? prot_bus_addr[12:1] : k056832_vram_addr[12:1];
    wire [ 1:0] uv_we   = prot_vram_req ? pv_wen : k056832_vram_we;
    wire [15:0] uv_din  = prot_vram_req ? prot_bus_dout : cpu_dout_i;
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
    assign vmem_addr = prot_vram_req ? {k056832_selected_page[3:0], prot_bus_addr[12:1]}
                                     : k056832_vram_addr[16:1];
    assign vmem_we   = uv_we & {2{~unp_sel}};
    // K056832 video emits a 17-bit word address with bit17 forced zero
    // ({1'b0,grid_page,tile_index}). JTFRAME VRAM is 16-bit addressed, so
    // discard that documented zero explicitly instead of relying on implicit
    // 17->16 truncation (which hid real width warnings in Quartus).
    assign vram_addr = video_vram_addr[16:1];
    // Palette RAM: 2048 xRGB_888 entries as two 16-bit banks (even/odd word).
    reg [2:0] pal_phase;
    reg [11:0] front_idx_hold, back_idx_hold;
    wire [11:0] video_pal_idx = (pal_phase == 3'd0) ? front_idx_hold : back_idx_hold;
    wire pal_wr = cs_palette && cpu_bus_active && !cpu_rnw;
    assign cpalh_addr = cpu_a[12:2];
    assign cpall_addr = cpu_a[12:2];
    assign cpalh_we   = {2{pal_wr && !cpu_a[1]}} & ~cpu_dsn;
    assign cpall_we   = {2{pal_wr &&  cpu_a[1]}} & ~cpu_dsn;
    // Palette video port is time-multiplexed inside one 6-MHz pixel: winner
    // first, then the runner-up used as K054338's alpha destination.
    assign palh_addr  = video_pal_idx[10:0];
    assign pall_addr  = video_pal_idx[10:0];
    // Both palette RAM ports use clk (96MHz in this profile), with no
    // input/output latches. Forward only written bytes on a mixed-port
    // collision at the existing synchronous RAM output latency.
    wire [15:0] palh_video_data, pall_video_data;
    jtmetamrph_palette_forward u_palette_forward(
        .clk(clk),.rst(rst_main),.video_addr(video_pal_idx[10:0]),
        .cpu_addr(cpu_a[12:2]),.cpu_data(cpu_dout),
        .high_we(cpalh_we),.low_we(cpall_we),
        .high_raw(palh_dout),.low_raw(pall_dout),
        .high_data(palh_video_data),.low_data(pall_video_data)
    );
    assign objram_addr = 0;

    // CPU ROM readback has priority over the scanline fetcher on the shared
    // tile SDRAM slot. A held CPU request therefore cannot be starved by a
    // renderer request, and the renderer observes tile_ok only when it owns
    // the slot.
    assign tile_addr = k056832_tile_cs ? k056832_tile_addr : video_tile_addr;
    assign tile_cs   = k056832_tile_cs || video_tile_cs;
    assign obj_addr  = sprite_rom_addr;
    assign obj_cs    = sprite_rom_cs;

    // K055550 command engine. Its completion is part of the CPU bus wait
    // contract; A0, 9F, 98, C0, and the evidence-bounded 87 behavior are
    // implemented in the title-local sequential engine.
    assign prot_bus_din = prot_ram_req ? ram_data :
                          prot_obj_req ? sprite_cpu_dout :
                          prot_vram_req ? (unp_sel_q ? unp_dout : vmem_dout) : 16'h0000;
    // Hardening: a K055550 request can never hang the engine (and with it
    // the 68000).  The hi-score injector shares the work-RAM port, so RAM
    // acks are ignored while it owns the port; a request to an address with
    // no routed memory completes as a no-op after a short settle time.
    reg        hs_inj_q;
    reg  [1:0] prot_none_cnt;
    wire       prot_none_req = prot_bus_req && !prot_ram_req && !prot_obj_req && !prot_vram_req;
    always @(posedge clk48) begin
        hs_inj_q      <= hs_inj_req;
        prot_none_cnt <= !prot_none_req ? 2'd0 : (&prot_none_cnt ? prot_none_cnt : prot_none_cnt + 2'd1);
    end
    assign prot_bus_ack = (prot_ram_req && ram_ok && !hs_inj_req && !hs_inj_q) ||
                          prot_obj_ack || pv_ok || (prot_none_req && &prot_none_cnt);
    // Hold the CPU acknowledge for the rest of the 68000 cycle, so the
    // single-clock K055550 dtack pulse cannot be missed.
    reg prot_acked;
    always @(posedge clk48) begin
        if (rst_main || !cs_prot) prot_acked <= 1'b0;
        else if (prot_dtack)      prot_acked <= 1'b1;
    end
    jtviostorm_k055550 u_k055550(
        .clk      ( clk48 ),
        .rst      ( rst_main ),
        .cen      ( cen_16 ),
        .cs       ( cs_prot ),
        .rnw      ( cpu_rnw ),
        .addr     ( cpu_byte_addr[5:1] ),
        .din      ( cpu_dout_i ),
        .dsn      ( cpu_dsn ),
        .dout     ( prot_dout ),
        .dtack    ( prot_dtack ),
        .busy     ( prot_busy ),
        .bus_req  ( prot_bus_req ),
        .bus_addr ( prot_bus_addr ),
        .bus_rnw  ( prot_bus_rnw ),
        .bus_dout ( prot_bus_dout ),
        .bus_dsn  ( prot_bus_dsn ),
        .bus_ack  ( prot_bus_ack ),
        .bus_din  ( prot_bus_din )
    );

    // Register-file endpoints. Readback remains zero until each custom-device
    // register contract is verified from the pinned MAME corpus and board
    // evidence.
    wire k054338_we = cs_k054338 && cpu_bus_active && !cpu_rnw;
    wire k055555_we = cs_k055555 && cpu_bus_active && !cpu_rnw;
    // K054321 is a low-byte-only 68000 peripheral. The address presented to
    // it is the MAME word offset (the CPU's A[4:1]); high-byte writes are
    // deliberately ignored by the wrapper.
    wire k054321_we = cs_k054321 && cpu_bus_active && !cpu_rnw && !cpu_dsn[0];
    // sound_irq_w(uint16_t) takes no mem_mask in MAME: any write (either
    // byte lane or full word) to 0x264000/1 triggers the sound Z80 IRQ.
    wire sound_irq_we = cs_sound_irq && cpu_bus_active && !cpu_rnw;
    wire [7:0] k054321_dout;
    wire       k054321_irq_n;
    wire [7:0] k054321_active;
    wire [6:0] k054321_volume;
    wire [7:0] sound_st_dout;
    wire [7:0] k053252_dout;
    wire       k053252_lhbl, k053252_lvbl, k053252_hs, k053252_vs;
    wire [8:0] k053252_hpos, k053252_vpos;
    wire       k053252_int1, k053252_int2;
    wire [15:0] lvc_dout;
    wire        lvc_cpu_ok;
    wire [8:0]  lvc_pxl;
    wire       sprite_dma_enabled;
    wire       OBJDMAEN;
    wire       irq6_latched, irq5_latched;
    jtmetamrph_irq u_irq(
        .rst                ( rst_main ),
        .clk                ( clk48 ),
        .hpos               ( k053252_hpos ),
        .vpos               ( k053252_vpos ),
        .sprite_irq_enabled ( sprite_dma_enabled ),
        .cpu_asn            ( cpu_asn ),
        .cpu_fc             ( cpu_fc ),
        .cpu_iack_level     ( cpu_a[3:1] ),
        .cpu_ipln           ( cpu_ipln ),
        .cpu_vpa_n          ( cpu_vpa_n ),
        .irq6_pending       ( irq6_latched ),
        .irq5_pending       ( irq5_latched )
    );
    wire [7:0] priority_code, palette_code, brightness_code;
    wire [7:0] layer_priority0, layer_priority1, layer_priority2, layer_priority3;
    wire [7:0] sub1_priority;
    wire [11:0] sub1_palette_base;
    wire [7:0] input_enables;
    wire [11:0] object_palette_base;
    wire [3:0] mix_code, shadow_code;
    wire [7:0] v_inmix_code, v_inmix_on, os_inmix_code, os_inmix_on;
    wire [7:0] colour_r, colour_g, colour_b;
    wire [3:0] k056832_page0, k056832_page1, k056832_page2, k056832_page3;
    wire [1:0] k056832_x0,k056832_x1,k056832_x2,k056832_x3,k056832_y0,k056832_y1,k056832_y2,k056832_y3;
    wire [1:0] k056832_w0,k056832_w1,k056832_w2,k056832_w3,k056832_h0,k056832_h1,k056832_h2,k056832_h3;
    // Full 16-bit signed K056832 scroll registers -- see Fix 4, jtviostorm_k056832.sv.
    wire signed [15:0] k056832_dx0, k056832_dx1, k056832_dx2, k056832_dx3;
    wire signed [15:0] k056832_dy0, k056832_dy1, k056832_dy2, k056832_dy3;
    wire [1:0] k056832_flip0, k056832_flip1, k056832_flip2, k056832_flip3;
    // Global screen flip (REG0 bits 5/4) + correction registers 0x3c/0x3a --
    // see port comments in jtviostorm_k056832.sv / jtviostorm_k056832_video.sv.
    wire        k056832_gflip_x, k056832_gflip_y;
    wire signed [12:0] k056832_corr_x;
    wire signed [11:0] k056832_corr_y;
    wire [17:1] video_vram_addr;
    wire        video_tile_cs;
    wire [21:2] video_tile_addr;
    // 9 bits: [8:5]=colnib, [4:0]=raw 5bpp pen -- see Fix 1, jtviostorm_k056832_video.sv.
    wire [8:0]  lyrf_pxl, lyra_pxl, lyrb_pxl, lyrc_pxl;
    wire [1:0]  lyrf_mix, lyra_mix, lyrb_mix, lyrc_mix;
    wire [11:0] palette_index;
    wire [11:0] priority_palette_index;
    wire [11:0] priority_background_index;
    wire [2:0]  priority_background_source;
    wire        priority_background_valid;
    wire [1:0] priority_mix, priority_shadow;
    wire [2:0] priority_source;
    wire       priority_valid;
    wire [11:0] layer_palette0, layer_palette1, layer_palette2, layer_palette3;
    wire [7:0] palette_r, palette_g, palette_b;
    wire [7:0] io_p1 = { cab_1p[0], 1'b1, joystick1[5:4], joystick1[3:0] };
    wire [7:0] io_p2 = { cab_1p[1], 1'b1, joystick2[5:4], joystick2[3:0] };
    wire [7:0] io_p3 = { cab_1p[2], 1'b1, joystick3[5:4], joystick3[3:0] };
    wire [7:0] io_p4 = { cab_1p[3], 1'b1, joystick4[5:4], joystick4[3:0] };
    // IN0 per Metamorphic Force's MAME port map: COIN1-4 occupy bits 0-3,
    // SERVICE1/2 occupy bits 4/5, and bits 6/7 are unknown; all active low.
    // The wrapper routes the second service input through unused dipsw[8].
    wire [7:0] io_in0 = { 2'b11, dipsw[8], service, coin[3:0] };
    wire       eep_do, eep_rdy;
    // LS273 S121 low-byte latch, OUTPUT&LDS clocked, CLR=SYSRES (F4).
    wire       eep_write = cs_io && cpu_bus_active && !cpu_rnw &&
                           (cpu_byte_addr == 24'h27c000) && !cpu_dsn[0];
    // SW1 bits retain Metamorphic Force's Sound/Coin Mechanism/Players/
    // Continuous Energy settings. ER5911 DO/READY occupy IN1 bits 0/1.
    // IN1 bit3 is the dedicated Test switch (PORT_SERVICE_NO_TOGGLE),
    // distinct from IN0 bit4's Service1 coin credit; JTFRAME provides
    // separate `dip_test`/`service` ports for exactly this split.
    wire [7:0] io_in1 = { dipsw[7:4], dip_test, 1'b0, eep_rdy, eep_do };

    reg [7:0] eep_ctrl_r;
    always @(posedge clk48 or posedge rst) begin
        if (rst)
            eep_ctrl_r <= 8'h00;
        else if (eep_write)
            eep_ctrl_r <= cpu_dout_i[7:0];
    end
    // Q8->Q1 bit order (IO sheet). OBJDMAEN arms the level-5 interrupt;
    // LVCROT/LVCDMAEN/COINCNT1-2 have no sink in this core.
    wire LVCROT   = eep_ctrl_r[7];
    wire LVCDMAEN = eep_ctrl_r[6];
    assign OBJDMAEN = eep_ctrl_r[5];
    wire COINCNT2 = eep_ctrl_r[4];
    wire COINCNT1 = eep_ctrl_r[3];
    wire EEP_CLK  = eep_ctrl_r[2];
    wire EEP_CS   = eep_ctrl_r[1];
    wire EEP_DI   = eep_ctrl_r[0];

    // LS175 S40 upper-byte latch, OUTPUT&UDS clocked, same 0x27c000 word.
    wire       io_hi_write = cs_io && cpu_bus_active && !cpu_rnw &&
                             (cpu_byte_addr == 24'h27c000) && !cpu_dsn[1];
    reg  [7:0] io_hi_r;
    always @(posedge clk48 or posedge rst) begin
        if (rst)
            io_hi_r <= 8'h00;
        else if (io_hi_write)
            io_hi_r <= cpu_dout_i[15:8];
    end
    // D11 is an audio-enable (high = on); the sound block takes an active-high mute
    wire MUTE = ~io_hi_r[3];
    wire AFE  = io_hi_r[2];
    // OCHARA (D8, sprite ROM bank/expansion select): no unambiguous OBJ CHA
    // sink found in u_k055673/u_jtsimson_obj (rom_addr is a flat 21-bit bus,
    // no bank-select input) -- latched, unconnected, documented (G4/G8).
    wire OCHARA = io_hi_r[0];

    jt5911 #(.PROG(0)) u_eeprom(
        .rst      ( rst       ),
        .clk      ( clk48     ),
        .sclk     ( EEP_CLK    ),
        .sdi      ( EEP_DI     ),
        .sdo      ( eep_do     ),
        .rdy      ( eep_rdy    ),
        .scs      ( EEP_CS     ),
        .mem_addr ( nvram_addr ),
        .mem_din  ( nvram_din  ),
        .mem_we   ( nvram_we   ),
        .mem_dout ( nvram_dout ),
        .dump_clr ( 1'b0       ),
        .dump_flag(            )
    );
    jtviostorm_k055555 u_k055555(
        .clk             ( clk48 ),
        .rst             ( rst_main ),
        .we              ( k055555_we ),
        .addr            ( cpu_byte_addr[7:1] ),
        .dsn             ( cpu_dsn ),
        .din             ( cpu_dout_i ),
        .priority_code   ( priority_code ),
        .palette_code    ( palette_code ),
        .mix_code        ( mix_code ),
        .v_inmix_code    ( v_inmix_code ),
        .v_inmix_on      ( v_inmix_on ),
        .os_inmix_code   ( os_inmix_code ),
        .os_inmix_on     ( os_inmix_on ),
        .shadow_code     ( shadow_code ),
        .brightness_code ( brightness_code ),
        .layer_palette0  ( layer_palette0 ),
        .layer_palette1  ( layer_palette1 ),
        .layer_palette2  ( layer_palette2 ),
        .layer_palette3  ( layer_palette3 ),
        .layer_priority0 ( layer_priority0 ),
        .layer_priority1 ( layer_priority1 ),
        .layer_priority2 ( layer_priority2 ),
        .layer_priority3 ( layer_priority3 ),
        .sub1_priority   ( sub1_priority ),
        .sub1_palette_base( sub1_palette_base ),
        .input_enables   ( input_enables ),
        .object_palette_base( object_palette_base )
    );
    jtviostorm_priority u_priority(
        .input_enables      ( input_enables ),
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
        .lvc_pxl            ( lvc_pxl ),
        .sub1_priority      ( sub1_priority ),
        .sub1_palette_base  ( sub1_palette_base ),
        .lyrf_mix           ( lyrf_mix ),
        .lyra_mix           ( lyra_mix ),
        .lyrb_mix           ( lyrb_mix ),
        .lyrc_mix           ( lyrc_mix ),
        .sprite_pixel       ( sprite_pixel ),
        .sprite_priority    ( sprite_priority ),
        .sprite_shadow      ( sprite_shadow ),
        .sprite_shadow_prio ( sprite_shadow_prio ),
        .object_palette_base( object_palette_base ),
        .palette_index      ( priority_palette_index ),
        .selected_mix       ( priority_mix ),
        .selected_shadow    ( priority_shadow ),
        .selected_source    ( priority_source ),
        .selected_valid     ( priority_valid ),
        .background_palette_index( priority_background_index ),
        .background_source ( priority_background_source ),
        .background_valid  ( priority_background_valid )
    );
    // Timing pipeline: the priority network is combinational but its result is
    // consumed only once per 6-MHz pixel.  Capture the complete winner/runner
    // bundle every 48-MHz clock so the long tile/sprite -> priority path ends
    // here instead of continuing into the palette request phase.
    reg [11:0] priority_palette_q, priority_background_q;
    reg [2:0]  priority_background_source_q, priority_source_q;
    reg [1:0]  priority_mix_q, priority_shadow_q;
    reg        priority_background_valid_q, priority_valid_q;

    // MAME K055555GX_decode_vmixcolor / gx_draw_basic_tilemaps:
    // each tile supplies an external two-bit category. V INMIX ON chooses,
    // bit by bit, whether the effective K054338 blend selector comes from
    // that category or K055555 V INMIX. The old core forwarded only the raw
    // tile category, so writes to PBLEND could be correct yet have no visual
    // effect (Metamorphic Force attract fade at frames 813+).
    reg [1:0] effective_priority_mix;
    reg [1:0] vmx_sel, von_sel;
    always @* begin
        vmx_sel = 2'd0;
        von_sel = 2'd0;
        case (priority_source)
            3'd0: begin vmx_sel=v_inmix_code[1:0]; von_sel=v_inmix_on[1:0]; end
            3'd1: begin vmx_sel=v_inmix_code[3:2]; von_sel=v_inmix_on[3:2]; end
            3'd2: begin vmx_sel=v_inmix_code[5:4]; von_sel=v_inmix_on[5:4]; end
            3'd3: begin vmx_sel=v_inmix_code[7:6]; von_sel=v_inmix_on[7:6]; end
            default: begin end
        endcase
        if (priority_source <= 3'd3)
            effective_priority_mix = (priority_mix & ~von_sel) | (vmx_sel & von_sel);
        else if (priority_source == 3'd5)
            // MAME's SUB1 path takes OS INMIX bits 3:2 as its K054338 level.
            effective_priority_mix = os_inmix_code[3:2];
        else
            effective_priority_mix = priority_mix;
    end
    always @(posedge clk48) begin
        if (rst_main) begin
            priority_palette_q <= 12'd0;
            priority_background_q <= 12'd0;
            priority_background_source_q <= 3'd0;
            priority_source_q <= 3'd0;
            priority_mix_q <= 2'd0;
            priority_shadow_q <= 2'd0;
            priority_background_valid_q <= 1'b0;
            priority_valid_q <= 1'b0;
        end else begin
            priority_palette_q <= priority_palette_index;
            priority_background_q <= priority_background_index;
            priority_background_source_q <= priority_background_source;
            priority_source_q <= priority_source;
            priority_mix_q <= effective_priority_mix;
            priority_shadow_q <= priority_shadow;
            priority_background_valid_q <= priority_background_valid;
            priority_valid_q <= priority_valid;
        end
    end

    // One physical video palette port services both candidates inside a
    // pixel. native_pxl_cen latches the pipelined pair; phase 0 requests the winner,
    // phase 1 requests the runner-up. With synchronous palette RAM, data is
    // At SDRAM96 the BRAM returns data between consecutive clk48 edges:
    // capture the winner at phase 0, before switching to the runner-up, and
    // the runner-up at phase 1. Same-clock BRAM retains phases 1/2.
    reg [7:0] pal_r_q, pal_g_q, pal_b_q;
    reg [7:0] back_r_q, back_g_q, back_b_q;
    reg [1:0] mix_q2, shd_q2;
    reg [2:0] src_q2;
    reg front_valid_q2, back_valid_q2;
`ifdef JTFRAME_SDRAM96
    localparam [2:0] PAL_FRONT_CAPTURE=3'd0, PAL_BACK_CAPTURE=3'd1;
`else
    localparam [2:0] PAL_FRONT_CAPTURE=3'd1, PAL_BACK_CAPTURE=3'd2;
`endif
    always @(posedge clk48) begin
        if (rst_main) begin
            pal_phase <= 3'd0; front_idx_hold <= 12'd0; back_idx_hold <= 12'd0;
            pal_r_q<=0; pal_g_q<=0; pal_b_q<=0; back_r_q<=0; back_g_q<=0; back_b_q<=0;
            mix_q2<=0; shd_q2<=0; src_q2<=0;
            front_valid_q2<=0; back_valid_q2<=0;
        end else begin
            if (native_pxl_cen) begin
                pal_phase <= 3'd0;
                front_idx_hold <= priority_palette_q;
                back_idx_hold <= priority_background_valid_q ? priority_background_q : 12'd0;
                mix_q2 <= priority_mix_q; shd_q2 <= priority_shadow_q; src_q2 <= priority_source_q;
                front_valid_q2 <= priority_valid_q;
                back_valid_q2 <= priority_background_valid_q;
            end else if (pal_phase < 3'd7)
                pal_phase <= pal_phase + 3'd1;
            if (pal_phase == PAL_FRONT_CAPTURE) begin
                pal_r_q <= palh_video_data[7:0]; pal_g_q <= pall_video_data[15:8]; pal_b_q <= pall_video_data[7:0];
            end
            if (pal_phase == PAL_BACK_CAPTURE) begin
                back_r_q <= palh_video_data[7:0]; back_g_q <= pall_video_data[15:8]; back_b_q <= pall_video_data[7:0];
            end
        end
    end
    assign palette_index = front_idx_hold;
    assign palette_r = pal_r_q;
    assign palette_g = pal_g_q;
    assign palette_b = pal_b_q;
    jtviostorm_k054338 u_k054338(
        .clk             ( clk48 ),
        .rst             ( rst_main ),
        .we              ( k054338_we ),
        .addr            ( cpu_byte_addr[4:1] ),
        .dsn             ( cpu_dsn ),
        .din             ( cpu_dout_i ),
        .front_r         ( palette_r ), .front_g( palette_g ), .front_b( palette_b ),
        .pixel_valid     ( front_valid_q2 ),
        .back_r          ( back_r_q ), .back_g ( back_g_q ), .back_b ( back_b_q ),
        .back_valid      ( back_valid_q2 ),
        // K055555 supplies the register-selected defaults, while the
        // compositor supplies the selected pixel's effect metadata.  Use the
        // latter here so a tile/object mix or shadow does not affect every
        // pixel in the frame.  The K054338 port is four bits wide for the
        // physical selector namespace; this title's proven tile/object path
        // currently emits the low two-bit modes.
        .mix_code        ( {2'b00,mix_q2} ),
        .shadow_code     ( {2'b00,shd_q2} ),
        .brightness_code ( brightness_code ),
        // priority_source (u_priority.selected_source) is 0-3 for the four
        // K056832 tile layers (A/B/C/D, matching K55_VBRI's 2-bit-per-layer
        // field order) and 4 for the sprite/OBJ candidate; K054338 uses this
        // to pick the correct K55_VBRI field per set_brightness(layer)
        // (konamigx_v.cpp:253-266) instead of always reading layer A's bits.
        .bri_layer_sel   ( src_q2 ),
        .red             ( colour_r ), .green( colour_g ), .blue( colour_b )
    );
    jtviostorm_sound u_sound(
        .rst        ( rst_main ),
        .clk        ( clk48 ),
        .cen_8      ( cen_8 ),
        .cen_pcm    ( cen_pcm ),
        .main_we    ( k054321_we ),
        .main_addr  ( cpu_byte_addr[4:1] ),
        .main_din   ( cpu_dout_i[7:0] ),
        .main_dout  ( k054321_dout ),
        .snd_irq    ( sound_irq_we ),
        .irq_n      ( k054321_irq_n ),
        .active     ( k054321_active ),
        .volume     ( k054321_volume ),
        .snd_addr   ( snd_addr ),
        .snd_cs     ( snd_cs ),
        .snd_data   ( snd_data ),
        .snd_ok     ( snd_ok ),
        .pcma_addr  ( pcma_addr ),
        .pcma_cs    ( pcma_cs ),
        .pcma_data  ( pcma_data ),
        .pcma_ok    ( pcma_ok ),
        .pcmb_addr  ( pcmb_addr ),
        .pcmb_cs    ( pcmb_cs ),
        .pcmb_data  ( pcmb_data ),
        .pcmb_ok    ( pcmb_ok ),
        .pcm0_l     ( pcm0_l ),
        .pcm0_r     ( pcm0_r ),
        .pcm1_l     ( pcm1_l ),
        .pcm1_r     ( pcm1_r ),
        .debug_bus  ( debug_bus ),
        .st_dout    ( sound_st_dout ),
        .mute       ( MUTE )
    );
    jtviostorm_k056832 u_k056832(
        .clk            ( clk48 ),
        .rst            ( rst_main ),
        .reg_cs         ( k056832_reg_cs ),
        .b_cs           ( k056832_b_cs ),
        .vram_cs        ( cs_vram && cpu_bus_active ),
        .romrd_cs       ( cs_tile_read && cpu_bus_active ),
        .cpu_we         ( k056832_we ||
                          (cs_vram && cpu_bus_active && !cpu_rnw) ),
        .cpu_rnw        ( cpu_rnw ),
        .reg_addr       ( cpu_byte_addr[5:1] ),
        .b_addr         ( cpu_byte_addr[2:1] ),
        .vram_cpu_addr  ( cpu_a[12:1] ),
        .cpu_din        ( cpu_dout_i ),
        .cpu_dsn        ( cpu_dsn ),
        .cpu_dout       ( k056832_dout ),
        .vram_addr      ( k056832_vram_addr ),
        .vram_we        ( k056832_vram_we ),
        .vram_dout      ( vram_cpu_dout ),
        .tile_cs        ( k056832_tile_cs ),
        .tile_addr      ( k056832_tile_addr ),
        .tile_data      ( tile_data ),
        .tile_ok        ( tile_ok ),
        .tile_wait      ( k056832_tile_wait ),
        .selected_page  ( k056832_selected_page ),
        .rom_bank       ( k056832_rom_bank ),
        .mode_5bpp      ( k056832_mode_5bpp ),
        .layer_page0    ( k056832_page0 ),
        .layer_page1    ( k056832_page1 ),
        .layer_page2    ( k056832_page2 ),
        .layer_page3    ( k056832_page3 ),
        .layer_x0(k056832_x0),.layer_x1(k056832_x1),.layer_x2(k056832_x2),.layer_x3(k056832_x3),
        .layer_y0(k056832_y0),.layer_y1(k056832_y1),.layer_y2(k056832_y2),.layer_y3(k056832_y3),
        .layer_w0(k056832_w0),.layer_w1(k056832_w1),.layer_w2(k056832_w2),.layer_w3(k056832_w3),
        .layer_h0(k056832_h0),.layer_h1(k056832_h1),.layer_h2(k056832_h2),.layer_h3(k056832_h3),
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
        .corr_y         ( k056832_corr_y )
    );
    jtviostorm_k053252 u_k053252(
        .rst   ( rst_main ),
        .clk   ( clk48 ),
        .cen   ( native_pxl_cen ),
        .cs    ( cs_k053252 && cpu_bus_active ),
        .rnw   ( cpu_rnw ),
        .addr  ( cpu_byte_addr[4:1] ),
        .dsn   ( cpu_dsn ),
        .din   ( cpu_dout_i ),
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

    // Metamorphic Force uses the K053250 as GX SUB1.  Violent Storm's donor
    // only preserved these CPU windows as scratch RAM; the real device is
    // active here and owns its 0x24c000 RAM, 0x250000 registers and 0x320000
    // ROM-read window, plus the rendered SUB1 pixel stream.
    jtmetamrph_k053250 u_k053250(
        .rst       ( rst_main ),
        .clk       ( clk48 ),
        .pxl_cen   ( native_pxl_cen ),
        .ram_cs    ( cs_scratch && cpu_bus_active ),
        .reg_cs    ( cs_scratch_reg && cpu_bus_active ),
        .rom_cs    ( cs_lvc_rom && cpu_bus_active && cpu_rnw ),
        .cpu_we    ( cpu_bus_active && !cpu_rnw ),
        .cpu_addr  ( cpu_a[13:1] ),
        .cpu_dsn   ( cpu_dsn ),
        .cpu_dout  ( cpu_dout_i ),
        .cpu_din   ( lvc_dout ),
        .cpu_ok    ( lvc_cpu_ok ),
        .rom0_addr ( lvc0_addr ),
        .rom0_cs   ( lvc0_cs ),
        .rom0_data ( lvc0_data ),
        .rom0_ok   ( lvc0_ok ),
        .rom1_addr ( lvc1_addr ),
        .rom1_cs   ( lvc1_cs ),
        .rom1_data ( lvc1_data ),
        .rom1_ok   ( lvc1_ok ),
        .lhbl      ( k053252_lhbl ),
        .hdump     ( k053252_hpos ),
        .vrender1  ( k053252_vpos ),
        .pc_line   ( 9'h0ef ),
        .pxl       ( lvc_pxl )
    );

    jtviostorm_k056832_video u_k056832_video(
        .rst       ( rst_main ),
        .clk       ( clk48 ),
        .pxl_cen   ( native_pxl_cen ),
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
        .x0(k056832_x0),.x1(k056832_x1),.x2(k056832_x2),.x3(k056832_x3),
        .y0(k056832_y0),.y1(k056832_y1),.y2(k056832_y2),.y3(k056832_y3),
        .w0(k056832_w0),.w1(k056832_w1),.w2(k056832_w2),.w3(k056832_w3),
        .h0(k056832_h0),.h1(k056832_h1),.h2(k056832_h2),.h3(k056832_h3),
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
        .vram_addr ( video_vram_addr ),
        .vram_dout ( vram_dout ),
        .tile_cs   ( video_tile_cs ),
        .tile_addr ( video_tile_addr ),
        .tile_data ( tile_data ),
        .tile_ok   ( tile_ok && !k056832_tile_cs ),
        .lyrf_pxl  ( lyrf_pxl ),
        .lyra_pxl  ( lyra_pxl ),
        .lyrb_pxl  ( lyrb_pxl ),
        .lyrc_pxl  ( lyrc_pxl ),
        .lyrf_mix  ( lyrf_mix ),
        .lyra_mix  ( lyra_mix ),
        .lyrb_mix  ( lyrb_mix ),
        .lyrc_mix  ( lyrc_mix )
    );

    jtviostorm_k055673 u_k055673(
        .rst        ( rst_main ),
        .clk        ( clk48 ),
        .pxl_cen    ( native_pxl_cen ),
        .pxl2_cen   ( native_pxl2_cen ),
        .hpos       ( k053252_hpos ),
        .vpos       ( k053252_vpos ),
        .lhbl       ( k053252_lhbl ),
        .lvbl       ( k053252_lvbl ),
        .hs         ( k053252_hs ),
        .obj_cs     ( sprite_bus_obj_cs ),
        .obj_we     ( sprite_bus_obj_we ),
        .obj_addr   ( sprite_bus_obj_addr ),
        .obj_din    ( sprite_bus_obj_din ),
        .obj_dsn    ( sprite_bus_obj_dsn ),
        .obj_dout   ( sprite_cpu_dout ),
        .reg_cs     ( sprite_mmr_cs ),
        .reg_we     ( sprite_mmr_cs && !cpu_rnw ),
        .reg_addr   ( cpu_byte_addr[3:0] ),
        .reg_din    ( cpu_dout_i ),
        .reg_dsn    ( cpu_dsn ),
        .objset2_cs ( sprite_objset2_cs ),
        .objset2_we ( sprite_objset2_we ),
        .objset2_addr( cpu_byte_addr[3:1] ),
        .objset2_din( cpu_dout_i ),
        .objset2_dsn( cpu_dsn ),
        .rom_addr   ( sprite_rom_addr ),
        .rom_cs     ( sprite_rom_cs ),
        .rom_data   ( obj_data ),
        .rom_ok     ( obj_ok ),
        .objcha_n   ( sprite_objcha_n ),
        .rom_read_offset( cpu_byte_addr[3:1] ),
        .shadow     ( sprite_shadow ),
        .shadow_prio( sprite_shadow_prio ),
        .prio       ( sprite_priority ),
        .pixel      ( sprite_pixel ),
        .dma_irq_enabled( sprite_dma_enabled ),
        .dma_busy   ( sprite_dma_busy ),
        .ln_done    ( sprite_ln_done )
    );

    // Local register/IO read mux. Metamorphic Force uses four players and
    // three buttons per player; jtviostorm.qsf defines JTFRAME_BUTTONS=3 and
    // joystick[6:4] carries buttons 3:1 into the Konami player byte.
    // Keep an accepted ROM word bound to its actual CPU address.  The
    // JTFRAME TAG_RAM SDRAM cache presents data after registered tag lookup;
    // merely delaying main_ok by one clock could acknowledge while a prior
    // request's word was still held in the CPU-side register.
    reg [20:1] b01_main_addr_q;
    reg        b01_main_word_valid, b01_main_din_ready;
    wire b01_rom_same_addr = main_addr == b01_main_addr_q;
    // Do not re-use the old ROM transaction's delayed ready indication
    // when the 68000 presents a new address. Qualify READY on the current
    // address *combinationally*, prior to the following clk48 edge.
    wire b01_main_response_ready = main_cs && b01_rom_same_addr &&
                                   b01_main_word_valid && b01_main_din_ready;
    always @(posedge clk48) begin
        if (rst_main) begin
            b01_main_addr_q     <= 20'd0;
            b01_main_word_valid <= 1'b0;
            b01_main_din_ready <= 1'b0;
            main_data_hold      <= 16'hffff;
        end else begin
            b01_main_addr_q <= main_addr;
            if (!main_cs || !b01_rom_same_addr) begin
                b01_main_word_valid <= 1'b0;
                b01_main_din_ready <= 1'b0;
            end else begin
                // One capture per stable-address read.  The next 48-MHz
                // edge allows cpu_din_r to register the held word before
                // DTACK can permit a new 68000 bus sampling phase.
                if (!b01_main_word_valid && main_ok) begin
                    main_data_hold <= main_data;
                    b01_main_word_valid <= 1'b1;
                end
                b01_main_din_ready <= b01_main_word_valid;
            end
        end
    end

    // K056832 video RAM and palette ports are synchronous 96-MHz BRAM;
    // the 68000-facing bus and cpu_din_r register run at 48 MHz.
    // Require a stable CPU address for two complete 48-MHz samples, and
    // then one further response register edge before dropping DTACK.
    // This protects mirrored VRAM and COLOR RAM POST readbacks against
    // accepting the preceding address's output during physical phase skew.
    wire b01_bram_rd = cpu_bus_active && cpu_rnw &&
                        (cs_vram || cs_palette);
    reg  [23:1] b01_bram_addr_q;
    reg  [1:0]  b01_bram_settle;
    wire b01_bram_ready = b01_bram_rd && (b01_bram_settle == 2'd3) &&
                           cpu_a == b01_bram_addr_q;
    always @(posedge clk48) begin
        if (rst_main || !b01_bram_rd) begin
            b01_bram_addr_q <= 23'd0;
            b01_bram_settle <= 2'd0;
        end else if (cpu_a != b01_bram_addr_q) begin
            b01_bram_addr_q <= cpu_a;
            b01_bram_settle <= 2'd0;
        end else if (b01_bram_settle != 2'd3) begin
            b01_bram_settle <= b01_bram_settle + 2'd1;
        end
    end

    always @* begin
        bus_din = 16'hffff;
        if (cs_main)
            bus_din = main_data_hold;
        else if (cs_ram || cs_extra)
            bus_din = ram_data;
        else if (cs_obj || sprite_cpu_rom_read)
            // K053246 OBJSET1 (0x240000-7) and K055673 OBJSET2
            // (0x244010-1f) are write-only on real hardware; only object
            // RAM and the 0x244000-f ROM-checksum readback respond to a
            // CPU read (viostorm_map, MAME mystwarr.cpp).
            bus_din = sprite_cpu_dout;
        else if (cs_scratch || cs_scratch_reg || cs_lvc_rom)
            bus_din = lvc_dout;
        else if (cs_vram || cs_k056832 || cs_tile_read)
            bus_din = k056832_dout;
        else if (cs_palette)
            bus_din = cpu_a[1] ? cpall_dout : cpalh_dout;
        else if (cs_k053252)
            bus_din = {8'hff,k053252_dout};
        else if (cs_k054321)
            bus_din = {8'hff,k054321_dout};
        else if (cs_prot)
            bus_din = prot_dout;
        else if (cs_io) begin
            // Absolute Metamorphic Force map-relative byte offsets. Each player
            // byte is KONAMI16_LSB/MSB: UDLR, buttons 1-3, then Start.
            // JTFRAME joystick bits are active-low and already use UDLR in
            // bits 3:0; cab_1p carries active-low starts.
            case (cpu_byte_addr)
                24'h274000: bus_din = { io_p3, io_p1 };
                24'h274002: bus_din = { io_p4, io_p2 };
                24'h278000: bus_din = { 8'h00, io_in0 };
                // MAME eeprom_r(): low-byte access returns IN1; an upper-byte-only
                // access returns 0.  Keep the undriven upper lane zero rather than
                // exposing IN1 through a word value on UDS-only reads.
                24'h278002: bus_din = !cpu_dsn[0] ? {8'h00, io_in1} : 16'h0000;
                default:  bus_din = 16'hffff;
            endcase
        end
    end

    // Response is registered on the 48 MHz bus clock, matching mature
    // JTFRAME 68000 integrations and preserving SDRAM return-data phase.
    always @(posedge clk48) begin
        if (rst_main)
            cpu_din_r <= 16'hffff;
        else
            cpu_din_r <= bus_din;
    end
    assign cpu_din = cpu_din_r;

    assign bus_cs = cs_any;
    assign bus_busy = hs_busy |
                      (main_cs && !b01_main_response_ready) |
                      (b01_bram_rd && !b01_bram_ready) |
                      (wram_sel && !ram_ok) |
                      ((cs_scratch || cs_scratch_reg || cs_lvc_rom) && !lvc_cpu_ok) |
                      (sprite_cpu_rom_read && !obj_ok) |
                      (cs_prot && !prot_dtack && !prot_acked) |
                      (cs_tile_read && k056832_tile_wait);

    jtframe_okdly u_main_okdly(
        .rst    ( rst_main ),
        .clk    ( clk48 ),
        .cs     ( main_cs ),
        .ok     ( main_ok ),
        .ok_dly ( main_ok_dly )
    );

    wire [15:0] dtack_fave, dtack_fworst;
`ifdef VS_REPLAY
    localparam DTACK_RECOVERY = 0; // replay master stalls the bus for long spans
`else
    localparam DTACK_RECOVERY = 1;
`endif
    jtframe_68kdtack_cen #(.W(6),.RECOVERY(DTACK_RECOVERY),.MFREQ(48000)) u_dtack(
        .rst      ( rst_main ),
        .clk      ( clk48 ),
        .cpu_cen  ( cpu_cen ),
        .cpu_cenb ( cpu_cenb ),
        .bus_cs   ( bus_cs ),
        .bus_busy ( bus_busy ),
        .bus_legit( cs_prot ),
        .bus_ack  ( 1'b0 ),
        .ASn      ( cpu_asn ),
        .DSn      ( cpu_dsn ),
        .num      ( 5'd1 ),
        .den      ( 6'd3 ),
        .wait2    ( 1'b0 ),
        .wait3    ( 1'b0 ),
        .DTACKn   ( bus_dtack_n ),
        .fave     ( dtack_fave ),
        .fworst   ( dtack_fworst )
    );
    assign cpu_dtack_n = bus_dtack_n;

`ifdef VS_REPLAY
    // Simulation-only: the CPU is replaced by a bus master that the C++ driver
    // pokes to replay a recorded MAME write log (video/palette equivalence).
    reg [23:1] rp_a   /* verilator public_flat_rw */ = 23'd0;
    reg [15:0] rp_d   /* verilator public_flat_rw */ = 16'd0;
    reg        rp_asn /* verilator public_flat_rw */ = 1'b1;
    reg        rp_rnw /* verilator public_flat_rw */ = 1'b1;
    reg [ 1:0] rp_dsn /* verilator public_flat_rw */ = 2'b11;
    assign cpu_a       = rp_a;
    assign cpu_dout_i  = rp_d;
    assign cpu_asn     = rp_asn;
    assign cpu_rnw     = rp_rnw;
    assign cpu_uds_n   = rp_dsn[1];
    assign cpu_lds_n   = rp_dsn[0];
    assign cpu_fc      = 3'b101;
    assign cpu_reset_n = 1'b1;
    assign cpu_bg_n    = 1'b1;
`else
    jtframe_m68k u_cpu(
        .clk     ( clk48 ),
        .rst     ( rst_main ),
        .cpu_cen ( cpu_cen ),
        .cpu_cenb( cpu_cenb ),
        .BERRn   ( 1'b1 ),
        .VPAn    ( cpu_vpa_n ),
        .BGACKn  ( 1'b1 ),
        .HALTn   ( dip_pause & ~rst_main ),
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
`endif

    // Timing closure: the native renderer runs at 48 MHz while JTFRAME_SDRAM96
    // presents the video chain at 96 MHz.  Register the complete native pixel
    // bundle here so deep K056832/priority logic terminates in the
    // 48-MHz domain and RGB plus timing cross to the framework together.
    reg [`JTFRAME_COLORW-1:0] native_r_q, native_g_q, native_b_q;
    reg native_lhbl_q, native_lvbl_q, native_hs_q, native_vs_q;
    reg palette_lhbl_q, palette_lvbl_q, palette_hs_q, palette_vs_q;
    always @(posedge clk48) begin
        if (rst_main) begin
            native_r_q <= 0; native_g_q <= 0; native_b_q <= 0;
            native_lhbl_q <= 1'b0; native_lvbl_q <= 1'b0;
            native_hs_q <= 1'b0; native_vs_q <= 1'b0;
            palette_lhbl_q <= 1'b0; palette_lvbl_q <= 1'b0;
            palette_hs_q <= 1'b0; palette_vs_q <= 1'b0;
        end else if (native_pxl_cen) begin
            native_r_q <= colour_r;
            native_g_q <= colour_g;
            native_b_q <= colour_b;
            palette_lhbl_q <= k053252_lhbl;
            palette_lvbl_q <= k053252_lvbl;
            palette_hs_q <= k053252_hs;
            palette_vs_q <= k053252_vs;
            native_lhbl_q <= palette_lhbl_q;
            native_lvbl_q <= palette_lvbl_q;
            native_hs_q <= palette_hs_q;
            native_vs_q <= palette_vs_q;
        end
    end
    assign red   = native_r_q;
    assign green = native_g_q;
    assign blue  = native_b_q;
    assign LHBL  = native_lhbl_q;
    assign LVBL  = native_lvbl_q;
    assign HS    = native_hs_q;
    assign VS    = native_vs_q;
    assign dip_flip = 1'b0;
    assign debug_view = 8'h00;


    assign ioctl_din = 8'h00;

endmodule
