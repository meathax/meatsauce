// MAME's tilemap0_color_w is mapped over C00008-C00009. The driver consumes
// bits 0-1 and bit 7 from the low data byte; high-byte-only writes pass zero
// in those fields to the handler, matching the current MAME map semantics.
module esd16_video_control (
    input             clk,
    input             rst,
    input             cpu_wr_cyc,
    input      [23:0] address,
    input             low_byte_write,
    input      [15:0] data,
    output reg  [7:0] tilemap0_color = 8'd0
);
    wire selected = (address[23:16] == 8'hC0) && (address[7:1] == 7'h04);

    always @(posedge clk) begin
        if (rst)
            tilemap0_color <= 8'd0;
        else if (cpu_wr_cyc && selected)
            tilemap0_color <= low_byte_write ? data[7:0] : 8'd0;
    end
endmodule
