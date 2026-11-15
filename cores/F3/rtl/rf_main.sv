// Taito F3 main CPU, memory map, interrupts and inputs

module rf_main #(parameter EXTERNAL_WORKRAM=0)
(
    input  logic        clk,             // 53.372 MHz
    input  logic        reset,

    // pivot store in SDRAM (rf_pivot_bus client). The pivot RAM is 64 KB on
    // the F3 and will not fit in block RAM here; see rf_pivot_bus.sv.
    input  logic        clk_ram,
    input wire memory_init,
    output logic [26:1] piv_ch_addr,
    output logic [15:0] piv_ch_din,
    output logic  [1:0] piv_ch_be,
    output logic        piv_ch_rnw,
    output logic        piv_ch_req,
    input  logic        piv_ch_ready,
    input  logic [63:0] piv_ch_dout,

    // program ROM read port (rf_prog_bus client, line-cached SDRAM fetch)
    output logic [21:1] prog_addr,
    output logic        prog_req,
    input  logic [15:0] prog_data,
    input  logic        prog_valid,

    // raster interface: one clk pulse on the first line of vblank
    input  logic        vbl_rise,

    // player inputs, MiSTer joystick words (active high)
    //   [0]=right [1]=left [2]=down [3]=up, buttons from [4],
    //   Start=[10] Coin=[11] Service=[12]
    input  logic [15:0] j0,
    input  logic [15:0] dial0, dial1,
    input  logic        pause,          // hold the CPU (MiSTer Pause button)
    // rf_hiscore borrows the CPU's RAM port while hs_pause holds clkena --
    // the same freeze the OSD Pause uses, a few microseconds at a time
    input  logic        hs_pause,
    output wire         hs_grant,
    input  logic [15:0] hs_addr,
    input  logic [15:0] hs_wdata,
    input  logic  [1:0] hs_be,
    input  logic        hs_we,
    output logic [15:0] hs_q,
    input wire hs_req,output wire hs_ready,
    output wire wr_req,wr_write,wr_ordered,wr_abort,
    output wire [15:0] wr_addr,wr_wdata,output wire [1:0] wr_be,
    input wire [15:0] wr_q,input wire wr_ready,wr_busy,
    input  logic [15:0] j1,
    // Kaiser Knuckle / Dan-Ku-Ga are 6-button fighters: buttons 4-6 are not
    // in IN.0 with the first three, they are in IN.4 (P2) and IN.5 (P1).
    // Every other game in the library uses those two ports for P3/P4, so
    // this is per game, from the MRA's game id (see Rayforce.sv).
    input  logic        six_button,
    input  logic        test_sw,        // cabinet TEST switch (OSD toggle)

    // ---- NVRAM: the settings EEPROM, loaded from and saved to the SD card
    // through hps_io's ioctl index 254 (see Rayforce.sv)
    input  logic        nv_wr,
    input  logic  [5:0] nv_addr,
    input  logic [15:0] nv_data,
    input  logic  [5:0] nv_sv_addr,
    output logic [15:0] nv_sv_data,
    output logic        nv_wrote,

    // ---- video side ----------------------------------------------------
    // Playfield / pivot / sprite scroll and the 1024x512 "extend" bit.
    // ctrl0 = 0x660000-0F (words 0-7), ctrl1 = 0x660010-1F (words 8-15).
    output logic [7:0][15:0] ctrl0,
    output logic [7:0][15:0] ctrl1,

    // Read ports into the video RAMs. Every one is the B side of a true
    // dual-port BRAM; the CPU owns the A side. Address in, data out one
    // clock later, held until the address changes.
    input  logic [13:0] v_pal_addr,   output logic [15:0] v_pal_q,
    input  logic [13:0] v_pf_addr,    output logic [15:0] v_pf_q,
    input  logic [11:0] v_text_addr,  output logic [15:0] v_text_q,
    input  logic [11:0] v_char_addr,  output logic [15:0] v_char_q,
    input  logic [14:0] v_line_addr,  output logic [15:0] v_line_q,
    input  logic [14:0] v_pivot_addr, output logic [15:0] v_pivot_q,
    input  logic [14:0] v_spr_addr,   output logic [15:0] v_spr_q,

    // CPU speed option.
    input  logic  [2:0] cpu_speed,      // OSD throttle, 0 = core as built
    // ---- sound board (Phase 3) -------------------------------------------
    // the MB8421's other side, driven by rf_sound_main
    input  logic  [9:0] snd_dp_addr,
    input  logic [15:0] snd_dp_wdata,
    input  logic        snd_dp_wren,
    input  logic  [1:0] snd_dp_be,
    output logic [15:0] snd_dp_q,
    // C80100 asserts the sound CPU's reset, C80000 releases it; held from
    // boot (taito_f3.cpp machine_reset asserts it)
    output logic        snd_reset,
    // KIRAMEKI's sound-ROM bank index, for rf_sound_main's 0xC20000 window
    output logic  [2:0] snd_bank_o,
    // low until the game writes 0x300000; only Kirameki ever does
    output logic        snd_bank_en_o

);

    // ---- CPU -------------------------------------------------------------
    logic        clkena_r;             // the registered decision; the
                                       // qualified enable is `clkena` below
    logic [31:0] cpu_addr;
    logic [15:0] cpu_din, cpu_dout;
    logic        nWr, nUDS, nLDS;
    logic [1:0]  busstate;              // 00 fetch, 10 read, 11 write, 01 none
    logic [31:0] vbr;
    logic  [2:0] ipl;

    // ---- the read-data wait ---------------------------------------------
    // rf_bram_be is a one-cycle read (address registered, output
    // unregistered) and src_q is a registered decode to match, so a read's
    // data reaches cpu_din the cycle AFTER its address reaches the bus. The
    // every-other-cycle rule in the wait-state engine below (`!clkena` in
    // the guard) used to buy that cycle for every access alike, and
    // cpu_fast simply deleted it -- which is why CPU Speed 1-3 froze every
    // game within a frame: TG68K latched the PREVIOUS access's ram_q
    // through the PREVIOUS access's src_q, on work RAM, palette, sprite,
    // playfield, text, line, pivot and the sound DPRAM alike. ROM was the
    // one source that survived, because rom_wait/prog_valid is a handshake
    // and not a fixed latency -- which is what made it look like a CPU that
    // boots and then hangs rather than one that never runs.
    //
    // Which access needs the wait CANNOT be decided a cycle ahead: the
    // busstate of the operation a clock enable will complete only appears
    // once the CPU has already advanced onto it. (A guard that reads
    // busstate on the deciding cycle is reading the operation that is
    // finishing, not the one that is starting, and gets the internal->read
    // transition wrong -- the same bug in a new place.) So the wait is
    // applied combinationally, on the cycle it is actually true:
    //   cpu_fresh      this cycle's address only just reached the bus, so
    //                  any BRAM behind it is still answering the last one
    //   cpu_needs_data fetch (00) or read (10). A write (11) and an
    //                  internal cycle (01) consume nothing off cpu_din and
    //                  may run back to back -- and on this CPU those are
    //                  where the deficit lives, because TG68K spends far
    //                  more internal cycles than a real 68020 and the old
    //                  rule halved the rate of every one of them.
    //
    // Settings 0 and 4-7 are provably unchanged: clkena_r already
    // alternates there, so cpu_fresh is never high on a cycle clkena_r is
    // and the qualification never fires. (2026-09-11)
    logic        cpu_fresh;
    wire         cpu_needs_data = (busstate == 2'b00) || (busstate == 2'b10);
    // A fast internal cycle may already have scheduled the next CE when
    // TG68K presents a work-RAM access. That access cannot consume the CE
    // until its own completion has been registered.
    logic ram_done;
    wire external_ram_cycle=EXTERNAL_WORKRAM && sel_ram && busstate!=2'b01;
    // BFFFO write-back reads a bit count TG68K registers every clock; it is
    // exact only when the previous clock did not enable the CPU, so the same
    // one-cycle decline as a fresh read applies (cuts the BFFFO setup path).
    logic        bfffo_hold;
    wire clkena=clkena_r && !((cpu_needs_data || bfffo_hold) && cpu_fresh) &&
        (!external_ram_cycle || ram_done);
    always_ff @(posedge clk) cpu_fresh <= reset ? 1'b0 : clkena;
    always_ff @(posedge clk)begin
        if(reset || (EXTERNAL_WORKRAM && wd_rst))ram_done<=0;
        else if(clkena)ram_done<=0;
        else if(EXTERNAL_WORKRAM && ram_wait && wr_ready)ram_done<=1;
    end

    // Wait-state engine, unchanged from the spike (it is the validated part):
    // BRAM and register targets are 2-cycle ops; a ROM access issues one
    // prog_bus request and holds clkena low until the data returns.
    // THE BOOT-BUG RULE: `a` is sampled ONLY while clkena is low -- once
    // clkena pulses, addr_out already belongs to the next operation.
    logic        rom_wait;
    logic ram_wait,cpu_ram_req;
    logic [15:0] cpu_ram_addr,cpu_ram_data,ram_result;
    logic [1:0] cpu_ram_be;
    logic cpu_ram_write;
    logic        prog_valid_lat;
    logic [15:0] prog_data_lat;

    // ---- CPU speed throttle ---------------------------------------------
    // The F3's 68020 runs at 16.67 MHz. This core clocks TG68K from clk_sys
    // with a clock enable and TG68K is not cycle-accurate, so the effective
    // speed is whatever the enable rate and the wait states happen to make.
    // Darius Gaiden is sensitive to it -- see the speedometer at the bottom
    // of this file for why and for the number to aim at. Setting 0 is the
    // core exactly as it was built before this knob existed, so every other
    // game is untouched until someone selects otherwise.
    logic [7:0] thr_acc;
    logic       thr_go;
    wire  [7:0] thr_inc = (cpu_speed == 3'd0) ? 8'd128 :   // as built
                          (cpu_speed == 3'd1) ? 8'd163 :   // x1.27 -- target
                          (cpu_speed == 3'd2) ? 8'd192 :   // x1.50
                          (cpu_speed == 3'd3) ? 8'd255 :   // x2.00, the cap
                          (cpu_speed == 3'd4) ? 8'd120 :   // 94 %
                          (cpu_speed == 3'd5) ? 8'd113 :   // 88 %
                          (cpu_speed == 3'd6) ? 8'd96  :   // 75 %
                                                8'd64;     // 50 %
    // 1-3 lift the every-other-cycle cap for the cycles that consume no
    // read data; everything else keeps it for all of them. Lifting it for
    // reads as well is what froze them -- see the read-data wait above.
    wire        cpu_fast = (cpu_speed >= 3'd1) && (cpu_speed <= 3'd3);

    always_ff @(posedge clk) begin
        if (reset) begin
            thr_acc <= 8'd0;
            thr_go  <= 1'b1;
        end else begin
            {thr_go, thr_acc} <= {1'b0, thr_acc} + {1'b0, thr_inc};
        end
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            clkena_r  <= 1'b0;
            rom_wait  <= 1'b0;
            ram_wait<=0;cpu_ram_req<=0;ram_result<=0;
            cpu_ram_addr<=0;cpu_ram_data<=0;cpu_ram_be<=0;cpu_ram_write<=0;
            prog_req  <= 1'b0;
        end else begin
            prog_req <= 1'b0;
            clkena_r <= 1'b0;

            if(EXTERNAL_WORKRAM && wd_rst && (ram_wait || ram_done))begin
                ram_wait<=0;cpu_ram_req<=0;
            end else if(EXTERNAL_WORKRAM && ram_done)begin
                // Retry a completion CE if the existing fresh-read guard
                // suppressed it; never issue the memory transaction again.
                clkena_r<=!clkena_r;
            end else if(EXTERNAL_WORKRAM && ram_wait)begin
                if(wr_ready)begin
                    // This private result is never overwritten by score reads.
                    ram_result<=wr_q;cpu_ram_req<=0;ram_wait<=0;clkena_r<=1;
                end
            end else if (rom_wait) begin
                // prog_valid direct, not just the latched copy: a fetch was
                // five clk_sys cycles even on a line-cache hit (decision ->
                // prog_req -> prog_valid -> prog_valid_lat -> clkena) and
                // this takes it to four. prog_data_lat is loaded on the same
                // edge that schedules the enable -- clkena is still low that
                // cycle -- so cpu_din is valid when the CPU samples it.
                // Instruction fetch is the dominant cost here and the
                // throttle never touched it: this branch bypasses thr_go.
                // BISECT 2026-09-12: reverted to prog_valid_lat. The direct
                // prog_valid took a cycle off EVERY instruction fetch at every
                // CPU Speed setting (this branch bypasses thr_go), and Darius
                // Gaiden's Zone A palette copy is timing-sensitive by ROM
                // design -- 39 requests into a 32-entry queue, and which three
                // are silently dropped depends on where the frame boundary
                // falls. Faster fetch moves that boundary.
                if (prog_valid_lat) begin
                    rom_wait <= 1'b0;
                    clkena_r <= 1'b1;
                end
            // clkena_r, NOT the qualified clkena. Reading the qualified one
            // here put the qualifying logic INSIDE this register's own
            // next-state loop (clkena_r -> qualify -> guard -> clkena_r), and
            // that is what took clk_sys from +1.138 ns slack to -0.292 with
            // -9.781 TNS on 2026-09-11 -- the first time the core clock had
            // ever failed. With clkena_r the loop is exactly as deep as it
            // was before the fix, and the qualification sits only on the
            // output that feeds TG68K.
            //
            // Still correct: when clkena_r is high but the qualification
            // blocks it, the CPU did NOT advance, so the address stays
            // settled; the guard simply declines this cycle and passes on the
            // next one. A blocked read therefore costs one EXTRA dead cycle
            // rather than going wrong, and back-to-back writes and internal
            // cycles are unaffected because they are never blocked. Settings
            // 0 and 4-7 stay bit-identical: cpu_fast is low, and clkena_r
            // already alternates, so neither term changes.
            end else if ((!clkena_r || (cpu_fast && !cpu_needs_data))
                         && !pause && !hs_pause && thr_go
                         && !piv_busy && (!EXTERNAL_WORKRAM || !wd_rst)) begin
                // pause: no further clock enables, so the CPU freezes between
                // bus cycles (a ROM fetch in flight still completes above)
                if (sel_rom && (busstate == 2'b00 || busstate == 2'b10)) begin
                    prog_addr <= a[21:1];
                    prog_req  <= 1'b1;
                    rom_wait  <= 1'b1;
                end else if(EXTERNAL_WORKRAM && sel_ram && busstate!=2'b01)begin
                    if(!ram_done && !wr_busy)begin
                        cpu_ram_addr<=a[16:1];cpu_ram_data<=cpu_dout;
                        cpu_ram_be<=be;cpu_ram_write<=!nWr && busstate==2'b11;
                        cpu_ram_req<=1;ram_wait<=1;
                    end
                end else begin
                    clkena_r <= 1'b1;
                end
            end
        end
    end

    always_ff @(posedge clk) begin
        if (reset || clkena) prog_valid_lat <= 1'b0;
        else if (prog_valid) begin
            prog_valid_lat <= 1'b1;
            prog_data_lat  <= prog_data;
        end
    end

    TG68KdotC_Kernel #(
        .SR_Read(2), .VBR_Stackframe(2), .extAddr_Mode(2),
        .MUL_Mode(2), .DIV_Mode(2), .BitField(2),
        .BarrelShifter(1), .MUL_Hardware(1)
    ) cpu (
        .clk(clk),
        .nReset(~(reset | wd_rst)),
        .clkena_in(clkena),
        .data_in(cpu_din),
        .IPL(ipl),
        .IPL_autovector(1'b1),          // 68EC020 AVEC: vector = 0x18 | level
        .berr(1'b0),
        .CPU(2'b11),                    // 68020 mode
        .addr_out(cpu_addr),
        .data_write(cpu_dout),
        .nWr(nWr),
        .nUDS(nUDS),
        .nLDS(nLDS),
        .busstate(busstate),
        .longword(),
        .nResetOut(),
        .FC(),
        .clr_berr(),
        .skipFetch(),
        .regin_out(),
        .CACR_out(),
        .VBR_out(vbr),
        .bfffo_hold(bfffo_hold)
    );

    // ---- address decode --------------------------------------------------
    wire [23:0] a = cpu_addr[23:0];

    // The program ROM window is the full 2 MB the F3 map gives it: Ray Force
    // populates 1 MB and the MRA pads the rest with zeros, which reads the
    // same as the unpopulated window did. Elevator Action Returns fills it.
    wire sel_rom   = (a[23:21] == 3'b000);                          // 000000-1FFFFF
    wire sel_romhi = 1'b0;                                          // (folded into sel_rom)
    wire sel_ram   = (a[23:18] == 6'b010000);                       // 400000-43FFFF (+mirror)
    wire sel_pal   = (a[23:15] == 9'b010001000);                    // 440000-447FFF
    wire sel_ctrl  = (a[23:16] == 8'h4A);
    wire sel_spr   = (a[23:16] == 8'h60);                           // 600000-60FFFF
    wire sel_61    = (a[23:16] == 8'h61);
    wire sel_pf    = sel_61 && !a[15];                              // 610000-617FFF
    wire sel_pfx   = sel_61 && (a[15:14] == 2'b10);                 // 618000-61BFFF
    wire sel_text  = sel_61 && (a[15:13] == 3'b110);                // 61C000-61DFFF
    wire sel_char  = sel_61 && (a[15:13] == 3'b111);                // 61E000-61FFFF
    wire sel_line  = (a[23:16] == 8'h62);                           // 620000-62FFFF
    wire sel_pivot = (a[23:16] == 8'h63);                           // 630000-63FFFF
    wire sel_vctrl = (a[23:16] == 8'h66) && (a[15:5] == 11'd0);     // 660000-66001F
    // 300000-30007F, the sound-ROM bankswitch. KIRAMEKI STAR ROAD ONLY: it is
    // the only F3 game that banks its sound ROM, and MAME's handler is
    // guarded by `if (m_game == KIRAMEKI)` with every other game logging
    // "Sound bankswitch in unsupported game". Write-only.
    wire sel_sndbank = (a[23:16] == 8'h30) && (a[15:7] == 9'd0);
    wire sel_dpram = (a[23:11] == 13'b1100000000000);               // C00000-C007FF

    wire cpu_wr = !nWr && (busstate == 2'b11) && clkena;
    wire [1:0] be = {~nUDS, ~nLDS};

    // ---- interrupts ------------------------------------------------------
    // 625 us after the vblank IRQ, in clk_sys ticks: 10000 cycles of a 16 MHz
    // 68020 = 625.0 us; 625 us x 53.372 MHz = 33358.
    localparam int INT3_DELAY = 33358;

    logic        irq2, irq3;
    logic [15:0] int3_tmr;

    // The autovector handler fetch is the acknowledge (see the header note).
    //
    // KNOWN LIMITATION: any data READ of VBR+0x68 / +0x6C while the IRQ is
    // pending also counts. The one place that happens is the boot ROM
    // checksum, which sweeps the vector table while interrupts are masked --
    // it drops a pending IRQ2 the game was not going to service anyway, and
    // is where the constant 380-frame offset between frame_cnt and irq2_cnt
    // comes from. Once the game is running nothing reads the vector table as
    // data, and the hardware acknowledge rate is exactly one per frame.
    wire vec_rd = clkena && (busstate == 2'b10);
    wire ack2   = irq2 && vec_rd && (a == (vbr[23:0] + 24'h68));
    wire ack3   = irq3 && vec_rd && (a == (vbr[23:0] + 24'h6C));

    always_ff @(posedge clk) begin
        if (reset) begin
            irq2 <= 1'b0; irq3 <= 1'b0; int3_tmr <= 16'd0;

        end else begin
            if (vbl_rise) begin
                irq2      <= 1'b1;
                int3_tmr  <= INT3_DELAY[15:0];

            end else if (int3_tmr != 16'd0) begin
                int3_tmr <= int3_tmr - 16'd1;
                if (int3_tmr == 16'd1) irq3 <= 1'b1;
            end
            if (ack2) begin irq2 <= 1'b0;  end
            if (ack3) begin irq3 <= 1'b0;  end
        end
    end

    // ---- watchdog (TC0640FIO) -------------------------------------------
    // The F3 has one, MAME configures it (WATCHDOG_TIMER in taito_f3.cpp) and
    // the games USE it: Elevator Action Returns' boot deliberately runs into
    // a `BRA.S *` with interrupts masked (ORI #$0700,SR at 0x01014C) and
    // relies on the watchdog to reboot the board out of it. Traced in MAME:
    // it sits at PC 0x01016E for about two seconds, resets, re-runs POST and
    // then reaches its main loop. Without a watchdog this core simply hung
    // there forever, which is exactly what it did until 2026-08-29.
    //
    // Kicked by any write to 0x4A0000. Three seconds of silence resets the
    // 68020 only -- not the core, not SDRAM, not the loaded ROM.
    //
    // Held off while `pause` is asserted: the OSD pause freezes the CPU, so
    // it cannot kick, and a watchdog that fired then would reboot the game
    // every time someone paused it.
    localparam int WD_FRAMES = 180;             // ~3 s at 58.94 Hz
    logic        wd_kick;
    logic  [7:0] wd_cnt;
    logic  [3:0] wd_hold;                       // reset pulse width
    wire         wd_rst = |wd_hold;

    always_ff @(posedge clk) begin
        if (reset) begin
            wd_cnt <= 8'd0; wd_hold <= 4'd0;
        end else begin
            if (wd_hold != 4'd0) wd_hold <= wd_hold - 4'd1;
            if (wd_kick || pause) wd_cnt <= 8'd0;
            else if (vbl_rise) begin
                if (wd_cnt >= WD_FRAMES[7:0]) begin
                    wd_cnt  <= 8'd0;
                    wd_hold <= 4'hF;            // pulse the CPU reset
                end else wd_cnt <= wd_cnt + 8'd1;
            end
        end
    end

    // IPL is active low on this core; level 3 wins over level 2.
    always_comb begin
        if      (irq3) ipl = 3'b100;    // ~3
        else if (irq2) ipl = 3'b101;    // ~2
        else           ipl = 3'b111;
    end

    // ---- control port 0x4A0000 ------------------------------------------
    logic [15:0] coin_word0, coin_word1;
    logic        ee_cs, ee_sk, ee_di;
    wire         ee_do;

    rf_eeprom_93c46 #(.SYNC_STORAGE(1)) eeprom
    (
        .clk(clk), .reset(reset),
        .cs(ee_cs), .sk(ee_sk), .di(ee_di), .do_out(ee_do),
        .ld_wr(nv_wr), .ld_addr(nv_addr), .ld_data(nv_data),
        .sv_addr(nv_sv_addr), .sv_data(nv_sv_data), .wrote(nv_wrote)
    );

    // EEPROMIN: bit0 EEPROM data out, bit1 TEST switch (active low),
    // bits 4-7 coin inputs (active low), the rest pulled high.
    wire [7:0] ee_in = {2'b11, ~j1[11], ~j0[11], 2'b11, ~test_sw, ee_do};

    // IN.0 low word, all active low.
    //  15..12 start 4/3/2/1   11..8 service 3/2/1, tilt
    //   7.. 4 P2 buttons 4..1  3..0 P1 buttons 4..1
    wire [15:0] in0_lo = { 1'b1, 1'b1, ~j1[10], ~j0[10],
                           1'b1, 1'b1, ~(j0[12] | j1[12]), 1'b1,
                           ~j1[7], ~j1[6], ~j1[5], ~j1[4],
                           ~j0[7], ~j0[6], ~j0[5], ~j0[4] };

    // IN.1 low word: joysticks, active low, bit order up/down/left/right from
    // bit 0 up. MiSTer's joystick word is right/left/down/up from bit 0, so
    // the nibbles are reversed here. Bits 8-15 must read high.
    wire [15:0] in1_lo = { 8'hFF,
                           ~j1[0], ~j1[1], ~j1[2], ~j1[3],
                           ~j0[0], ~j0[1], ~j0[2], ~j0[3] };

    // The 6-button fighters' extra three, active low, at the bit positions
    // MAME's port map gives them (verified with tools/mame/ports.lua on both
    // sets, 2026-09-11): IN.4 P2 button 4/5/6 = mask 0x100/0x200/0x400, so
    // low-word bits 10:8; IN.5 P1 button 4/5/6 = 0x001/0x002/0x004, bits 2:0.
    // MiSTer's joystick word puts buttons 4,5,6 at [7],[8],[9]. Off for every
    // other game, so those ports read all-ones exactly as they did before.
    wire [15:0] in4_lo = six_button
        ? {5'h1F, ~j1[9], ~j1[8], ~j1[7], 8'hFF}
        : 16'hFFFF;
    wire [15:0] in5_lo = six_button
        ? {13'h1FFF, ~j0[9], ~j0[8], ~j0[7]}
        : 16'hFFFF;

    // F3 packed dial words from the per-player input adapters.
    logic [15:0] ctrl_q;
    always_comb begin
        case (a[4:1])
            4'h0: ctrl_q = {ee_in, ee_in};      // IN.0 high word (EEPROM byte x2)
            4'h1: ctrl_q = in0_lo;              // IN.0 low  word
            4'h2: ctrl_q = coin_word0;          // IN.1 high word
            4'h3: ctrl_q = in1_lo;              // IN.1 low  word
            4'h4: ctrl_q = 16'hFFFF;            // IN.2 analog, high word
            4'h5: ctrl_q = dial0;               // IN.2 low: P1 dial
            4'h6: ctrl_q = 16'hFFFF;            // IN.3 analog, high word
            4'h7: ctrl_q = dial1;               // IN.3 low: P2 dial
            4'h8: ctrl_q = 16'hFFFF;            // IN.4 P3/P4 buttons, high word
            4'h9: ctrl_q = in4_lo;              // IN.4 low: P2 buttons 4-6
            4'hA: ctrl_q = coin_word1;          // IN.5 high word
            4'hB: ctrl_q = in5_lo;              // IN.5 low: P1 buttons 4-6
            default: ctrl_q = 16'hFFFF;
        endcase
    end

    always_ff @(posedge clk) begin
        wd_kick <= 1'b0;
        if (reset) begin
            coin_word0 <= 16'd0; coin_word1 <= 16'd0;
            {ee_cs, ee_sk, ee_di} <= 3'b000;
        end else if (cpu_wr && sel_ctrl) begin
            case (a[4:1])
                4'h2: coin_word0 <= cpu_dout;               // 4A0004, upper half
                4'hA: coin_word1 <= cpu_dout;               // 4A0014, upper half
                4'h9: if (!nLDS) begin                      // 4A0012 low byte
                    ee_di <= cpu_dout[2];
                    ee_sk <= cpu_dout[3];
                    ee_cs <= cpu_dout[4];
                end
                4'h0: wd_kick <= 1'b1;                      // 4A0000 watchdog
                default: ;
            endcase
        end
    end

    // ---- video control registers 0x660000 -------------------------------
    // Held in unpacked arrays and flattened onto the packed output ports:
    // a variable index into an unpacked array of vectors is the shape
    // Quartus handles best, and the ports stay plain vectors.
    logic [15:0] c0 [0:7];
    logic [15:0] c1 [0:7];
    integer ci;

    genvar gi;
    generate
        for (gi = 0; gi < 8; gi = gi + 1) begin : g_vctrl
            assign ctrl0[gi] = c0[gi];
            assign ctrl1[gi] = c1[gi];
        end
    endgenerate

    always_ff @(posedge clk) begin
        if (reset) begin
            for (ci = 0; ci < 8; ci = ci + 1) begin
                c0[ci] <= 16'd0;
                c1[ci] <= 16'd0;
            end
        end else if (cpu_wr && sel_vctrl) begin
            if (!a[4]) begin
                if (be[1]) c0[a[3:1]][15:8] <= cpu_dout[15:8];
                if (be[0]) c0[a[3:1]][7:0]  <= cpu_dout[7:0];
            end else begin
                if (be[1]) c1[a[3:1]][15:8] <= cpu_dout[15:8];
                if (be[0]) c1[a[3:1]][7:0]  <= cpu_dout[7:0];
            end
        end
    end

    // ---- memories --------------------------------------------------------
    wire [15:0] ram_q, pal_q, spr_q, pf_q, pfx_q, text_q, char_q,
                line_q, pivot_q, dpram_q;

    // Each CPU write fires ONCE, on the clock-enable cycle. busstate stays
    // 2'b11 for both cycles of a 2-cycle bus op, so without a qualifier the
    // write is performed twice; the one that commits at the end of the
    // clock-enable cycle is the one carrying valid address and data, which
    // build 28154550 established the hard way -- qualifying with !clkena
    // instead (rf_sound_main's rule, which does not transfer: different
    // TG68K mode and speed divider) broke Ray Force outright.
    //
    // The control and video-control registers are left unqualified: writing
    // the same value twice to a latch is idempotent, and the EEPROM lines
    // hang off those, so they are not worth disturbing.

    // CPU-only memories: simple dual port is enough.
    // While rf_hiscore holds hs_pause the CPU's clkena is suppressed, so it
    // neither writes (wren needs clkena) nor latches a read -- the mux is
    // invisible to it. hs_q shares the read port; the CPU's combinational
    // raddr is re-presented the cycle the mux drops back.
    assign hs_grant = hs_pause && !clkena_r && !rom_wait && !piv_busy &&
        (!EXTERNAL_WORKRAM || (!ram_wait && !ram_done && !cpu_ram_req && (!wr_busy || hs_req)));
    assign wr_req=EXTERNAL_WORKRAM && (hs_grant?hs_req:cpu_ram_req);
    assign wr_write=hs_grant?hs_we:cpu_ram_write;
    assign wr_ordered=hs_grant;
    assign wr_abort=reset|wd_rst;
    assign wr_addr=hs_grant?hs_addr:cpu_ram_addr;
    assign wr_wdata=hs_grant?hs_wdata:cpu_ram_data;
    assign wr_be=hs_grant?hs_be:cpu_ram_be;
    assign hs_ready=EXTERNAL_WORKRAM ? hs_grant && wr_ready : 1'b1;
    generate if(EXTERNAL_WORKRAM)begin: external_workram
        assign ram_q=ram_result;
        assign hs_q=wr_q;
    end else begin: local_workram
    rf_bram_be #(.AW(16)) u_ram (
        .clk(clk),
        .waddr(hs_grant ? hs_addr : a[16:1]),
        .wdata(hs_grant ? hs_wdata : cpu_dout),
        .wren(hs_grant ? hs_we : (cpu_wr && sel_ram && clkena)),
        .be(hs_grant ? hs_be : be),
        .raddr(hs_grant ? hs_addr : a[16:1]), .q(ram_q));
    assign hs_q = ram_q;
    end endgenerate

    rf_bram_be #(.AW(13)) u_pfx (
        .clk(clk), .waddr(a[13:1]), .wdata(cpu_dout),
        .wren(cpu_wr && sel_pfx && clkena), .be(be), .raddr(a[13:1]), .q(pfx_q));

    // MB8421: this CPU on port A, the sound CPU on port B (byte lanes)
    rf_bram_tdp #(.AW(10)) u_dpram (
        .clk(clk),
        .a_addr(a[10:1]), .a_wdata(cpu_dout), .a_wren(cpu_wr && sel_dpram && clkena),
        .a_be(be), .a_q(dpram_q),
        .b_addr(snd_dp_addr), .b_wdata(snd_dp_wdata), .b_wren(snd_dp_wren),
        .b_be(snd_dp_be), .b_q(snd_dp_q));

    // sound CPU reset, from the two write-only addresses
    wire sel_sndrst_on  = (a[23:8] == 16'hC801);
    wire sel_sndrst_off = (a[23:8] == 16'hC800);
    always_ff @(posedge clk) begin
        if (reset) snd_reset <= 1'b1;
        else if (cpu_wr && clkena) begin
            if (sel_sndrst_on)  snd_reset <= 1'b1;
            if (sel_sndrst_off) snd_reset <= 1'b0;
        end
    end

    // Video-visible memories: true dual port, CPU on A, renderer on B.
    rf_bram_tdp #(.AW(14)) u_pal (
        .clk(clk),
        .a_addr(a[14:1]), .a_wdata(cpu_dout), .a_wren(cpu_wr && sel_pal && clkena),
        .a_be(be), .a_q(pal_q),
        .b_addr(v_pal_addr), .b_wdata(16'd0), .b_wren(1'b0), .b_be(2'b00),
        .b_q(v_pal_q));

    rf_bram_tdp #(.AW(15)) u_spr (
        .clk(clk),
        .a_addr(a[15:1]), .a_wdata(cpu_dout), .a_wren(cpu_wr && sel_spr && clkena),
        .a_be(be), .a_q(spr_q),
        .b_addr(v_spr_addr), .b_wdata(16'd0), .b_wren(1'b0), .b_be(2'b00),
        .b_q(v_spr_q));

    rf_bram_tdp #(.AW(14)) u_pf (
        .clk(clk),
        .a_addr(a[14:1]), .a_wdata(cpu_dout), .a_wren(cpu_wr && sel_pf && clkena),
        .a_be(be), .a_q(pf_q),
        .b_addr(v_pf_addr), .b_wdata(16'd0), .b_wren(1'b0), .b_be(2'b00),
        .b_q(v_pf_q));

    rf_bram_tdp #(.AW(12)) u_text (
        .clk(clk),
        .a_addr(a[12:1]), .a_wdata(cpu_dout), .a_wren(cpu_wr && sel_text && clkena),
        .a_be(be), .a_q(text_q),
        .b_addr(v_text_addr), .b_wdata(16'd0), .b_wren(1'b0), .b_be(2'b00),
        .b_q(v_text_q));

    rf_bram_tdp #(.AW(12)) u_char (
        .clk(clk),
        .a_addr(a[12:1]), .a_wdata(cpu_dout), .a_wren(cpu_wr && sel_char && clkena),
        .a_be(be), .a_q(char_q),
        .b_addr(v_char_addr), .b_wdata(16'd0), .b_wren(1'b0), .b_be(2'b00),
        .b_q(v_char_q));

    rf_bram_tdp #(.AW(15)) u_line (
        .clk(clk),
        .a_addr(a[15:1]), .a_wdata(cpu_dout), .a_wren(cpu_wr && sel_line && clkena),
        .a_be(be), .a_q(line_q),
        .b_addr(v_line_addr), .b_wdata(16'd0), .b_wren(1'b0), .b_be(2'b00),
        .b_q(v_line_q));

    rf_bram_tdp #(.AW(12)) u_pivot (
        .clk(clk),
        .a_addr(a[12:1]), .a_wdata(cpu_dout), .a_wren(cpu_wr && sel_pivot && clkena),
        .a_be(be), .a_q(pivot_q),
        .b_addr(12'd0), .b_wdata(16'd0), .b_wren(1'b0), .b_be(2'b00),
        .b_q());

    // The row being displayed is implied by the address the video asks for
    // (addr[8:4] = ys[7:3]), so nothing in rf_video_pivot has to change and
    // the pipe bench is untouched.
    wire piv_busy;
    rf_pivot_bus #(.SEPARATE_INIT(EXTERNAL_WORKRAM),
        .BASE(EXTERNAL_WORKRAM?26'h1f00000:26'h0a00000)) u_pivot_bus (
        .init(memory_init),
        .reset    (reset),
        .clk_sys  (clk),
        .cpu_addr (a[15:1]),
        .cpu_din  (cpu_dout),
        .cpu_be   (be),
        .cpu_wr   (cpu_wr && sel_pivot && clkena),
        .cpu_busy (piv_busy),
        .row      (v_pivot_addr[8:4]),
        .v_addr   (v_pivot_addr),
        .v_q      (v_pivot_q),
        .clk_ram  (clk_ram),
        .ch_addr  (piv_ch_addr),
        .ch_din   (piv_ch_din),
        .ch_be    (piv_ch_be),
        .ch_rnw   (piv_ch_rnw),
        .ch_req   (piv_ch_req),
        .ch_ready (piv_ch_ready),
        .ch_dout  (piv_ch_dout));

    // ---- read mux --------------------------------------------------------
    // Registered one cycle to line up with the BRAM output, exactly like the
    // spike: the address is presented while clkena is low, the RAM registers
    // it, and the CPU samples data_in on the clkena pulse a cycle later.
    localparam [3:0] SRC_ROM=0, SRC_RAM=1, SRC_PAL=2, SRC_SPR=3, SRC_PF=4,
                     SRC_PFX=5, SRC_TEXT=6, SRC_CHAR=7, SRC_LINE=8,
                     SRC_PIVOT=9, SRC_DPRAM=10, SRC_CTRL=11, SRC_VCTRL=12,
                     SRC_ZERO=13;

    logic [3:0]  src;
    logic [3:0]  src_q;
    logic [15:0] ctrl_hold, vctrl_hold;

    always_comb begin
        if      (sel_rom)   src = SRC_ROM;
        else if (sel_ram)   src = SRC_RAM;
        else if (sel_pal)   src = SRC_PAL;
        else if (sel_spr)   src = SRC_SPR;
        else if (sel_pf)    src = SRC_PF;
        else if (sel_pfx)   src = SRC_PFX;
        else if (sel_text)  src = SRC_TEXT;
        else if (sel_char)  src = SRC_CHAR;
        else if (sel_line)  src = SRC_LINE;
        else if (sel_pivot) src = SRC_PIVOT;
        else if (sel_dpram) src = SRC_DPRAM;
        else if (sel_ctrl)  src = SRC_CTRL;
        else if (sel_vctrl) src = SRC_VCTRL;
        else                src = SRC_ZERO;   // romhi and everything unmapped
    end

    always_ff @(posedge clk) begin
        src_q      <= src;
        ctrl_hold  <= ctrl_q;
        vctrl_hold <= a[4] ? c1[a[3:1]] : c0[a[3:1]];
    end

    always_comb begin
        case (src_q)
            SRC_ROM:   cpu_din = prog_data_lat;
            SRC_RAM:   cpu_din = ram_q;
            SRC_PAL:   cpu_din = pal_q;
            SRC_SPR:   cpu_din = spr_q;
            SRC_PF:    cpu_din = pf_q;
            SRC_PFX:   cpu_din = pfx_q;
            SRC_TEXT:  cpu_din = text_q;
            SRC_CHAR:  cpu_din = char_q;
            SRC_LINE:  cpu_din = line_q;
            SRC_PIVOT: cpu_din = pivot_q;
            SRC_DPRAM: cpu_din = dpram_q;
            SRC_CTRL:  cpu_din = ctrl_hold;
            SRC_VCTRL: cpu_din = vctrl_hold;
            default:   cpu_din = 16'h0000;
        endcase
    end

    // ---- KIRAMEKI sound-ROM bank -----------------------------------------
    // taito_f3.cpp sound_bankswitch_w, verbatim:
    //
    //     idx = (offset << 1) & 0x1e;  if (ACCESSING_BITS_0_15) idx += 1;
    //     if (idx >= 8) idx -= 8;      m_taito_en->set_bank(1, idx);
    //
    // `offset` is a LONGWORD index, so offset<<1 is a[6:1] shifted -- and
    // masking with 0x1e keeps four bits. Only set_bank(1, ...) is ever
    // called, i.e. only cpubank2, the 0xC20000 window; banks 1 and 3 keep the
    // linear mapping this core already gives them. The wrap at 8 makes the
    // index three bits.
    logic [2:0] snd_bank;
    // Belt and braces after the no-sound regression: the C20000 window uses
    // the ordinary linear mapping until the game has actually WRITTEN the
    // bank register. Only Kirameki Star Road ever does. So no other game can
    // be affected by this path at all, whatever the reset value happens to
    // be -- which is the property that was missing when it shipped broken.
    logic       snd_bank_set;
    always_ff @(posedge clk) begin
        // RESETS TO 1, NOT 0. MAME sets the three sound-CPU windows with
        // set_entry(i % max) for i = 0,1,2, so cpubank2 -- the C20000 window
        // this index drives -- starts on ENTRY 1. Resetting it to 0 pointed
        // that window at entry 0, so the sound 68000 executed the wrong
        // 128 KB in EVERY game and no game had sound. Reported from a board
        // 2026-09-08 against build 08154107: "installed the 20260908 version,
        // however I didn't get any sound, reverted and got the sound back".
        if (reset) begin snd_bank <= 3'd1; snd_bank_set <= 1'b0; end
        else if (cpu_wr && sel_sndbank && clkena) begin
            // a[6:2] is the longword offset; <<1 then &0x1e is a[5:2],0.
            // The low half being written adds one, exactly as ACCESSING_BITS_0_15.
            snd_bank     <= {a[4:2], 1'b0} + {2'd0, be[0]};
            snd_bank_set <= 1'b1;
        end
    end
    assign snd_bank_o = snd_bank;
    assign snd_bank_en_o = snd_bank_set;

endmodule
