module bigfight_cxd1095 (
    input  logic        clk,
    input  logic        reset,
    input  logic        cold_start,
    input  logic        cs,
    input  logic        wr,
    input  logic [2:0]  address,
    input  logic [7:0]  din,
    input  logic [39:0] ports_i,
    output logic [7:0]  dout,
    output logic [39:0] port_values_o,
    output logic [39:0] port_masks_o,
    output logic        write_cb_strobe_o,
    output logic [2:0]  write_cb_port_o
);

    // Port order is A at [7:0] through E at [39:32]. E uses only its low nibble.
    logic [7:0] data_latch [0:4];
    logic [7:0] data_dir   [0:4];
    logic [7:0] selected_dir;
    logic [7:0] selected_input;
    logic [7:0] input_mask;
    integer output_port;
    integer seq_port;

    // Read registers 0-4 combine live inputs on input-configured bits with
    // the stored output latch on output-configured bits. Other offsets read 0.
    always_comb begin
        dout = 8'h00;
        selected_dir = 8'hff;
        selected_input = 8'h00;
        input_mask = 8'h00;

        if (cs && !wr && (address <= 3'd4)) begin
            selected_dir = data_dir[address];
            selected_input = ports_i[address * 8 +: 8];
            input_mask = selected_dir;

            if (address == 3'd4)
                input_mask = input_mask & 8'h0f;

            dout = (selected_input & input_mask) |
                   (data_latch[address] & ~selected_dir);
        end
    end

    // Drive the output latch values and active output masks. Direction writes
    // change these wires but intentionally do not generate a callback strobe.
    always_comb begin
        port_values_o = 40'h0;
        port_masks_o = 40'h0;
        for (output_port = 0; output_port < 5; output_port = output_port + 1) begin
            port_values_o[output_port * 8 +: 8] =
                data_latch[output_port] & ~data_dir[output_port];
            port_masks_o[output_port * 8 +: 8] = ~data_dir[output_port];
        end
    end

    // One synchronous clock domain. Reset restores input directions while
    // retaining output latches; cold_start separately initializes those latches.
    always_ff @(posedge clk) begin
        write_cb_strobe_o <= 1'b0;

        if (cold_start) begin
            for (seq_port = 0; seq_port < 5; seq_port = seq_port + 1)
                data_latch[seq_port] <= 8'h00;
            write_cb_port_o <= 3'd0;
        end

        if (reset) begin
            for (seq_port = 0; seq_port < 5; seq_port = seq_port + 1)
                data_dir[seq_port] <= 8'hff;
            write_cb_strobe_o <= 1'b0;
            write_cb_port_o <= 3'd0;
        end else if (!cold_start && cs && wr) begin
            case (address)
                3'd0: begin
                    data_latch[0] <= din;
                    write_cb_strobe_o <= 1'b1;
                    write_cb_port_o <= 3'd0;
                end
                3'd1: begin
                    data_latch[1] <= din;
                    write_cb_strobe_o <= 1'b1;
                    write_cb_port_o <= 3'd1;
                end
                3'd2: begin
                    data_latch[2] <= din;
                    write_cb_strobe_o <= 1'b1;
                    write_cb_port_o <= 3'd2;
                end
                3'd3: begin
                    data_latch[3] <= din;
                    write_cb_strobe_o <= 1'b1;
                    write_cb_port_o <= 3'd3;
                end
                3'd4: begin
                    data_latch[4] <= {4'h0, din[3:0]};
                    write_cb_strobe_o <= 1'b1;
                    write_cb_port_o <= 3'd4;
                end
                3'd6: begin
                    for (seq_port = 0; seq_port < 4; seq_port = seq_port + 1)
                        data_dir[seq_port] <= {
                            {4{din[(seq_port * 2) + 1]}},
                            {4{din[seq_port * 2]}}
                        };
                end
                3'd7: data_dir[4] <= {4'hf, din[3:0]};
                default: begin
                    // Offset 5 is unused and has no state or callback effect.
                end
            endcase
        end
    end

endmodule
