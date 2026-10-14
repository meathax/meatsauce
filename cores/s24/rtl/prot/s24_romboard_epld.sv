// Behavioural model of the EPM5032 on the System 24 ROM board.
//
// The board notes identify a 10 MHz source divided by the 74HC4040 into a
// 625 kHz counter clock (/16) and a roughly 9 kHz auxiliary clock (/1024).
// MODE writes reset the EPM counter.  In mode zero the visible counter wraps
// at FF; in mode one it wraps at 66 (103 states).  The register/bank mux and
// security latch remain in s24_core because their CPU bus cycle is shared
// with the motherboard maps; this block owns the documented EPM timing state.
// The documented INT3# level is exposed separately from the MAME-compatible
// auxiliary event used by the motherboard IRQ model; the exact programmed
// fuse equations that combine the two clocks remain unavailable.
module s24_romboard_epld (
    input  logic       clk,
    input  logic       reset,
    input  logic       phi1,
    input  logic       mode_write,
    input  logic       mode_data,
    output logic       mode,
    output logic [7:0] count,
    output logic       int3_n,
    output logic       irq_tick
);
    logic [3:0]  count_div;
    logic [9:0]  irq_div;

    // The ROM-board notes identify INT3# as a level output: MODE=1 forces it
    // low and MODE=0 releases it high.
    always_comb int3_n = ~mode;

    always_ff @(posedge clk) begin
        if (reset) begin
            mode     <= 1'b0;
            count    <= 8'h00;
            count_div<= 4'h0;
            irq_div  <= 10'h000;
            irq_tick <= 1'b0;
        end else begin
            irq_tick <= 1'b0;

            if (phi1) begin
                // 10 MHz / 16 = 625 kHz EPM counter clock.
                if (count_div == 4'hf) begin
                    count_div <= 4'h0;
                    count <= (mode && count == 8'h66) ? 8'h00 : count + 1'b1;
                end else count_div <= count_div + 1'b1;

                // 10 MHz / 1024 is the second 74HC4040 output.  The exact
                // fuse-level use of this input is not public; irq_tick is
                // retained as the MAME-compatible motherboard FRC event.
                if (irq_div == 10'h3ff) begin
                    irq_div  <= 10'h000;
                    irq_tick <= 1'b1;
                end else irq_div <= irq_div + 1'b1;
            end

            if (mode_write) begin
                mode      <= mode_data;
                count     <= 8'h00;
                count_div <= 4'h0;
                irq_div   <= 10'h000;
                irq_tick  <= 1'b0;
            end
        end
    end
endmodule
