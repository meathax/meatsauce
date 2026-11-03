// ThunderJaws JSA II target wrapper around the pinned Skull & Crossbones JSA
// device implementations. Host-side command and response pins follow MAME's
// Atari sound communication device; there is no SCOM serial link on this path.
module thunderjaws_sound #(
    parameter integer SOUND_RESET_SYS_CYCLES = 1152,
    // MAME's JSA periodic IRQ chain divides 3.579545 MHz by 4*16*16*14.
    // At ce_ym this is 1024*14 enables; keep POST at 14 below.
    parameter integer IRQ_PRE = 1024,
    parameter integer IRQ_POST = 14,
    // T65 registers IRQ_n_o, then evaluates it at MCycle==LCycle. In the
    // sealed capture the timer terminal at sys 345205 follows the required
    // T65 input-sample edge at sys 345168. Lead the CPU-facing IRQ level by
    // four YM enables (two T65 enables); the divider terminal remains exact.
    parameter integer IRQ_SAMPLE_ADVANCE_YM = 4
) (
    input  logic        clk_sys,
    input  logic        pause,
    input  logic        init_reset,
    input  logic        sound_reset_request,
    input  logic        sound_command_write,
    input  logic  [7:0] sound_command_data,
    input  logic        sound_response_ack,
    input  logic        self_test,
    input  logic  [2:0] coin,

    input  logic        sound_rom_wr,
    input  logic [15:0] sound_rom_addr,
    input  logic  [7:0] sound_rom_data,
    input  logic        oki_rom_ack,
    input  logic  [7:0] oki_rom_data,
    output logic        oki_rom_req,
    output logic [17:0] oki_rom_addr,

    output logic  [7:0] main_response_data,
    output logic        main_response_ready,
    output logic        main_irq6,
    output logic signed [15:0] ym_audio_ch1,
    output logic signed [15:0] ym_audio_ch2,
    output logic signed [17:0] oki_audio,

    output logic        ce_ym_3m579545,
    output logic        ce_t65_1m789772,
    output logic        ce_oki_1m193181,
    output logic  [6:0] ce_phase_debug,
    output logic        cpu_reset_n_debug,
    output logic [15:0] cpu_address_debug,
    output logic  [7:0] cpu_read_data_debug,
    output logic  [7:0] cpu_write_data_debug,
    output logic        cpu_read_not_write_debug,
    output logic        cpu_sync_debug,
    output logic        command_pending_debug,
    output logic  [7:0] rdio_data_debug,
    output logic        response_write_debug
);
    localparam integer RESET_COUNT_WIDTH = $clog2(SOUND_RESET_SYS_CYCLES + 1);

    logic [RESET_COUNT_WIDTH-1:0] reset_count = '0;
    logic [7:0] command_latch = 8'h00;
    logic command_pending = 1'b0;

    wire sound_reset_active = (reset_count != '0);
    wire ce_ym;
    wire ce_t65;
    wire ce_oki;
    wire [6:0] ce_phase;

    wire [1:0] rom_bank;
    wire cctr1_unused, cctr2_unused, cctr_or_unused;
    wire vfreq;
    wire okires_n, yamres_n;
    wire lpf_unused;
    wire sp0;
    wire [2:0] ym_volume;
    wire signed [15:0] ym_raw_ch1, ym_raw_ch2;
    wire signed [17:0] oki_raw;
    wire [7:0] rdio_donor_data;
    wire [7:0] rdio_data;

    wire ym_cs, ym_a0, ym_we, ym_rd;
    wire [7:0] ym_dout, ym_din;
    wire ym_irq, ym_ct1, ym_ct2_unused;
    wire [7:0] oki_status;
    wire sel_rdv, sel_rdp, sel_rdio, sel_irqack;
    wire sel_wrv, sel_wrp, sel_wrio, sel_mix;
    wire [15:0] cpu_address;
    wire [7:0] cpu_dout, cpu_din;
    wire cpu_rnw, cpu_sync, irq_periodic;
    wire board_cpu_reset_n;

    thunderjaws_sound_ce u_ce (
        .pause(pause),
        .clk_sys(clk_sys),
        .ce_ym_3m579545(ce_ym),
        .ce_t65_1m789772(ce_t65),
        .ce_oki_1m193181(ce_oki),
        .phase_debug(ce_phase)
    );

    // Provisional verification pulse: 1152 sys clocks cover 48 T65 enables,
    // 96 YM enables, and 32 OKI enables at target rates. MAME models the
    // sound-reset callback as an instantaneous CPU reset event, so this width
    // is not MAME timing-qualified until reset/command overlap is probed.
    // The divider itself runs through both POR and sound-reset intervals.
    always_ff @(posedge clk_sys) begin
        if (init_reset) begin
            reset_count <= '0;
            command_latch <= 8'h00;
            command_pending <= 1'b0;
            main_response_data <= 8'h00;
            main_response_ready <= 1'b0;
        end else begin
            if (sound_reset_request) begin
                reset_count <= RESET_COUNT_WIDTH'(SOUND_RESET_SYS_CYCLES);
                main_response_ready <= 1'b0;
            end else if (sound_reset_active) begin
                reset_count <= reset_count - RESET_COUNT_WIDTH'(1);
            end

            // MAME's sound reset clears the response side, but leaves a
            // pending main command and its NMI line intact.
            if (sound_command_write) begin
                command_latch <= sound_command_data;
                command_pending <= 1'b1;
            end else if (sel_rdp && cpu_rnw) begin
                command_pending <= 1'b0;
            end

            if (sound_response_ack)
                main_response_ready <= 1'b0;
            if (sel_wrp && !cpu_rnw) begin
                main_response_data <= cpu_dout;
                main_response_ready <= 1'b1;
            end
            if (sound_reset_request)
                main_response_ready <= 1'b0;
        end
    end

    assign main_irq6 = main_response_ready;
    assign command_pending_debug = command_pending;
    assign rdio_data_debug = rdio_data;
    assign response_write_debug = sel_wrp && !cpu_rnw;

    // Adapt the donor LS240 port to ThunderJaws' MAME input declaration.
    // D6 is the active-low NMI sense; D4 and D3 are unused inputs whose
    // default MAME value is zero. Three coin inputs occupy D2:D0.
    assign rdio_data = {rdio_donor_data[7], ~command_pending,
        rdio_donor_data[5], 2'b00, rdio_donor_data[2:0]};

    skullxbo_snd_io u_io (
        .clk(clk_sys),
        .reset_n(~init_reset),
        .wrio_stb(sel_wrio && !cpu_rnw),
        .wrio_data(cpu_dout),
        .mix_stb(sel_mix && !cpu_rnw),
        .mix_data(cpu_dout),
        .self_test(self_test),
        .cmd_pending(command_pending),
        .resp_pending(main_response_ready),
        .coin({1'b0, coin}),
        .mame_polarity(1'b0),
        .bank(rom_bank),
        .cctr2(cctr2_unused),
        .cctr1(cctr1_unused),
        .cctr_wired_or(cctr_or_unused),
        .vfreq(vfreq),
        .okires_n(okires_n),
        .yamres_n(yamres_n),
        .lpf(lpf_unused),
        .ym_vol(ym_volume),
        .sp0(sp0),
        .rdio_data(rdio_donor_data)
    );

    skullxbo_snd_bus #(
        .IRQ_PRE(IRQ_PRE),
        .IRQ_POST(IRQ_POST),
        .IRQ_SAMPLE_ADVANCE_YM(IRQ_SAMPLE_ADVANCE_YM),
        .MAME_FREERUN(1'b1)
    ) u_bus (
        .clk(clk_sys),
        .ce_1m79(ce_t65),
        .ce_3m58(ce_ym),
        .por(init_reset),
        .sndres(sound_reset_active),
        .scom_full(command_pending),
        .ym_irq(ym_irq),
        .bank(rom_bank),
        .rdp_data(command_latch),
        .rdio_data(rdio_data),
        .rdv_data(oki_status),
        .ym_cs(ym_cs),
        .ym_a0(ym_a0),
        .ym_we(ym_we),
        .ym_rd(ym_rd),
        .ym_dout(ym_dout),
        .ym_din(ym_din),
        .sel_rdv(sel_rdv),
        .sel_rdp(sel_rdp),
        .sel_rdio(sel_rdio),
        .sel_irqack(sel_irqack),
        .sel_wrv(sel_wrv),
        .sel_wrp(sel_wrp),
        .sel_wrio(sel_wrio),
        .sel_mix(sel_mix),
        .rom_wr(sound_rom_wr),
        .rom_wr_addr(sound_rom_addr),
        .rom_wr_data(sound_rom_data),
        .reset_n(board_cpu_reset_n),
        .irq_periodic(irq_periodic),
        .cpu_addr(cpu_address),
        .cpu_dout(cpu_dout),
        .cpu_din(cpu_din),
        .cpu_rnw(cpu_rnw),
        .cpu_sync(cpu_sync)
    );

    skullxbo_ym u_ym (
        .clk(clk_sys),
        .cen(ce_ym),
        .cen_p1(ce_t65),
        .yamres_n(yamres_n),
        .ym_cs(ym_cs),
        .ym_a0(ym_a0),
        .ym_we(ym_we),
        .ym_dout(ym_dout),
        .ym_din(ym_din),
        .ym_irq(ym_irq),
        .sample(),
        .ct1(ym_ct1),
        .ct2(ym_ct2_unused),
        .aud_ch1(ym_raw_ch1),
        .aud_ch2(ym_raw_ch2)
    );

    skullxbo_oki u_oki (
        .clk(clk_sys),
        .ce_1m19(ce_oki),
        .okires_n(okires_n),
        .vfreq(vfreq),
        .wr_stb(sel_wrv && !cpu_rnw),
        .wr_data(cpu_dout),
        .rd_stb(sel_rdv && cpu_rnw),
        .rd_data(oki_status),
        .oki_req(oki_rom_req),
        .oki_addr(oki_rom_addr),
        .oki_ack(oki_rom_ack),
        .oki_data(oki_rom_data),
        .audio(),
        .audio_wide(oki_raw)
    );

    // MAME JSA-II routes each YM output at 0.60 * MIX[3:1]/7 and OKI at
    // 0.75 * (MIX[0] ? 1.0 : 0.5) * YM2151 CT1. Export scaled samples so the
    // game-level mixer sums these directly without applying gains again.
    thunderjaws_sound_mix u_mix (
        .ym_raw_ch1(ym_raw_ch1),
        .ym_raw_ch2(ym_raw_ch2),
        .oki_raw(oki_raw),
        .ym_volume(ym_volume),
        .oki_volume_full(sp0),
        .ym_ct1(ym_ct1),
        .ym_audio_ch1(ym_audio_ch1),
        .ym_audio_ch2(ym_audio_ch2),
        .oki_audio(oki_audio)
    );

    assign ce_ym_3m579545 = ce_ym;
    assign ce_t65_1m789772 = ce_t65;
    assign ce_oki_1m193181 = ce_oki;
    assign ce_phase_debug = ce_phase;
    assign cpu_reset_n_debug = board_cpu_reset_n;
    assign cpu_address_debug = cpu_address;
    assign cpu_read_data_debug = cpu_din;
    assign cpu_write_data_debug = cpu_dout;
    assign cpu_read_not_write_debug = cpu_rnw;
    assign cpu_sync_debug = cpu_sync;
endmodule

module thunderjaws_sound_mix (
    input  logic signed [15:0] ym_raw_ch1,
    input  logic signed [15:0] ym_raw_ch2,
    input  logic signed [17:0] oki_raw,
    input  logic        [2:0] ym_volume,
    input  logic              oki_volume_full,
    input  logic              ym_ct1,
    output logic signed [15:0] ym_audio_ch1,
    output logic signed [15:0] ym_audio_ch2,
    output logic signed [17:0] oki_audio
);

    // Fold 3*volume into the reciprocal coefficient: one signed16x26 product.
    // K=958699 gives exact floor(m/35), m<=688128. For negative p,
    // ceil(p*K/2^25) is trunc(p/35); K is odd and 0<abs(p)<2^25,
    // so its low25 bits cannot all vanish and floor+1 is exact.
    function automatic logic signed [15:0] scale_ym(
        input logic signed [15:0] sample,input logic [2:0] volume
    );
        logic signed [25:0] coefficient;
        logic signed [41:0] product;
        logic signed [15:0] quotient;
        begin
            case(volume)
              0:coefficient=26'sd0;
              1:coefficient=26'sd2876097;
              2:coefficient=26'sd5752194;
              3:coefficient=26'sd8628291;
              4:coefficient=26'sd11504388;
              5:coefficient=26'sd14380485;
              6:coefficient=26'sd17256582;
              7:coefficient=26'sd20132679;
            endcase
            product=$signed(sample)*coefficient;
            quotient=$signed(product[40:25]);
            scale_ym=quotient+(product[41] ? 16'sd1 : 16'sd0);
        end
    endfunction
    function automatic logic signed [17:0] scale_oki(
        input logic signed [17:0] sample,input logic full_volume
    );
        logic signed [19:0] product;
        logic [18:0] magnitude;
        logic [17:0] quotient;
        begin
            product=$signed(sample)*20'sd3;
            magnitude=product[19] ? (~product[18:0]+19'd1) : product[18:0];
            quotient=full_volume ? magnitude>>2 : magnitude>>3;
            scale_oki=product[19] ? -$signed(quotient) : $signed(quotient);
        end
    endfunction

    always_comb begin
        ym_audio_ch1=scale_ym(ym_raw_ch1,ym_volume);
        ym_audio_ch2=scale_ym(ym_raw_ch2,ym_volume);
        oki_audio=!ym_ct1 ? 18'sd0 : scale_oki(oki_raw,oki_volume_full);
    end
endmodule

// Mono JSA output. FM is 6.02 dB lower relative to sampled effects/voices.
// Keep the four-voice OKI sum wide: lowering a clipped sample cannot repair it.
// At maximum legal chip/MIX levels, |YM1/2 + YM2/2 + OKI| <= 117964.
// The /4 master therefore stays below 29492, with >0.91 dB of headroom.
module thunderjaws_audio_output (
    input logic signed [15:0] ym1, ym2,
    input logic signed [17:0] oki,
    output logic signed [15:0] audio
);
    logic signed [16:0] fm_sum;
    logic signed [18:0] mix_sum;
    logic [18:0] magnitude;
    always_comb begin
        fm_sum = $signed({ym1[15],ym1}) + $signed({ym2[15],ym2});
        // Truncate toward zero to preserve polarity and digital silence.
        mix_sum = $signed(fm_sum / 17'sd2) + $signed({oki[17],oki});
        magnitude = mix_sum[18] ? -mix_sum : mix_sum;
        audio = mix_sum[18] ? -$signed(magnitude >> 2) : $signed(magnitude >> 2);
    end
endmodule
