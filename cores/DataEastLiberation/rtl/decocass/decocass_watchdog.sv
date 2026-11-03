// Data East Cassette frame-counted watchdog and cocktail flip latch.

module decocass_watchdog (
    input  logic       clk_sys,
    input  logic       reset,
    input  logic       vblank_start,
    input  logic       count_w,
    input  logic       flip_w,
    input  logic [7:0] cpu_dout,
    input  logic [7:0] dsw1,
    output logic       watchdog_reset,
    output logic       flip_screen
);

    logic       enabled;
    logic [7:0] flip_register;
    logic [4:0] frame_limit;
    logic [4:0] frame_count;

    always_ff @(posedge clk_sys) begin
        if (reset) begin
            enabled        <= 1'b0;
            flip_register  <= 8'h00;
            frame_limit    <= 5'd16;
            frame_count    <= 5'd0;
            watchdog_reset <= 1'b0;
        end else begin
            watchdog_reset <= 1'b0;

            if (flip_w) begin
                flip_register <= cpu_dout;
                enabled       <= cpu_dout[3];
                if (!cpu_dout[3])
                    frame_count <= 5'd0;
            end

            if (count_w) begin
                frame_limit <= {1'b0, cpu_dout[3:0]} + 5'd1;
                frame_count <= 5'd0;
            end else if (vblank_start && enabled && !(flip_w && !cpu_dout[3])) begin
                if ((frame_count + 5'd1) >= frame_limit) begin
                    watchdog_reset <= 1'b1;
                    frame_count    <= 5'd0;
                end else begin
                    frame_count <= frame_count + 5'd1;
                end
            end
        end
    end

    always_comb flip_screen = flip_register[0] & dsw1[6];

endmodule
