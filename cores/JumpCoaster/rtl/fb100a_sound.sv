module fb100a_sound (
    input  wire                 clk_sys,
    input  wire                 ce_ay,
    input  wire                 reset_n,
    input  wire                 ay_select, // CPU F800: address, F801: data
    input  wire                 ay_write,
    input  wire [7:0]           ay_data,
    output wire signed [15:0]   audio_mono
);
    reg  [3:0] ay_address;
    reg        write_armed;
    wire       write_pulse;
    wire       register_write;
    wire [9:0] ay_sound;

    // The CPU wrapper presents ay_write as a level. Accept one bus phase per
    // complete high interval, even when it spans several clk_sys cycles.
    // Re-arm only after the level returns low; this also suppresses a stale
    // held write across reset release.
    assign write_pulse   = reset_n && ay_write && write_armed;
    assign register_write = write_pulse && ay_select;

    always @(posedge clk_sys or negedge reset_n) begin
        if (!reset_n) begin
            ay_address <= 4'd0;
            write_armed <= 1'b0;
        end else if (!ay_write) begin
            write_armed <= 1'b1;
        end else if (write_armed) begin
            write_armed <= 1'b0;
            if (!ay_select)
                ay_address <= ay_data[3:0];
        end
    end

    // Jump Coaster uses a single AY-8910 on the 1.536 MHz ce_ay. Pass that
    // enable straight through so register writes do not reset or re-phase
    // the chip's tone/noise/envelope dividers.
    jt49 #(
        .COMP             (3'b000),
        .YM2203_LUMPED    (0),
        .CLKDIV           (3),
        .MUTE_NULL_PERIOD (1)
    ) u_ay (
        .rst_n   (reset_n),
        .clk     (clk_sys),
        .clk_en  (ce_ay),
        .addr    (ay_address),
        .cs_n    (!register_write),
        .wr_n    (!register_write),
        .din     (ay_data),
        .sel     (1'b0),
        .dout    (),
        .sound   (ay_sound),
        .A       (),
        .B       (),
        .C       (),
        .sample  (),
        .IOA_in  (8'h00),
        .IOA_out (),
        .IOA_oe  (),
        .IOB_in  (8'h00),
        .IOB_out (),
        .IOB_oe  ()
    );

    // JT49's unsigned 10-bit sum is kept unipolar. A 3-bit scale maps its
    // full range to about 25% of signed 16-bit positive range for mixer
    // headroom. No filtering, DC blocking, or equalization is added here.
    assign audio_mono = {3'b000, ay_sound, 3'b000};
endmodule
