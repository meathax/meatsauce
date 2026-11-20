// SPDX-License-Identifier: BSD-3-Clause
// Board implementation of the Galastrm TC0110PCR configuration (shift=0).
// Register semantics derived from MAME 0.289 tc0110pcr.cpp,
// copyright Nicola Salmoria; xRGB555 from galastrm.cpp.
module gs_tc0110pcr (
    input  logic clk,
    input  logic reset,
    input  logic cpu_req,
    input  logic cpu_write,
    input  logic cpu_reg,
    input  logic [1:0] cpu_be,
    input  logic [15:0] cpu_wdata,
    output logic cpu_ack,
    output logic [15:0] cpu_rdata,
    input  logic pixel_ce,
    input  logic [11:0] pixel_index,
    output wire [23:0] pixel_rgb
);
    logic [11:0] index = 12'b0;
    (* ramstyle="M10K" *) logic [15:0] palette_ram [0:4095];
    logic [15:0] pixel_word = 16'b0;
    logic [15:0] cpu_palette_word = 16'b0;
    wire [15:0] data_masked = {
        cpu_be[1] ? cpu_wdata[15:8] : 8'b0,
        cpu_be[0] ? cpu_wdata[7:0] : 8'b0
    };
    integer entry;
    initial begin
        for (entry=0; entry<4096; entry=entry+1) palette_ram[entry]=16'b0;
    end

    // MAME clears RAM at power-on, and device_reset is empty: retain the
    // index and palette across CPU reset. Pixel lookup has one clock latency.
    always_ff @(posedge clk) begin
        if (pixel_ce) pixel_word <= palette_ram[pixel_index];
        // Both RAM read registers must remain free of reset/mux logic.
        cpu_palette_word <= palette_ram[index];
        cpu_ack <= 1'b0;
        if (reset) begin
            cpu_rdata <= 16'b0;
        end else if (cpu_req && !cpu_ack) begin
            cpu_ack <= 1'b1;
            if (cpu_write && |cpu_be) begin
                if (cpu_reg) palette_ram[index] <= data_masked;
                else index <= data_masked[11:0];
            end else if (!cpu_write) begin
                // Offset zero is not an address readback; MAME returns 0x00ff.
                cpu_rdata <= cpu_reg ? cpu_palette_word : 16'h00ff;
            end
        end
    end
    assign pixel_rgb = {
        pixel_word[14:10],pixel_word[14:12],
        pixel_word[9:5],pixel_word[9:7],
        pixel_word[4:0],pixel_word[4:2]
    };
endmodule
