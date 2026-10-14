// SPDX-License-Identifier: GPL-3.0-or-later
// Conditional related-Bandido IRQ path; outside production files.qip.
// sample_ce observes settled raw counter/VB inputs on this master clock.
// Framework hold preserves IRQ storage while ordinary paused scanout updates
// request history. A frozen debug raster also freezes sample_ce/history.
// diagnostic_clear supplies a reproducible bench origin, not CPU RESET.
module n8080_interrupt_path (
    input wire clk,
    input wire diagnostic_clear,
    input wire sample_ce,
    input wire hold_irq, // framework pause; not a physical PCB pin
    input wire [7:0] raw_vertical,
    input wire vb,
    input wire inte,
    input wire status_inta,
    output reg irq,
    output wire intr,
    output wire intd,
    output wire [7:0] interrupt_data,
    output wire request_rise
);
    reg previous_intr;
    assign intd=raw_vertical[6]^raw_vertical[7];
    assign intr=vb|(raw_vertical[7]&!raw_vertical[6]);
    assign interrupt_data={2'b11,1'b0,!intd,intd,3'b111};
    assign request_rise=sample_ce&intr&!previous_intr&!diagnostic_clear;
    always @(posedge clk) begin
        if(diagnostic_clear) begin
            irq<=0;
            // Releasing clear with INTR already high is not a new clock edge.
            previous_intr<=intr;
        end else begin
            // Observe request edges while clear is held; releasing INTA does
            // not create an edge. Clear applies even between sample strobes.
            if(sample_ce) previous_intr<=intr;
            if(!hold_irq) begin
                if(status_inta) irq<=0;
                else if(request_rise) irq<=inte;
            end
        end
    end
endmodule
