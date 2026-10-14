// SPDX-License-Identifier: GPL-3.0-or-later
// Conditional, zero-delay related-Bandido RAM clock network.
// Not yet connected to the board: exact Sheriff phase and DRAM timing remain open.
module n8080_memory_phases (
    input  wire       clk,
    input  wire       reset,
    input  wire       ce_xtal, // positive edges of the 20.160 MHz crystal
    output wire       raw_cas_n,
    output wire       raw_ras_n,
    output wire       comadr_n,
    output wire       hread_n,
    output wire [3:0] phase_4i,
    output wire [7:0] delay_4a
);
    reg [3:0] decade_2a;
    reg       divider_3b;
    reg [3:0] counter_4i;
    reg [7:0] serial_4a;

    // 2A QA rises on even-to-odd decade transitions, including 0 -> 1.
    wire ck2_rise = !decade_2a[0];
    always @(posedge clk) begin
        if (reset) begin
            // A reproducible simulation origin, not a PCB power-up claim.
            decade_2a <= 0;
            divider_3b <= 0;
            counter_4i <= 0;
            serial_4a <= 0;
        end else if (ce_xtal) begin
            decade_2a <= decade_2a == 9 ? 4'd0 : decade_2a + 4'd1;
            if (ck2_rise) begin
                divider_3b <= !divider_3b;
                // 4A clocks directly from CK/2; 4I clocks through 3B.
                // Capture the old QB before the derived 4I count changes.
                serial_4a <= {serial_4a[6:0], counter_4i[1]};
                if (!divider_3b) counter_4i <= counter_4i + 4'd1;
            end
        end
    end
    assign raw_cas_n = !serial_4a[1];
    assign raw_ras_n = serial_4a[1] & serial_4a[3];
    assign comadr_n = !serial_4a[6];
    assign hread_n = !counter_4i[2];
    assign phase_4i = counter_4i;
    assign delay_4a = serial_4a;
endmodule
