// Data East Cassette bidirectional sound latches.
//
// Implements decocass_m.cpp's command/data/status side effects, including the
// audio CPU's previously disconnected $1800-$1fff data-ack reset window.

module decocass_sound_latches (
    input  logic       clk_sys,
    input  logic       reset,

    input  logic       main_we_e414,
    input  logic [7:0] main_dout,
    output logic [7:0] main_din_e700,
    output logic [7:0] main_din_e701,

    input  logic       audio_we_c000,
    input  logic       audio_re_a000,
    input  logic       audio_ack_reset,
    input  logic [7:0] audio_dout,
    output logic [7:0] audio_din_a000,
    output logic       audio_irq
);

    logic [7:0] command_latch;
    logic [7:0] response_latch;
    logic       command_pending;
    logic       response_pending;

    always_comb begin
        main_din_e700 = response_latch;
        main_din_e701 = {command_pending, response_pending, 6'b000000};
        audio_din_a000 = command_latch;
        audio_irq = command_pending;
    end

    always_ff @(posedge clk_sys) begin
        if (reset) begin
            command_latch   <= 8'h00;
            response_latch  <= 8'h00;
            command_pending <= 1'b0;
            response_pending <= 1'b0;
        end else begin
            // An audio-side read consumes the current command. If a new main
            // command lands on the same clock, retain the new pending IRQ.
            if (audio_re_a000)
                command_pending <= 1'b0;
            if (main_we_e414) begin
                command_latch    <= main_dout;
                command_pending  <= 1'b1;
                response_pending <= 1'b0;
            end

            // Any audio access in $1800-$1fff acknowledges its response.
            // A response written on the same clock remains visible to main.
            if (audio_ack_reset)
                response_pending <= 1'b0;
            if (audio_we_c000) begin
                response_latch   <= audio_dout;
                response_pending <= 1'b1;
            end
        end
    end

endmodule
