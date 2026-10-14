// SPDX-License-Identifier: GPL-3.0-or-later
// Master-clock sampled model of related-Bandido 4F/4G/4T and READY 3D.
// Not connected to the board. Inputs must preserve pin events at master-clock
// resolution; electrical pulse widths and simultaneous-event order are open.
module n8080_ram_readback (
    input  wire       clk,
    input  wire       reset,
    input  wire       ramstb_n,
    input  wire       hread_n,
    input  wire       phi1_ttl,
    input  wire       phi3_ttl,
    input  wire [7:0] rd,
    output reg  [7:0] captured_data,
    output reg        first_capture,
    output reg        rdy_in,
    output wire       ready
);
    reg previous_read_clock;
    reg previous_phi3;
    reg ready_sample;
    wire read_clock = hread_n ^ first_capture;

    always @(posedge clk) begin
        previous_phi3 <= phi3_ttl;
        if (reset || !ramstb_n) begin
            captured_data <= 0;
            first_capture <= 0;
            rdy_in <= 0;
            // CLR dominates captures. Track the clock with Q2 cleared, so
            // releasing CLR while the clock is high creates no false edge.
            previous_read_clock <= hread_n;
        end else if (read_clock && !previous_read_clock) begin
            captured_data <= rd;
            rdy_in <= first_capture; // 4F D1 receives the old Q2
            first_capture <= 1'b1;   // 4F D2 is tied high
            // The first Q2 transition terminates its own XOR-clock pulse.
            previous_read_clock <= hread_n ^ 1'b1;
        end else begin
            previous_read_clock <= read_clock;
        end

        if (reset || !ramstb_n)
            ready_sample <= 1'b1;
        else if (!rdy_in)
            ready_sample <= 1'b0;
        else if (phi3_ttl && !previous_phi3)
            ready_sample <= phi1_ttl; // Qbar of D = NOT phi1 TTL
    end

    // LS74 Qbar is high when CLR is asserted, including both async controls
    // low. Do not derive this output by simply inverting a modeled Q register.
    assign ready = !ramstb_n ? 1'b1 : !rdy_in ? 1'b0 : ready_sample;
endmodule
