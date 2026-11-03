// Sound-device clock enables derived from the existing ThunderJaws clk_sys.
// One free-running integer divider preserves the required subset relationship.
module thunderjaws_sound_ce (
    input  logic       clk_sys,
    input  logic       pause,
    output logic       ce_ym_3m579545,
    output logic       ce_t65_1m789772,
    output logic       ce_oki_1m193181,
    output logic [6:0] phase_debug
);
    logic [6:0] phase = 7'd0;

    always_ff @(posedge clk_sys) begin
        if(pause)phase<=phase;
        else if (phase == 7'd71)
            phase <= 7'd0;
        else
            phase <= phase + 7'd1;
    end

    assign phase_debug = phase;
    assign ce_ym_3m579545 = !pause && ((phase == 7'd0) || (phase == 7'd12) ||
        (phase == 7'd24) || (phase == 7'd36) || (phase == 7'd48) ||
        (phase == 7'd60));
    assign ce_t65_1m789772 = !pause && ((phase == 7'd0) || (phase == 7'd24) ||
        (phase == 7'd48));
    assign ce_oki_1m193181 = !pause && ((phase == 7'd0) || (phase == 7'd36));
endmodule
