module argus_sound_chips (
    input wire clk_sys, reset, ce_opn, pause_game,
    input wire [1:0] game_id, opn_select,
    input wire opn_addr, opn_we,
    input wire [7:0] opn_wdata,
    output wire [7:0] opn_rdata,
    output wire irq_n,
    output reg signed [15:0] audio_l, audio_r,
    output reg sample_ce,
    output wire [1:0] trace_irq_n,
    output wire [15:0] trace_chip_debug
);
    wire dual = game_id == 1 || game_id == 2;
    // JT03 registers run at clk_sys; cen is the actual YM2203 input clock.
    // JT12 internally divides FM by 6/3/2 and PSG by 4/2/1. Never FASTDIV.
    wire chip_cen = ce_opn && (!pause_game || reset);
    wire [7:0] dout0, dout1, debug0, debug1;
    wire signed [15:0] fm0, fm1;
    wire [7:0] a0,b0,c0,a1,b1,c1;
    wire irq0, irq1;
    wire signed [15:0] mixed;
    assign opn_rdata = opn_select[0] ? dout0 :
                       opn_select[1] && dual ? dout1 : 8'hff;
    assign irq_n = irq0; // Second OPN IRQ is physically unconnected to sound Z80.
    assign trace_irq_n = {irq1,irq0};
    assign trace_chip_debug = {debug1,debug0};

    jt03 u_opn0 (
        .rst(reset), .clk(clk_sys), .cen(chip_cen),
        .din(opn_wdata), .addr(opn_addr), .cs_n(!opn_select[0]), .wr_n(!opn_we),
        .dout(dout0), .irq_n(irq0), .IOA_in(8'hff), .IOB_in(8'hff),
        .IOA_out(), .IOB_out(), .IOA_oe(), .IOB_oe(),
        .psg_A(a0), .psg_B(b0), .psg_C(c0), .fm_snd(fm0),
        .psg_snd(), .snd(), .snd_sample(), .debug_view(debug0)
    );
    jt03 u_opn1 (
        .rst(reset || !dual), .clk(clk_sys), .cen(chip_cen),
        .din(opn_wdata), .addr(opn_addr), .cs_n(!opn_select[1] || !dual), .wr_n(!opn_we),
        .dout(dout1), .irq_n(irq1), .IOA_in(8'hff), .IOB_in(8'hff),
        .IOA_out(), .IOB_out(), .IOA_oe(), .IOB_oe(),
        .psg_A(a1), .psg_B(b1), .psg_C(c1), .fm_snd(fm1),
        .psg_snd(), .snd(), .snd_sample(), .debug_view(debug1)
    );
    reg [1:0] sample_div, settle;
    wire mixed_valid;
    argus_audio_mix_pipeline u_mix (
        .clk_sys(clk_sys), .reset(reset), .enable(!pause_game),
        .capture(settle == 1 && !pause_game),
        .game_id(game_id), .fm0(fm0), .fm1(fm1),
        .a0(a0), .b0(b0), .c0(c0), .a1(a1), .b1(b1), .c1(c1),
        .mixed(mixed), .mixed_valid(mixed_valid)
    );
    // 1.5MHz / 4 = 375kHz preserves the fastest possible PSG prescaler output.
    // Output holds between strobes for the framework's two-equal-samples CDC.
    // Four sys clocks let JT12/JT49 enabled pipelines settle before mixing.
    always @(posedge clk_sys) begin
        sample_ce <= 0;
        if (reset) begin
            sample_div <= 0;
            settle <= 0;
            audio_l <= 0;
            audio_r <= 0;
        end else if (!pause_game) begin
            if (chip_cen) begin
                sample_div <= sample_div + 1'b1;
                if (sample_div == 3) settle <= 3;
            end
            if (settle != 0) begin
                settle <= settle - 1'b1;
            end
            // Capture remains at the original settle==1 edge. The exact result
            // commits four enabled sys clocks later; the 144-clock cadence holds.
            if (mixed_valid) begin
                audio_l <= mixed;
                audio_r <= mixed;
                sample_ce <= 1;
            end
        end
    end
endmodule
