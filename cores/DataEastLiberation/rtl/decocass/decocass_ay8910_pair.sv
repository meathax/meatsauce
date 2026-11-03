// DECO Cassette dual AY-3-8910 interface and mono analogue-path model.
//
// The audio CPU writes an external four-bit address latch at $4xxx/$8xxx,
// then writes data at $2xxx/$6xxx.  Capture both address and data on the
// 500 kHz CPU enable so a later 1.5 MHz AY enable cannot observe a bus value
// from the following 6502 cycle.
module ay8910_pair (
    input  wire               clk_sys,
    input  wire               ce_hclk2,
    input  wire               ce_dc,          // DC-blocker enable (line rate)
    input  wire               ce_audio,
    input  wire               reset,
    input  wire               ay1_data_we,
    input  wire               ay1_addr_we,
    input  wire               ay2_data_we,
    input  wire               ay2_addr_we,
    input  wire [7:0]         audio_dout,
    output wire signed [15:0] sound_out,
    output wire               dbg_ay_pulse
);

    reg [3:0] ay1_addr;
    reg [3:0] ay2_addr;
    reg [7:0] ay1_data;
    reg [7:0] ay2_data;
    reg       ay1_pending;
    reg       ay2_pending;

    always @(posedge clk_sys) begin
        if (reset) begin
            ay1_addr    <= 4'h0;
            ay2_addr    <= 4'h0;
            ay1_data    <= 8'h00;
            ay2_data    <= 8'h00;
            ay1_pending <= 1'b0;
            ay2_pending <= 1'b0;
        end else begin
            if (ce_audio && ay1_addr_we)
                ay1_addr <= audio_dout[3:0];
            if (ce_audio && ay2_addr_we)
                ay2_addr <= audio_dout[3:0];

            // A newly accepted CPU write wins over an AY-enable acknowledge.
            // This also handles the legal case where both enables coincide.
            if (ce_audio && ay1_data_we) begin
                ay1_data    <= audio_dout;
                ay1_pending <= 1'b1;
            end else if (ce_hclk2) begin
                ay1_pending <= 1'b0;
            end

            if (ce_audio && ay2_data_we) begin
                ay2_data    <= audio_dout;
                ay2_pending <= 1'b1;
            end else if (ce_hclk2) begin
                ay2_pending <= 1'b0;
            end
        end
    end

    // JT49's register bus is not gated by clk_en. Qualifying the pending flag
    // makes each CPU data access exactly one register-write clock edge.
    wire ay1_write = ay1_pending && ce_hclk2;
    wire ay2_write = ay2_pending && ce_hclk2;
    assign dbg_ay_pulse = ay1_write | ay2_write;

    wire [9:0] ay1_sound;
    wire [9:0] ay2_sound;

    jt49 #(.COMP(3'b000), .CLKDIV(3)) ay1 (
        .rst_n   (~reset),
        .clk     (clk_sys),
        .clk_en  (ce_hclk2),
        .addr    (ay1_addr),
        .cs_n    (~ay1_write),
        .wr_n    (~ay1_write),
        .din     (ay1_data),
        .sel     (1'b1),
        .dout    (),
        .sound   (ay1_sound),
        .A       (), .B(), .C(), .sample(),
        .IOA_in  (8'h00), .IOA_out(), .IOA_oe(),
        .IOB_in  (8'h00), .IOB_out(), .IOB_oe()
    );

    jt49 #(.COMP(3'b000), .CLKDIV(3)) ay2 (
        .rst_n   (~reset),
        .clk     (clk_sys),
        .clk_en  (ce_hclk2),
        .addr    (ay2_addr),
        .cs_n    (~ay2_write),
        .wr_n    (~ay2_write),
        .din     (ay2_data),
        .sel     (1'b1),
        .dout    (),
        .sound   (ay2_sound),
        .A       (), .B(), .C(), .sample(),
        .IOA_in  (8'h00), .IOA_out(), .IOA_oe(),
        .IOB_in  (8'h00), .IOB_out(), .IOB_oe()
    );

    // The PCB mixes both AY outputs at equal gain. JT49 is unipolar and emits
    // zero at silence, so subtracting a fixed half-scale value is incorrect
    // and produces a full-scale DC rail. Sum first, then remove its measured
    // DC component. Twelve bits accommodate the two 3x8-bit channel sums
    // without the startup wrap that an eleven-bit signed filter could cause.
    wire [10:0] ay_sum = {1'b0, ay1_sound} + {1'b0, ay2_sound};
    wire signed [11:0] ay_ac;
    jt49_dcrm2 #(.sw(12)) ay_dc_remove (
        .clk  (clk_sys),
        .cen  (ce_dc),
        .rst  (reset),
        .din  ({1'b0, ay_sum}),
        .dout (ay_ac)
    );

    wire signed [15:0] ay_scaled = {ay_ac, 4'b0000};
    tp_lpf_light lpf (
        .clk   (clk_sys),
        .reset (reset),
        .in    (ay_scaled),
        .out   (sound_out)
    );

endmodule
