// Data East Cassette 8-sprite renderer.
//
// One sprite slot is evaluated on each of the eight 48 MHz clocks available
// per 6 MHz pixel. This preserves MAME's slot 0 -> 7 draw order while testing
// the fetched graphics pen before replacing a lower sprite. Consequently a
// lower-priority sprite remains visible through a later sprite's transparent
// pixels, unlike a bounding-box-only priority selection.

module decocass_video_sprites (
    input  logic        clk_sys,
    input  logic        reset,
    input  logic        ce_pix,
    input  logic [8:0]  hcnt,
    input  logic [8:0]  vcnt,
    input  logic [7:0]  color_center_bot,
    input  logic        cpu_we_spr,
    input  logic [9:0]  cpu_spr_addr,
    input  logic [7:0]  cpu_spr_dout,
    input  logic        cpu_we_char_p0,
    input  logic        cpu_we_char_p1,
    input  logic        cpu_we_char_p2,
    input  logic [12:0] cpu_char_addr,
    input  logic [7:0]  cpu_char_dout,
    output logic [4:0]  spr_pen,
    output logic        spr_priority
);

    // Descriptor mirror: flags/code/Y/X at interleave 0x20. Slots begin at
    // 0x380 and descend by 0x80, so increasing slot number is increasing
    // priority in MAME's draw loop.
    logic [9:0] descriptor_addr;
    logic [7:0] descriptor_q;
    dpram #(.address_width(10), .data_width(8)) descriptor_ram (
        .clock_a(clk_sys), .enable_a(1'b1), .wren_a(cpu_we_spr),
        .address_a(cpu_spr_addr), .data_a(cpu_spr_dout), .q_a(),
        .clock_b(clk_sys), .enable_b(1'b1), .wren_b(1'b0),
        .address_b(descriptor_addr), .data_b(8'h00), .q_b(descriptor_q)
    );

    logic       slot_enable [0:7];
    logic       slot_flip_x [0:7];
    logic       slot_flip_y [0:7];
    logic [7:0] slot_code   [0:7];
    logic signed [8:0] slot_x [0:7];
    logic [7:0] slot_y      [0:7];
    logic [4:0] scan;
    logic [4:0] scan_delayed;
    logic [9:0] scan_addr;
    integer reset_slot;

    always_comb begin
        scan_addr = 10'h380 - {scan[4:2], 7'b0000000} +
                    {scan[1:0], 5'b00000};
    end

    always_ff @(posedge clk_sys) begin
        if (reset) begin
            scan            <= 5'd0;
            scan_delayed    <= 5'd0;
            descriptor_addr <= 10'h380;
            for (reset_slot = 0; reset_slot < 8; reset_slot = reset_slot + 1) begin
                slot_enable[reset_slot] <= 1'b0;
                slot_flip_x[reset_slot] <= 1'b0;
                slot_flip_y[reset_slot] <= 1'b0;
                slot_code[reset_slot]   <= 8'h00;
                slot_x[reset_slot]      <= 9'sd0;
                slot_y[reset_slot]      <= 8'h00;
            end
        end else if (ce_pix) begin
            case (scan_delayed[1:0])
                2'd0: begin
                    slot_enable[scan_delayed[4:2]] <= descriptor_q[0];
                    slot_flip_y[scan_delayed[4:2]] <= descriptor_q[1];
                    slot_flip_x[scan_delayed[4:2]] <= descriptor_q[2];
                end
                2'd1: slot_code[scan_delayed[4:2]] <= descriptor_q;
                2'd2: slot_y[scan_delayed[4:2]]    <= 8'd240 - descriptor_q;
                2'd3: slot_x[scan_delayed[4:2]]    <=
                           10'sd240 - $signed({1'b0, descriptor_q});
            endcase
            descriptor_addr <= scan_addr;
            scan_delayed    <= scan;
            scan            <= scan + 5'd1;
        end
    end

    // Eight system-clock phases per pixel. phase 7 is issued on ce_pix; its
    // synchronous RAM result is resolved on phase 0 immediately afterward.
    logic [2:0] phase;
    always_ff @(posedge clk_sys) begin
        if (reset)
            phase <= 3'd0;
        else if (ce_pix)
            phase <= 3'd0;
        else
            phase <= phase + 3'd1;
    end

    logic signed [9:0] delta_x;
    logic [7:0] delta_y;
    logic [3:0] source_col;
    logic [3:0] source_row;
    logic       query_valid;
    logic [2:0] query_bit;
    logic [12:0] query_addr;

    always_comb begin
        // MAME clips sprite X and wraps only Y. Preserve negative X so a
        // left-clipped sprite does not also appear at the right screen edge.
        delta_x = $signed({1'b0, hcnt}) - slot_x[phase];
        delta_y = vcnt[7:0] - slot_y[phase];
        source_col = slot_flip_x[phase] ? (4'd15 - delta_x[3:0])
                                              : delta_x[3:0];
        source_row = slot_flip_y[phase] ? (4'd15 - delta_y[3:0])
                                              : delta_y[3:0];
        query_valid = slot_enable[phase] &&
                      (delta_x >= 10'sd0) && (delta_x < 10'sd16) &&
                      (delta_y < 8'd16);
        query_addr = {slot_code[phase], ~source_col[3], source_row};
        query_bit  = 3'd7 - source_col[2:0];
    end

    logic [7:0] plane0_q;
    logic [7:0] plane1_q;
    logic [7:0] plane2_q;
    dpram #(.address_width(13), .data_width(8)) sprite_plane0 (
        .clock_a(clk_sys), .enable_a(1'b1), .wren_a(cpu_we_char_p0),
        .address_a(cpu_char_addr), .data_a(cpu_char_dout), .q_a(),
        .clock_b(clk_sys), .enable_b(1'b1), .wren_b(1'b0),
        .address_b(query_addr), .data_b(8'h00), .q_b(plane0_q)
    );
    dpram #(.address_width(13), .data_width(8)) sprite_plane1 (
        .clock_a(clk_sys), .enable_a(1'b1), .wren_a(cpu_we_char_p1),
        .address_a(cpu_char_addr), .data_a(cpu_char_dout), .q_a(),
        .clock_b(clk_sys), .enable_b(1'b1), .wren_b(1'b0),
        .address_b(query_addr), .data_b(8'h00), .q_b(plane1_q)
    );
    dpram #(.address_width(13), .data_width(8)) sprite_plane2 (
        .clock_a(clk_sys), .enable_a(1'b1), .wren_a(cpu_we_char_p2),
        .address_a(cpu_char_addr), .data_a(cpu_char_dout), .q_a(),
        .clock_b(clk_sys), .enable_b(1'b1), .wren_b(1'b0),
        .address_b(query_addr), .data_b(8'h00), .q_b(plane2_q)
    );

    logic       query_valid_delayed;
    logic [2:0] query_bit_delayed;
    logic [2:0] fetched_pen;
    logic       accumulated_valid;
    logic [2:0] accumulated_pen;

    always_comb begin
        fetched_pen = {plane2_q[query_bit_delayed],
                       plane1_q[query_bit_delayed],
                       plane0_q[query_bit_delayed]};
    end

    always_ff @(posedge clk_sys) begin
        if (reset) begin
            query_valid_delayed <= 1'b0;
            query_bit_delayed   <= 3'd0;
            accumulated_valid   <= 1'b0;
            accumulated_pen     <= 3'd0;
            spr_pen             <= 5'd0;
            spr_priority        <= 1'b0;
        end else begin
            query_valid_delayed <= query_valid;
            query_bit_delayed   <= query_bit;

            if (phase == 3'd0) begin
                // The delayed value here is slot 7 from the preceding pixel.
                // It wins if nontransparent; otherwise retain the highest
                // nontransparent result accumulated from slots 0 through 6.
                if (query_valid_delayed && (fetched_pen != 3'b000)) begin
                    spr_pen      <= {1'b0, color_center_bot[1], fetched_pen};
                    spr_priority <= 1'b1;
                end else if (accumulated_valid) begin
                    spr_pen      <= {1'b0, color_center_bot[1], accumulated_pen};
                    spr_priority <= 1'b1;
                end else begin
                    spr_pen      <= 5'd0;
                    spr_priority <= 1'b0;
                end
                accumulated_valid <= 1'b0;
                accumulated_pen   <= 3'd0;
            end else if (query_valid_delayed && (fetched_pen != 3'b000)) begin
                accumulated_valid <= 1'b1;
                accumulated_pen   <= fetched_pen;
            end
        end
    end

endmodule
