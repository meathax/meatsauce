module jtviostorm_game(
    `include "jtframe_game_ports.inc"
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
    wire [23:0] cpu_byte_addr = {cpu_a,1'b0};
    wire [ 1:0] cpu_dsn = {cpu_uds_n,cpu_lds_n};
    wire        bus_cs;
    wire        bus_busy;
    wire        bus_dtack_n;
    logic [15:0] bus_din;
    reg  [15:0] cpu_din_r;
    reg         rst_main;
    wire        main_ok_dly;

    // The Violent Storm map exposes two writable local windows around the
    // unused K053250 address space.  Keep them in flat inferred RAMs so the
    // physical depth is explicit (0x24c000-0x24ffff = 8K words) and so a
    // future schematic review can replace the wrapper without changing the
    // CPU-visible contract.  These are storage windows only; no road/video
    // function is inferred from their existence.
    (* ramstyle = "M10K, no_rw_check" *) reg [15:0] scratch_ram [0:8191];
    (* ramstyle = "MLAB, no_rw_check" *) reg [15:0] scratch_reg_ram [0:7];
    reg [15:0] scratch_dout_r, scratch_reg_dout_r;
    reg        scratch_seen, scratch_reg_seen;
    reg        scratch_ok_r, scratch_reg_ok_r;

    // Explicit address decode. The active gate includes AS and byte strobes
    // so an address held during an idle phase cannot create a chip select.
    wire cs_main, cs_ram, cs_obj, cs_extra, cs_sprite_ctl;
    wire cs_scratch, cs_scratch_reg, cs_k054338, cs_k055555, cs_prot;
    wire cs_k053252, cs_sound_irq, cs_k054321, cs_k056832, cs_io;
    wire cs_vram, cs_tile_read, cs_palette, cs_video, cs_any;
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
        .cs_palette     ( cs_palette ),
        .cs_video       ( cs_video ),
        .cs_any         ( cs_any )
    );

    wire scratch_cs_i     = cs_scratch     && cpu_bus_active;
    wire scratch_reg_cs_i = cs_scratch_reg && cpu_bus_active;

    // One registered read/ready phase models a local synchronous RAM port and
    // prevents the CPU response from depending on an asynchronous array
    // read. A held 68000 cycle is serviced once; writes use the same byte
    // enables as the external JTFRAME RAM slot.
    always @(posedge clk48) begin
        if (rst_main) begin
            scratch_dout_r     <= 16'hffff;
            scratch_reg_dout_r <= 16'hffff;
            scratch_seen       <= 1'b0;
            scratch_reg_seen   <= 1'b0;
            scratch_ok_r       <= 1'b0;
            scratch_reg_ok_r   <= 1'b0;
        end else begin
            if (!scratch_cs_i) begin
                scratch_seen <= 1'b0;
                scratch_ok_r <= 1'b0;
            end else if (!scratch_seen) begin
                scratch_seen   <= 1'b1;
                scratch_ok_r   <= 1'b1;
                scratch_dout_r <= scratch_ram[cpu_byte_addr[13:1]];
                if (!cpu_rnw) begin
                    if (!cpu_dsn[1]) scratch_ram[cpu_byte_addr[13:1]][15:8] <= cpu_dout_i[15:8];
                    if (!cpu_dsn[0]) scratch_ram[cpu_byte_addr[13:1]][7:0]  <= cpu_dout_i[7:0];
                end
            end
            if (!scratch_reg_cs_i) begin
                scratch_reg_seen <= 1'b0;
                scratch_reg_ok_r <= 1'b0;
            end else if (!scratch_reg_seen) begin
                scratch_reg_seen   <= 1'b1;
                scratch_reg_ok_r   <= 1'b1;
                scratch_reg_dout_r <= scratch_reg_ram[cpu_byte_addr[3:1]];
                if (!cpu_rnw) begin
                    if (!cpu_dsn[1]) scratch_reg_ram[cpu_byte_addr[3:1]][15:8] <= cpu_dout_i[15:8];
                    if (!cpu_dsn[0]) scratch_reg_ram[cpu_byte_addr[3:1]][7:0]  <= cpu_dout_i[7:0];
                end
            end
        end
    end

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
    assign main_addr = prot_ram_req ? prot_bus_addr[20:1] : cpu_a[20:1];
    assign main_cs   = cs_main && cpu_rnw;
    assign ram_cs    = prot_ram_req ? 1'b1 :
                       ((cs_ram || cs_extra) && cpu_bus_active);
    assign ram_we    = prot_ram_req ? !prot_bus_rnw :
                       (ram_cs && !cpu_rnw);
    assign ram_dsn   = prot_ram_req ? prot_bus_dsn : cpu_dsn;
    assign cpu_dout  = prot_ram_req ? prot_bus_dout : cpu_dout_i;

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
    assign vmem_addr = k056832_vram_addr;
    assign vmem_we   = k056832_vram_we;
    assign vram_addr = video_vram_addr;
    assign cpal_addr = cpu_a[12:1];
    assign cpal_we   = {2{cs_palette && cpu_bus_active && !cpu_rnw}} & ~cpu_dsn;
    assign pal_addr  = palette_index;
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
                          prot_obj_req ? sprite_cpu_dout : 16'h0000;
    assign prot_bus_ack = (prot_ram_req && ram_ok) || prot_obj_ack;
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
    wire       sprite_dma_enabled;
    wire       irq6_latched, irq5_latched;
    jtviostorm_irq u_irq(
        .rst              ( rst              ),
        .clk              ( clk48             ),
        .vpos             ( k053252_vpos      ),
        .sprite_dma_enabled( sprite_dma_enabled ),
        .cpu_asn          ( cpu_asn           ),
        .cpu_fc           ( cpu_fc            ),
        .cpu_ipln         ( cpu_ipln          ),
        .cpu_vpa_n        ( cpu_vpa_n         ),
        .irq6_pending     ( irq6_latched      ),
        .irq5_pending     ( irq5_latched      )
    );
    wire [7:0] priority_code, palette_code, brightness_code;
    wire [7:0] layer_priority0, layer_priority1, layer_priority2, layer_priority3;
    wire [7:0] input_enables;
    wire [11:0] object_palette_base;
    wire [3:0] mix_code, shadow_code;
    wire [7:0] colour_r, colour_g, colour_b;
    wire [3:0] k056832_page0, k056832_page1, k056832_page2, k056832_page3;
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
    wire [1:0] priority_mix, priority_shadow;
    wire [2:0] priority_source;
    wire       priority_valid;
    wire [11:0] layer_palette0, layer_palette1, layer_palette2, layer_palette3;
    wire [7:0] palette_r, palette_g, palette_b;
    wire [7:0] io_p1 = { cab_1p[0], 1'b1, joystick1[5:4], joystick1[3:0] };
    wire [7:0] io_p2 = { cab_1p[1], 1'b1, joystick2[5:4], joystick2[3:0] };
    wire [7:0] io_p3 = { cab_1p[2], 1'b1, joystick3[5:4], joystick3[3:0] };
    wire [7:0] io_p4 = 8'hff; // three-player cabinet; player four is absent
    // IN0 per viostorm's MAME port map (mystwarr.cpp INPUT_PORTS_START):
    // bit0-2 COIN1-3, bit3 unknown, bit4 SERVICE1, bit5 SERVICE2,
    // bit6-7 unknown; all active low.
    // SERVICE2 (bit5) is held inactive: JTFRAME's common port set provides a
    // single `service` input and no second service line, so there is no real
    // control to bind it to. This only matters with the Coin Mechanism DIP
    // set to "Independent" (dipsw[2]); in the default "Common" configuration
    // the game does not consult SERVICE2. Documented rather than mapped to an
    // arbitrary spare button, which would invent hardware behaviour.
    wire [7:0] io_in0 = { 2'b11, 1'b1, service, 1'b1, coin[2:0] };
    wire [7:0] eep_ctrl;
    wire       eep_do, eep_rdy;
    wire       eep_write = cs_io && cpu_bus_active && !cpu_rnw &&
                           (cpu_byte_addr == 24'h27c000) && !cpu_dsn[0];
    // The four low DIP bits retain the documented Sound/Flip/Coin/Players
    // inputs. ER5911 DO/READY occupy IN1 bits 0/1 exactly as in MAME.
    // IN1 bit3 is the dedicated Test switch (PORT_SERVICE_NO_TOGGLE),
    // distinct from IN0 bit4's Service1 coin credit; JTFRAME provides
    // separate `dip_test`/`service` ports for exactly this split.
    wire [7:0] io_in1 = { dipsw[3:0], dip_test, 1'b1, eep_rdy, eep_do };

    reg [7:0] eep_ctrl_r;
    assign eep_ctrl = eep_ctrl_r;
    always @(posedge clk48 or posedge rst) begin
        if (rst)
            eep_ctrl_r <= 8'h00;
        else if (eep_write)
            eep_ctrl_r <= cpu_dout_i[7:0];
    end

    jt5911 #(.PROG(0)) u_eeprom(
        .rst      ( rst       ),
        .clk      ( clk48     ),
        .sclk     ( eep_ctrl[2] ),
        .sdi      ( eep_ctrl[0] ),
        .sdo      ( eep_do     ),
        .rdy      ( eep_rdy    ),
        .scs      ( eep_ctrl[1] ),
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
        .lyrf_mix           ( lyrf_mix ),
        .lyra_mix           ( lyra_mix ),
        .lyrb_mix           ( lyrb_mix ),
        .lyrc_mix           ( lyrc_mix ),
        .sprite_pixel       ( sprite_pixel ),
        .sprite_priority    ( sprite_priority ),
        .sprite_shadow      ( sprite_shadow ),
        .object_palette_base( object_palette_base ),
        .palette_index      ( priority_palette_index ),
        .selected_mix       ( priority_mix ),
        .selected_shadow    ( priority_shadow ),
        .selected_source    ( priority_source ),
        .selected_valid     ( priority_valid )
    );
    assign palette_index = priority_palette_index;
    // Palette RAM is xBGR555. Expand each five-bit component without
    // introducing a new clock or a separate colour-space block.
    assign palette_r = {pal_dout[4:0],   pal_dout[4:2]};
    assign palette_g = {pal_dout[9:5],   pal_dout[9:7]};
    assign palette_b = {pal_dout[14:10], pal_dout[14:12]};
    jtviostorm_k054338 u_k054338(
        .clk             ( clk48 ),
        .rst             ( rst_main ),
        .we              ( k054338_we ),
        .addr            ( cpu_byte_addr[4:1] ),
        .dsn             ( cpu_dsn ),
        .din             ( cpu_dout_i ),
        .front_r         ( palette_r ), .front_g( palette_g ), .front_b( palette_b ),
        .back_r          ( 8'h00 ), .back_g ( 8'h00 ), .back_b ( 8'h00 ),
        // K055555 supplies the register-selected defaults, while the
        // compositor supplies the selected pixel's effect metadata.  Use the
        // latter here so a tile/object mix or shadow does not affect every
        // pixel in the frame.  The K054338 port is four bits wide for the
        // physical selector namespace; this title's proven tile/object path
        // currently emits the low two-bit modes.
        .mix_code        ( {2'b00,priority_mix} ),
        .shadow_code     ( {2'b00,priority_shadow} ),
        .brightness_code ( brightness_code ),
        // priority_source (u_priority.selected_source) is 0-3 for the four
        // K056832 tile layers (A/B/C/D, matching K55_VBRI's 2-bit-per-layer
        // field order) and 4 for the sprite/OBJ candidate; K054338 uses this
        // to pick the correct K55_VBRI field per set_brightness(layer)
        // (konamigx_v.cpp:253-266) instead of always reading layer A's bits.
        .bri_layer_sel   ( priority_source ),
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
        .st_dout    ( sound_st_dout )
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
        .vram_dout      ( vmem_dout ),
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
        .cen   ( cen_8 ),
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

    jtviostorm_k056832_video u_k056832_video(
        .rst       ( rst_main ),
        .clk       ( clk48 ),
        .pxl_cen   ( cen_8 ),
        .hpos      ( k053252_hpos ),
        .vpos      ( k053252_vpos ),
        .lhbl      ( k053252_lhbl ),
        .lvbl      ( k053252_lvbl ),
        .hs        ( k053252_hs ),
        .vs        ( k053252_vs ),
        .gfx_en    ( gfx_en ),
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
        .pxl_cen    ( cen_8 ),
        .pxl2_cen   ( cen_8 ),
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
        .prio       ( sprite_priority ),
        .pixel      ( sprite_pixel ),
        .dma_irq_enabled( sprite_dma_enabled ),
        .dma_busy   ( sprite_dma_busy ),
        .ln_done    ( sprite_ln_done )
    );

    // Local register/IO read mux. The I/O values follow the documented
    // three-player/two-button cabinet contract; software button-3 is inactive.
    always @* begin
        bus_din = 16'hffff;
        if (cs_main)
            bus_din = main_data;
        else if (cs_ram || cs_extra)
            bus_din = ram_data;
        else if (cs_obj || sprite_cpu_rom_read)
            // K053246 OBJSET1 (0x240000-7) and K055673 OBJSET2
            // (0x244010-1f) are write-only on real hardware; only object
            // RAM and the 0x244000-f ROM-checksum readback respond to a
            // CPU read (viostorm_map, MAME mystwarr.cpp).
            bus_din = sprite_cpu_dout;
        else if (cs_scratch)
            bus_din = scratch_dout_r;
        else if (cs_scratch_reg)
            bus_din = scratch_reg_dout_r;
        else if (cs_vram || cs_k056832 || cs_tile_read)
            bus_din = k056832_dout;
        else if (cs_palette)
            bus_din = cpal_dout;
        else if (cs_k053252)
            bus_din = {8'hff,k053252_dout};
        else if (cs_k054321)
            bus_din = {8'hff,k054321_dout};
        else if (cs_prot)
            bus_din = prot_dout;
        else if (cs_io) begin
            // Absolute map-relative byte offsets from viostorm_map. Each
            // player byte is KONAMI16_LSB/MSB: UDLR, Punch, Jump, inactive
            // button 3, then Start. JTFRAME joystick bits are active-low and
            // already use UDLR in bits 3:0; cab_1p carries active-low starts.
            case (cpu_byte_addr)
                24'h274000: bus_din = { io_p3, io_p1 };
                24'h274002: bus_din = { io_p4, io_p2 };
                24'h278000: bus_din = { 8'h00, io_in0 };
                24'h278002: bus_din = { 8'h00, io_in1 };
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
    assign bus_busy = (main_cs && !main_ok_dly) |
                      (ram_cs  && !ram_ok) |
                      (scratch_cs_i && !scratch_ok_r) |
                      (scratch_reg_cs_i && !scratch_reg_ok_r) |
                      (sprite_cpu_rom_read && !obj_ok) |
                      (cs_prot && !prot_dtack) |
                      (cs_tile_read && k056832_tile_wait);

    jtframe_okdly u_main_okdly(
        .rst    ( rst_main ),
        .clk    ( clk48 ),
        .cs     ( main_cs ),
        .ok     ( main_ok ),
        .ok_dly ( main_ok_dly )
    );

    jtframe_68kdtack_cen #(.W(6),.RECOVERY(1),.MFREQ(48000)) u_dtack(
        .rst      ( rst_main ),
        .clk      ( clk48 ),
        .cpu_cen  ( cpu_cen ),
        .cpu_cenb ( cpu_cenb ),
        .bus_cs   ( bus_cs ),
        .bus_busy ( bus_busy ),
        .bus_legit( 1'b0 ),
        .bus_ack  ( 1'b0 ),
        .ASn      ( cpu_asn ),
        .DSn      ( cpu_dsn ),
        .num      ( 5'd1 ),
        .den      ( 6'd3 ),
        .wait2    ( 1'b0 ),
        .wait3    ( 1'b0 ),
        .DTACKn   ( bus_dtack_n ),
        .fave     ( ),
        .fworst   ( )
    );
    assign cpu_dtack_n = bus_dtack_n;

    jtframe_m68k u_cpu(
        .clk     ( clk48 ),
        .rst     ( rst_main ),
        .cpu_cen ( cpu_cen ),
        .cpu_cenb( cpu_cenb ),
        .BERRn   ( 1'b1 ),
        .VPAn    ( cpu_vpa_n ),
        .BGACKn  ( 1'b1 ),
        .HALTn   ( ~(dip_pause | rst_main) ),
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

    // Native video remains a deterministic timing shell until K053252 and the
    // tile/object pipelines are integrated. No presentation crop is applied.
    assign red   = colour_r;
    assign green = colour_g;
    assign blue  = colour_b;
    assign LHBL  = k053252_lhbl;
    assign LVBL  = k053252_lvbl;
    assign HS    = k053252_hs;
    assign VS    = k053252_vs;
    assign dip_flip = status[5];
    assign debug_view = {prot_busy,prot_bus_req,priority_code[5:0]};

    assign ioctl_din = 8'h00;

endmodule
