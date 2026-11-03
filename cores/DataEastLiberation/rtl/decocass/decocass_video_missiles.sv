// Data East Cassette 16-missile renderer.
// Exact MAME ordering: for pairs 0 through 7, draw lower then upper. Later
// nontransparent dots overwrite earlier dots; coordinates clip rather than
// wrapping horizontally.

module decocass_video_missiles (
    input  logic       clk_sys,
    input  logic       reset,
    input  logic       ce_pix,
    input  logic [8:0] hcnt,
    input  logic [8:0] vcnt,
    input  logic [7:0] color_missiles,
    input  logic       flip_screen,
    input  logic       cpu_we_mis,
    input  logic [9:0] cpu_mis_addr,
    input  logic [7:0] cpu_mis_dout,
    output logic [4:0] mis_pen,
    output logic       mis_priority
);

    logic [9:0] descriptor_addr;
    logic [7:0] descriptor_q;
    dpram #(.address_width(10), .data_width(8)) descriptor_ram (
        .clock_a(clk_sys), .enable_a(1'b1), .wren_a(cpu_we_mis),
        .address_a(cpu_mis_addr), .data_a(cpu_mis_dout), .q_a(),
        .clock_b(clk_sys), .enable_b(1'b1), .wren_b(1'b0),
        .address_b(descriptor_addr), .data_b(8'h00), .q_b(descriptor_q)
    );

    logic signed [8:0] lower_x [0:7];
    logic signed [8:0] lower_y [0:7];
    logic signed [8:0] upper_x [0:7];
    logic signed [8:0] upper_y [0:7];
    logic [4:0] scan;
    logic [4:0] scan_delayed;
    logic [9:0] scan_addr;
    integer reset_pair;

    always_comb scan_addr = {scan[4:2], scan[1:0], 5'b00000};

    always_ff @(posedge clk_sys) begin
        if (reset) begin
            scan            <= 5'd0;
            scan_delayed    <= 5'd0;
            descriptor_addr <= 10'd0;
            for (reset_pair = 0; reset_pair < 8; reset_pair = reset_pair + 1) begin
                lower_x[reset_pair] <= 9'sd0;
                lower_y[reset_pair] <= 9'sd0;
                upper_x[reset_pair] <= 9'sd0;
                upper_y[reset_pair] <= 9'sd0;
            end
        end else if (ce_pix) begin
            case (scan_delayed[1:0])
                2'd0: lower_y[scan_delayed[4:2]] <=
                           10'sd254 - $signed({1'b0, descriptor_q});
                2'd1: upper_y[scan_delayed[4:2]] <=
                           10'sd254 - $signed({1'b0, descriptor_q});
                2'd2: lower_x[scan_delayed[4:2]] <=
                           10'sd255 - $signed({1'b0, descriptor_q});
                2'd3: upper_x[scan_delayed[4:2]] <=
                           10'sd255 - $signed({1'b0, descriptor_q});
            endcase
            descriptor_addr <= scan_addr;
            scan_delayed    <= scan;
            scan            <= scan + 5'd1;
        end
    end

    logic       hit_valid;
    logic [4:0] hit_pen;
    logic signed [9:0] delta_x;
    logic signed [9:0] delta_y;
    integer pair;

    // Cocktail flip is performed once for the complete frame by the common
    // screen_rotate path.  A straight 256x256 mirror is already identical to
    // MAME for 16x16 sprites, but the four-pixel missile circuit deliberately
    // uses the sprite origin constant 240.  Bias native coordinates so the
    // later global mirror lands at MAME's exact flipped positions:
    //   X: 240-(255-Rx)  => pre-mirror (255-Rx)+12 for a 4-pixel segment
    //   Y: 240-(255-Ry)-1 => pre-mirror (254-Ry)+17 for a point
    logic signed [9:0] flip_x_bias;
    logic signed [9:0] flip_y_bias;

    always_comb begin
        hit_valid = 1'b0;
        hit_pen   = 5'd0;
        delta_x   = 10'sd0;
        delta_y   = 10'sd0;
        flip_x_bias = flip_screen ? 10'sd12 : 10'sd0;
        flip_y_bias = flip_screen ? 10'sd17 : 10'sd0;
        for (pair = 0; pair < 8; pair = pair + 1) begin
            delta_x = $signed({1'b0, hcnt}) -
                      ($signed(lower_x[pair]) + flip_x_bias);
            delta_y = $signed({1'b0, vcnt}) -
                      ($signed(lower_y[pair]) + flip_y_bias);
            if ((delta_x >= 10'sd0) && (delta_x < 10'sd4) &&
                (delta_y == 10'sd0)) begin
                hit_valid = 1'b1;
                hit_pen   = {2'b01, color_missiles[2:0]};
            end

            delta_x = $signed({1'b0, hcnt}) -
                      ($signed(upper_x[pair]) + flip_x_bias);
            delta_y = $signed({1'b0, vcnt}) -
                      ($signed(upper_y[pair]) + flip_y_bias);
            if ((delta_x >= 10'sd0) && (delta_x < 10'sd4) &&
                (delta_y == 10'sd0)) begin
                hit_valid = 1'b1;
                hit_pen   = {2'b01, color_missiles[6:4]};
            end
        end
    end

    // Two pixel stages match foreground/background/sprite layer alignment.
    logic       hit_valid_delayed;
    logic [4:0] hit_pen_delayed;
    always_ff @(posedge clk_sys) begin
        if (reset) begin
            hit_valid_delayed <= 1'b0;
            hit_pen_delayed   <= 5'd0;
            mis_pen           <= 5'd0;
            mis_priority      <= 1'b0;
        end else if (ce_pix) begin
            hit_valid_delayed <= hit_valid;
            hit_pen_delayed   <= hit_pen;
            mis_pen           <= hit_valid_delayed ? hit_pen_delayed : 5'd0;
            mis_priority      <= hit_valid_delayed;
        end
    end

endmodule
