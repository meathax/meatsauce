module daikaiju_ce_guard #(
    parameter integer MIN_SPACING = 16,
    parameter integer COUNT_BITS = $clog2(MIN_SPACING)
) (
    input  logic clk_sys,
    input  logic reset,
    input  logic enable,
    input  logic ce_in,
    output logic ce_out
);
    logic [COUNT_BITS-1:0] cooldown = '0;

    // Keep the free-running source phase. Cooldown counts master edges even
    // while paused, so re-enable can never create a shortened CE interval.
    always_comb ce_out = !reset && enable && ce_in && (cooldown == 0);

    always_ff @(posedge clk_sys) begin
        if (reset) begin
            cooldown <= '0;
        end else if (ce_out) begin
            cooldown <= MIN_SPACING - 1;
        end else if (cooldown != 0) begin
            cooldown <= cooldown - 1'b1;
        end
    end

    initial begin
        if (MIN_SPACING < 2 || (1 << COUNT_BITS) < MIN_SPACING)
            $error("Invalid Daikaiju CE guard spacing/width");
    end
endmodule
