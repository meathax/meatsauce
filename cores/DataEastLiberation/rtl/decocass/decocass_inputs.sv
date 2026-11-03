// Data East Cassette input and quadrature read mux.
// MAME reference: decocass_input_r and decocass_quadrature_decoder_reset_w.

module decocass_inputs (
    input  logic       clk_sys,
    input  logic       reset,
    input  logic       quadrature_latch,
    input  logic [7:0] cpu_addr_lo,
    input  logic [7:0] in0,
    input  logic [7:0] in1,
    input  logic [7:0] in2,
    output logic [7:0] input_q
);

    logic [7:0] quadrature [0:3];

    function automatic logic [7:0] digital_axis(
        input logic positive,
        input logic negative
    );
        if (positive ^ negative)
            digital_axis = positive ? 8'hf0 : 8'h10;
        else
            digital_axis = 8'h80;
    endfunction

    always_ff @(posedge clk_sys) begin
        if (reset) begin
            // MAME machine_reset clears the hardware latches. A game writes
            // $E415/$E416 before sampling them, which captures neutral $80.
            quadrature[0] <= 8'h00;
            quadrature[1] <= 8'h00;
            quadrature[2] <= 8'h00;
            quadrature[3] <= 8'h00;
        end else if (quadrature_latch) begin
            quadrature[0] <= digital_axis(in0[0], in0[1]); // P1 X: right/left
            quadrature[1] <= digital_axis(in0[3], in0[2]); // P1 Y: down/up
            quadrature[2] <= digital_axis(in1[0], in1[1]); // P2 X: right/left
            quadrature[3] <= digital_axis(in1[3], in1[2]); // P2 Y: down/up
        end
    end

    always_comb begin
        case (cpu_addr_lo[2:0])
            3'd0: input_q = in0;
            3'd1: input_q = in1;
            3'd2: input_q = in2;
            3'd3: input_q = quadrature[0];
            3'd4: input_q = quadrature[1];
            3'd5: input_q = quadrature[2];
            3'd6: input_q = quadrature[3];
            default: input_q = 8'hff; // MAME leaves the nominal E607 ADC read open bus
        endcase
    end

endmodule
