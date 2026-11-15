// MAME HOLD_LINE level5 for each CPU, independently released by its IACK.
module bigfight_irq (
    input logic clk, reset, vblank_start, main_ack, sub_ack,
    output logic [2:0] main_ipl_n,sub_ipl_n
);
    logic main_pending,sub_pending;
    assign main_ipl_n = main_pending ? 3'b010 : 3'b111;
    assign sub_ipl_n = sub_pending ? 3'b010 : 3'b111;
    always_ff @(posedge clk) begin
        if (reset) begin
            main_pending <= 1'b0;
            sub_pending <= 1'b0;
        end else begin
            if (main_ack) main_pending <= 1'b0;
            if (sub_ack) sub_pending <= 1'b0;
            if (vblank_start) begin
                main_pending <= 1'b1;
                sub_pending <= 1'b1;
            end
        end
    end
endmodule
