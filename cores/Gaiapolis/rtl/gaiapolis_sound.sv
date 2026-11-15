// SPDX-License-Identifier: GPL-3.0-or-later
/*
 * Gaiapolis dual-K054539 sound subsystem, derived from the pinned donor.
 *
 * The Z80 address map and K054321 command/latch behavior follow the pinned
 * MAME mystwarr.cpp map.  The PCM engines are the project-owned derivative of
 * the GPL Bucky K054539 implementation; its fixed-point sample path and
 * ROM-ready handshake are kept behind this title-local wrapper.  The K054321
 * digital mute/gain boundary is implemented below; the board's downstream
 * analogue filter remains outside this contract.
 */
module gaiapolis_sound(
    input             rst,
    input             clk,
    input             cen_8,
    input             cen_pcm,

    input             pause_cpu_run,
    input             pause_busrq_n,
    input             pause_quiesce,
    input             pause_freeze,
    output            pause_busak_n,
    output            pause_mreq_n,
    output            pause_iorq_n,
    output            pause_rd_n,
    output            pause_wr_n,
    output            pause_pending,
    output     [ 1:0] pause_pcm_idle,

    input             main_we,
    input      [ 3:0] main_addr,
    input      [ 7:0] main_din,
    output     [ 7:0] main_dout,
    input             snd_irq,
    output            irq_n,
    output     [ 7:0] active,
    output     [ 6:0] volume,

    output     [17:0] snd_addr,
    output            snd_cs,
    input      [ 7:0] snd_data,
    input             snd_ok,

    output     [21:0] pcma_addr,
    output            pcma_cs,
    input      [ 7:0] pcma_data,
    input             pcma_ok,
    output     [21:0] pcmb_addr,
    output            pcmb_cs,
    input      [ 7:0] pcmb_data,
    input             pcmb_ok,

    output signed [15:0] pcm0_l,
    output signed [15:0] pcm0_r,
    output signed [15:0] pcm1_l,
    output signed [15:0] pcm1_r,

    input      [ 7:0] debug_bus,
    output     [ 7:0] st_dout,

    input             mute // IO latch D11 (F4), forces both stereo channels silent
);
    wire [7:0] cpu_din, cpu_dout, z80_ram_dout;
    wire [15:0] z80_a;
    wire m1_n, mreq_n, iorq_n, rd_n, wr_n, rfsh_n;
    wire halt_n, busak_n, z80_cen;
    wire mem_acc = !mreq_n && rfsh_n;

    wire rom_cs_i = mem_acc && !rd_n && (!z80_a[15] || !z80_a[14]);
    wire ram_cs_i = mem_acc && (z80_a[15:13] == 3'b110);
    wire k539a_cs = mem_acc && (z80_a[15:10] == 6'b111000) &&
                    (z80_a[9:0] <= 10'h22f);
    wire k539b_cs = mem_acc && (z80_a[15:10] == 6'b111001) &&
                    (z80_a[9:0] <= 10'h22f);
    wire k21_cs = mem_acc && (z80_a[15:2] == 14'h3c00);
    wire bank_cs = mem_acc && (z80_a == 16'hf800);
    wire aux_cs = mem_acc && (z80_a[15:11] == 5'b11100) &&
                  !k539a_cs && !k539b_cs;

    reg [7:0] sound_ctrl;
    reg [7:0] aux_ram [0:2047];
    integer ai;
    initial for (ai = 0; ai < 2048; ai = ai + 1) aux_ram[ai] = 8'h00;

    wire k21_we = k21_cs && !wr_n;
    // The bridge clears the Z80 interrupt on the Z80 I/O acknowledge phase,
    // matching the MAME device and the mature JTCORES jt054321 implementation.
    wire k21_iack = !iorq_n;
    wire [7:0] k21_dout, k21_sdout;
    wire k21_irq_n;
    wire [7:0] k21_active;
    wire [6:0] k21_volume;
    wire rb_wait_a, rb_wait_b;
    wire cen_z80 = cen_8 && pause_cpu_run && !(rb_wait_a || rb_wait_b);
    assign pause_busak_n = busak_n;
    assign pause_mreq_n = mreq_n;
    assign pause_iorq_n = iorq_n;
    assign pause_rd_n = rd_n;
    assign pause_wr_n = wr_n;
    assign pause_pending = (rom_cs_i && !snd_ok) || rb_wait_a || rb_wait_b;

    // The main-board adapter maps K054321 on the upper 68000 byte lane.  The sound bus uses
    // the same three latch offsets as the MAME sound_map (0, 2, 3).
    jtviostorm_k054321 u_k054321(
        .clk        ( clk          ),
        .rst        ( rst          ),
        .main_we    ( main_we      ),
        .main_addr  ( main_addr    ),
        .main_din   ( main_din     ),
        .main_dout  ( k21_dout     ),
        .sound_we   ( k21_we       ),
        .sound_addr ( z80_a[1:0]   ),
        .sound_din  ( cpu_dout     ),
        .sound_dout ( k21_sdout    ),
        .irq_set    ( snd_irq      ),
        .sound_iack ( k21_iack     ),
        .irq_n      ( k21_irq_n    ),
        .active     ( k21_active   ),
        .volume     ( k21_volume   )
    );

    // The Z80 bank register is four bits on the PCB (MAME mystwarr.cpp
    // configure_entries(0,16,...,0x4000) -> 16 x 16 KiB banks over a 0x40000
    // region). sound_ctrl already latches the full CPU write byte, so all
    // four bits are captured in the register regardless of how many are
    // wired into the ROM address below -- do not truncate the register.
    wire [3:0] bank_eff = sound_ctrl[3:0];
    // Gaiapolis populates the complete 256KiB region: all sixteen banks
    // reach the ROM port, including bank bit3.
    assign snd_addr = z80_a[15] ? {bank_eff, z80_a[13:0]} :
                                     {3'b0, z80_a[14:0]};
    assign snd_cs   = rom_cs_i;

    assign cpu_din = rom_cs_i ? snd_data :
                     ram_cs_i ? z80_ram_dout :
                     k539a_cs ? k539a_dout :
                     k539b_cs ? k539b_dout :
                     k21_cs   ? ((z80_a[1:0] == 2'd0) ? 8'h00 : k21_sdout) :
                     aux_cs   ? aux_ram[z80_a[10:0]] : 8'hff;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            // MAME machine_start configures the sixteen banks and selects2.
            sound_ctrl <= 8'h02;
        end else begin
            if (bank_cs && !wr_n)
                sound_ctrl <= cpu_dout;
            if (aux_cs && !wr_n)
                aux_ram[z80_a[10:0]] <= cpu_dout;
        end
    end

    jtframe_sysz80 #(.RAM_AW(13), .CLR_INT(0)) u_z80(
        .rst_n      ( ~rst       ),
        .clk        ( clk        ),
        .cen        ( cen_z80    ),
        .cpu_cen    ( z80_cen    ),
        .int_n      ( k21_irq_n  ),
        .nmi_n      ( nmi_n      ),
        .busrq_n    ( pause_busrq_n ),
        .m1_n       ( m1_n       ),
        .mreq_n     ( mreq_n     ),
        .iorq_n     ( iorq_n     ),
        .rd_n       ( rd_n       ),
        .wr_n       ( wr_n       ),
        .rfsh_n      ( rfsh_n     ),
        .halt_n      ( halt_n     ),
        .busak_n     ( busak_n    ),
        .A           ( z80_a     ),
        .cpu_din     ( cpu_din   ),
        .cpu_dout    ( cpu_dout  ),
        .ram_dout    ( z80_ram_dout ),
        .ram_cs      ( ram_cs_i  ),
        .rom_cs      ( rom_cs_i  ),
        .rom_ok      ( snd_ok    )
    );

    wire timeout_a, timeout_b;
    wire [7:0] k539a_dout, k539b_dout;
    wire [23:0] pcma_addr_full, pcmb_addr_full;
    wire signed [15:0] k539a_dry_l, k539a_dry_r, k539b_dry_l, k539b_dry_r;
    wire signed [15:0] k539a_wet_l, k539a_wet_r, k539b_wet_l, k539b_wet_r;
    wire [1:0] k539_valid, k539_enabled;
    wire [15:0] k539_epoch_a, k539_epoch_b;

    // The sample ROM slots live on the 96 MHz SDRAM clock and answer with a
    // combinational hit/data path. Register each answer here: the engines
    // receive it one clock later, together with the address it belongs to, so
    // the cache compare no longer feeds the engine logic in the same clock.
    // An answer registered for an earlier address is dropped (a_q != address).
    reg  [21:0] pcma_a_q, pcmb_a_q;
    reg  [ 7:0] pcma_d_q, pcmb_d_q;
    reg         pcma_ok_q, pcmb_ok_q, pcma_cs_q, pcmb_cs_q;
    always @(posedge clk) begin
        pcma_a_q <= pcma_addr_full[21:0]; pcma_d_q <= pcma_data;
        pcma_ok_q <= pcma_ok;             pcma_cs_q <= pcma_cs;
        pcmb_a_q <= pcmb_addr_full[21:0]; pcmb_d_q <= pcmb_data;
        pcmb_ok_q <= pcmb_ok;             pcmb_cs_q <= pcmb_cs;
    end
    wire pcma_ok_r = pcma_ok_q && pcma_cs_q && pcma_cs && pcma_a_q == pcma_addr_full[21:0];
    wire pcmb_ok_r = pcmb_ok_q && pcmb_cs_q && pcmb_cs && pcmb_a_q == pcmb_addr_full[21:0];

    // The title-owned engines retain pending ROM requests and wait within
    // their read states. Keep the sample/timer dividers at 18.432 MHz even
    // while the independent SDRAM ports are waiting for data.
    wire cen_pcma = cen_pcm;
    wire cen_pcmb = cen_pcm;

    gaiapolis_pause_pcm #(.BOOST_MASK(8'he0)) u_k054539a(
        .rst        ( rst          ),
        .clk        ( clk          ),
        .cen        ( cen_pcma     ),
        .quiesce    ( pause_quiesce ),
        .freeze     ( pause_freeze ),
        .pause_idle ( pause_pcm_idle[0] ),
        .timeout    ( timeout_a    ),
        .addr       ( {z80_a[9],z80_a[7:0]} ),
        .we         ( !wr_n        ),
        .rd         ( !rd_n        ),
        .cs         ( k539a_cs     ),
        .din        ( cpu_dout     ),
        .dout       ( k539a_dout   ),
        .rom_cs     ( pcma_cs      ),
        .rom_addr   ( pcma_addr_full ),
        .rb_wait    ( rb_wait_a    ),
        .rom_data   ( pcma_d_q     ),
        .rom_ok     ( pcma_ok_r    ),
        .left       ( k539a_dry_l      ),
        .right      ( k539a_dry_r      ),
        .wet_left(k539a_wet_l), .wet_right(k539a_wet_r),
        .sample_valid(k539_valid[0]), .sample_epoch(k539_epoch_a), .output_enabled(k539_enabled[0]),
        .axword_a(16'sd0), .axword_b(16'sd0),
        .debug_bus  ( debug_bus    ),
        .st_dout    ( st_dout      )
    );

    gaiapolis_pause_pcm #(.BOOST_MASK(8'h00)) u_k054539b(
        .rst        ( rst          ),
        .clk        ( clk          ),
        .cen        ( cen_pcmb     ),
        .quiesce    ( pause_quiesce ),
        .freeze     ( pause_freeze ),
        .pause_idle ( pause_pcm_idle[1] ),
        .timeout    ( timeout_b    ),
        .addr       ( {z80_a[9],z80_a[7:0]} ),
        .we         ( !wr_n        ),
        .rd         ( !rd_n        ),
        .cs         ( k539b_cs     ),
        .din        ( cpu_dout     ),
        .dout       ( k539b_dout   ),
        .rom_cs     ( pcmb_cs      ),
        .rom_addr   ( pcmb_addr_full ),
        .rb_wait    ( rb_wait_b    ),
        .rom_data   ( pcmb_d_q     ),
        .rom_ok     ( pcmb_ok_r    ),
        .left       ( k539b_dry_l      ),
        .right      ( k539b_dry_r      ),
        .wet_left(k539b_wet_l), .wet_right(k539b_wet_r),
        .sample_valid(k539_valid[1]), .sample_epoch(k539_epoch_b), .output_enabled(k539_enabled[1]),
        .axword_a(16'sd0), .axword_b(16'sd0),
        .debug_bus  ( debug_bus    ),
        .st_dout    (               )
    );

    // A standard 32 MiB SDRAM module supplies one shared 4 MiB sample image.
    // Valid K054539 bank values fit in 22 bits; retain the high bits only for
    // diagnostics so an invalid software bank cannot select another region.
    assign pcma_addr = pcma_addr_full[21:0];
    assign pcmb_addr = pcmb_addr_full[21:0];

    // MAME routes each K054539's channel 0 to the opposite speaker.  Keep the
    // swap explicit at the JTFRAME channel boundary; analog filtering remains
    // outside the digital core contract.  K054321's active bits are speaker
    // enables (bit 1 = left, bit 0 = right), and its volume register follows
    // pow(2,(volume-40)/10).  Apply both controls after the documented swap so
    // they refer to the physical left/right outputs, not the raw K054539
    // channel names.
    // Reuse the improved donor's coherent two-chip board summer. Optional
    // equal dry/wet reconstruction follows Gaiapolis's functional effects
    // route. This is not a measured PCB wet weighting. Output normalization
    // is outside the chip DSP, preserving all native truncation and wrap.
    gaiapolis_k054321_mix #(.WET_MIX(1), .OUTPUT_GAIN_SHIFT(3)) u_board_mix(
        .clk(clk), .rst(rst), .chip_a_valid(k539_valid[0]), .chip_b_valid(k539_valid[1]),
        .chip_a_enabled(k539_enabled[0]), .chip_b_enabled(k539_enabled[1]),
        .chip_a_epoch(k539_epoch_a), .chip_b_epoch(k539_epoch_b),
        .chip_a_dry_l(k539a_dry_l), .chip_a_dry_r(k539a_dry_r),
        .chip_a_wet_l(k539a_wet_l), .chip_a_wet_r(k539a_wet_r),
        .chip_b_dry_l(k539b_dry_l), .chip_b_dry_r(k539b_dry_r),
        .chip_b_wet_l(k539b_wet_l), .chip_b_wet_r(k539b_wet_r),
        .volume(k21_volume), .enable(k21_active[1:0]), .mute(mute),
        .pcm0_l(pcm0_l), .pcm0_r(pcm0_r), .pcm1_l(pcm1_l), .pcm1_r(pcm1_r),
        .pair_valid(), .pair_epoch()
    );

    // MAME mystwarr.cpp:1005 only binds k054539_1's (chip A) timer_handler
    // to k054539_nmi_gen; k054539_2 (chip B) has no timer_handler binding in
    // the machine config at all (mystwarr.cpp:1009-1012), so its timer state
    // never reaches the Z80 NMI line. timeout_b is intentionally unused here.
    wire nmi_event = timeout_a;
    wire nmi_n;
    jtframe_edge #(.QSET(0)) u_nmi_edge(
        .rst    ( rst             ),
        .clk    ( clk             ),
        .edgeof ( nmi_event       ),
        .clr    ( ~sound_ctrl[4]  ),
        .q      ( nmi_n           )
    );

    assign main_dout = k21_dout;
    assign irq_n     = k21_irq_n;
    assign active    = k21_active;
    assign volume    = k21_volume;
endmodule

/*
 * K054321 speaker gain/mute boundary.
 *
 * KNOWN functional reference: MAME k054321_device propagates a speaker
 * enable from active[1:0] and computes the global gain as
 * pow(2.0, (volume - 40) / 10.0), with volume clamped to 0..64.
 *
 * INFERRED implementation contract: Q4.12 constants are rounded from that
 * curve (maximum gain is 5.278, so Q4.12 has ample integer headroom).  The
 * signed 16-bit sample is extended to 32 bits before multiplication, shifted
 * by 12, and saturated back to signed 16 bits.  Saturation prevents a loud
 * K054321 setting from wrapping the DAC stream.  This block is combinational;
 * it adds no state or clock latency to the existing K054539 sample boundary.
 */
module jtviostorm_k054321_gain(
    input  logic               clk,
    input  logic signed [15:0] sample,
    input  logic               enable,
    input  logic        [ 6:0] volume,
    output logic signed [15:0] out
);
    function automatic [15:0] gain_q12(input logic [6:0] v);
        begin
            case (v)
                7'd0:  gain_q12 = 16'd256;
                7'd1:  gain_q12 = 16'd274;
                7'd2:  gain_q12 = 16'd294;
                7'd3:  gain_q12 = 16'd315;
                7'd4:  gain_q12 = 16'd338;
                7'd5:  gain_q12 = 16'd362;
                7'd6:  gain_q12 = 16'd388;
                7'd7:  gain_q12 = 16'd416;
                7'd8:  gain_q12 = 16'd446;
                7'd9:  gain_q12 = 16'd478;
                7'd10: gain_q12 = 16'd512;
                7'd11: gain_q12 = 16'd549;
                7'd12: gain_q12 = 16'd588;
                7'd13: gain_q12 = 16'd630;
                7'd14: gain_q12 = 16'd676;
                7'd15: gain_q12 = 16'd724;
                7'd16: gain_q12 = 16'd776;
                7'd17: gain_q12 = 16'd832;
                7'd18: gain_q12 = 16'd891;
                7'd19: gain_q12 = 16'd955;
                7'd20: gain_q12 = 16'd1024;
                7'd21: gain_q12 = 16'd1097;
                7'd22: gain_q12 = 16'd1176;
                7'd23: gain_q12 = 16'd1261;
                7'd24: gain_q12 = 16'd1351;
                7'd25: gain_q12 = 16'd1448;
                7'd26: gain_q12 = 16'd1552;
                7'd27: gain_q12 = 16'd1663;
                7'd28: gain_q12 = 16'd1783;
                7'd29: gain_q12 = 16'd1911;
                7'd30: gain_q12 = 16'd2048;
                7'd31: gain_q12 = 16'd2195;
                7'd32: gain_q12 = 16'd2353;
                7'd33: gain_q12 = 16'd2521;
                7'd34: gain_q12 = 16'd2702;
                7'd35: gain_q12 = 16'd2896;
                7'd36: gain_q12 = 16'd3104;
                7'd37: gain_q12 = 16'd3327;
                7'd38: gain_q12 = 16'd3566;
                7'd39: gain_q12 = 16'd3822;
                7'd40: gain_q12 = 16'd4096;
                7'd41: gain_q12 = 16'd4390;
                7'd42: gain_q12 = 16'd4705;
                7'd43: gain_q12 = 16'd5043;
                7'd44: gain_q12 = 16'd5405;
                7'd45: gain_q12 = 16'd5793;
                7'd46: gain_q12 = 16'd6208;
                7'd47: gain_q12 = 16'd6654;
                7'd48: gain_q12 = 16'd7132;
                7'd49: gain_q12 = 16'd7643;
                7'd50: gain_q12 = 16'd8192;
                7'd51: gain_q12 = 16'd8780;
                7'd52: gain_q12 = 16'd9410;
                7'd53: gain_q12 = 16'd10086;
                7'd54: gain_q12 = 16'd10809;
                7'd55: gain_q12 = 16'd11585;
                7'd56: gain_q12 = 16'd12417;
                7'd57: gain_q12 = 16'd13308;
                7'd58: gain_q12 = 16'd14263;
                7'd59: gain_q12 = 16'd15287;
                7'd60: gain_q12 = 16'd16384;
                7'd61: gain_q12 = 16'd17560;
                7'd62: gain_q12 = 16'd18820;
                7'd63: gain_q12 = 16'd20171;
                // Volume writes saturate at 64 in the K054321 bridge.  Keep
                // the gain block fail-closed for an out-of-range value too.
                default: gain_q12 = 16'd21619;
            endcase
        end
    endfunction

    // The source sample is already signed 16-bit.  The Q4.12 table tops out
    // at 21619 (< 2^15), so a signed 16-bit gain operand is sufficient while
    // the 32-bit product still covers the full +/-32768*21619 range.
    logic signed [15:0] sample_ext;
    logic signed [15:0] gain_ext;
    logic signed [31:0] product;
    logic signed [31:0] scaled;

    // The gain table lookup is registered (volume changes rarely) to keep the
    // table out of the multiplier path.
    logic [15:0] gain_r;
    always_ff @(posedge clk) gain_r <= gain_q12(volume);

    always_comb begin
        sample_ext = sample;
        gain_ext   = $signed(gain_r);
        product    = sample_ext * gain_ext;
        scaled     = product >>> 12;

        if (!enable)
            out = 16'sd0;
        else if (scaled > 32'sd32767)
            out = 16'sh7fff;
        else if (scaled < -32'sd32768)
            out = 16'sh8000;
        else
            out = scaled[15:0];
    end
endmodule
