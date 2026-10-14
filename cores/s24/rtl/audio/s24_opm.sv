// System 24 board adapter for the die-derived IKAOPM YM2151 core.
module s24_opm (
    input  logic               clk,
    input  logic               reset,
    input  logic               ce_4m,
    input  logic               chip_reset_n,
    input  logic               write_valid,
    input  logic               write_a0,
    input  logic [7:0]         write_data,
    output logic               write_accepted,
    output logic [7:0]         status,
    output logic               irq_n,
    output logic               sample_strobe_l,
    output logic               sample_strobe_r,
    output logic signed [15:0] audio_l,
    output logic signed [15:0] audio_r
);
    logic write_active;
    logic write_waiting;
    logic write_armed;
    logic [1:0] write_hold;
    logic [1:0] write_phi_wait;
    logic sample_l, sample_r;
    logic signed [15:0] ika_l, ika_r;

    assign sample_strobe_l = sample_l;
    assign sample_strobe_r = sample_r;

    // FULLY_SYNCHRONOUS adds a two-stage input synchronizer. Four stable host
    // clocks provide an explicit capture window before the board bus retires
    // the write; IKAOPM's request latch then transfers it into phi1.
    always_ff @(posedge clk) begin
        write_accepted <= 1'b0;
        if (reset || !chip_reset_n) begin
            write_active <= 1'b0;
            write_waiting <= 1'b0;
            write_armed <= 1'b1;
            write_hold <= 2'd0;
            write_phi_wait <= 2'd0;
        end else if (write_waiting) begin
            if (ce_4m) begin
                if (write_phi_wait == 2'd3) begin
                    write_waiting <= 1'b0;
                    write_accepted <= 1'b1;
                end else begin
                    write_phi_wait <= write_phi_wait + 1'b1;
                end
            end
        end else if (!write_valid) begin
            write_armed <= 1'b1;
        end else if (!write_active && write_valid && write_armed) begin
            write_active <= 1'b1;
            write_armed <= 1'b0;
            write_hold <= 2'd0;
        end else if (write_active) begin
            if (write_hold == 2'd3) begin
                write_active <= 1'b0;
                write_waiting <= 1'b1;
                write_phi_wait <= 2'd0;
            end else begin
                write_hold <= write_hold + 1'b1;
            end
        end
    end

    // The two YM3012 channels latch at distinct times on the original bus.
    // Preserve those boundaries instead of collapsing them to one sample tick.
    always_ff @(posedge clk) begin
        if (reset || !chip_reset_n) begin
            audio_l <= 16'sd0;
            audio_r <= 16'sd0;
        end else begin
            if (sample_l) audio_l <= ika_l;
            if (sample_r) audio_r <= ika_r;
        end
    end

    IKAOPM #(
        .FULLY_SYNCHRONOUS(1),
        .FAST_RESET(1),
        // The integrated design is M10K-bound; the donor's default shift
        // registers use available ALMs and avoid fragmented tiny memories.
        .USE_BRAM(0)
    ) opm (
        .i_EMUCLK(clk),.i_phiM_PCEN_n(~ce_4m),.i_IC_n(chip_reset_n),
        .o_phi1(),
        .i_CS_n(~write_active),.i_RD_n(1'b1),.i_WR_n(~write_active),
        .i_A0(write_a0),.i_D(write_data),.o_D(status),.o_D_OE(),
        .o_CT1(),.o_CT2(),.o_IRQ_n(irq_n),
        .o_SH1(),.o_SH2(),.o_SO(),
        .o_EMU_R_SAMPLE(sample_r),.o_EMU_R_EX(),.o_EMU_R(ika_r),
        .o_EMU_L_SAMPLE(sample_l),.o_EMU_L_EX(),.o_EMU_L(ika_l)
    );
endmodule
