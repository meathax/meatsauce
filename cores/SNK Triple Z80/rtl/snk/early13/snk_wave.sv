// SPDX-License-Identifier: BSD-3-Clause
// Original RTL following MAME snkwave.cpp (Nicola Salmoria).
// ce_wave is one pulse per 8 MHz source tick, not a generated clock.
module snk_wave (
    input wire clk,
    input wire reset,
    input wire ce_wave,
    input wire wr,
    input wire [2:0] addr,
    input wire [7:0] data,
    output reg signed [15:0] pcm,
    output reg sample_valid
);
    reg [11:0] frequency;
    reg [11:0] counter;
    reg [3:0] position;
    reg signed [7:0] waveform [0:15];
    reg [7:0] sample_ticks;
    reg signed [15:0] accumulator;
    wire [3:0] wave_base = ({1'b0,addr} - 4'd2) << 1;
    wire signed [15:0] tick_value = frequency == 12'hfff ? 16'sd0 :
        {{8{waveform[position][7]}}, waveform[position]};
    integer i;
    always @(posedge clk) begin
        sample_valid <= 1'b0;
        if (reset) begin
            frequency <= 0;
            counter <= 0;
            position <= 0;
            sample_ticks <= 0;
            accumulator <= 0;
            pcm <= 0;
            for (i = 0; i < 16; i = i + 1) waveform[i] <= 0;
        end else begin
            if (wr) begin
                case (addr)
                    0: frequency[11:6] <= data[7:2];
                    1: frequency[5:0] <= data[5:0];
                    2,3,4,5: begin
                        waveform[wave_base] <= {1'b0,data[6:4],4'b0};
                        waveform[wave_base + 4'd1] <= {1'b0,data[2:0],4'b0};
                        waveform[4'd14 - wave_base] <= ~{1'b0,data[2:0],4'b0};
                        waveform[4'd15 - wave_base] <= ~{1'b0,data[6:4],4'b0};
                    end
                    default: begin end
                endcase
            end
            if (ce_wave) begin
                if (frequency != 12'hfff) begin
                    if (counter == 12'hfff) begin
                        counter <= frequency;
                        position <= position + 1'b1;
                    end else counter <= counter + 1'b1;
                end
                sample_ticks <= sample_ticks + 1'b1;
                if (sample_ticks == 8'hff) begin
                    pcm <= accumulator + tick_value;
                    accumulator <= 0;
                    sample_valid <= 1'b1;
                end else accumulator <= accumulator + tick_value;
            end
        end
    end
endmodule
