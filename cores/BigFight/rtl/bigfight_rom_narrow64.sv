// SPDX-License-Identifier: GPL-3.0-only
// Same-clock byte/word selector for an aligned 64-bit ROM granule service.
// The backend must hold an accepted response until wide_rsp_ready_o and must
// share cold_reset so no pre-reset response can reappear after cancellation.
module bigfight_rom_narrow64 #(
    parameter integer DATA_BITS = 8
) (
    input  logic                  clk_sys,
    input  logic                  cold_reset,

    input  logic                  narrow_req_valid_i,
    output logic                  narrow_req_ready_o,
    input  logic [25:0]           narrow_req_byte_address_i,
    output logic                  narrow_rsp_valid_o,
    input  logic                  narrow_rsp_ready_i,
    output logic [DATA_BITS-1:0]  narrow_rsp_data_o,

    output logic                  wide_req_valid_o,
    input  logic                  wide_req_ready_i,
    output logic [25:0]           wide_req_byte_address_o,
    input  logic                  wide_rsp_valid_i,
    output logic                  wide_rsp_ready_o,
    input  logic [63:0]           wide_rsp_data_i
);

    logic request_legal;
    logic outstanding_q;
    logic [2:0] accepted_lane_q;

    generate
        if (DATA_BITS == 8) begin : g_byte_width
            assign request_legal = 1'b1;
        end else if (DATA_BITS == 16) begin : g_word_width
            assign request_legal = !narrow_req_byte_address_i[0];
        end else begin : g_unsupported_width
            assign request_legal = 1'b0;
        end
    endgenerate

    assign narrow_req_ready_o = !cold_reset && !outstanding_q && wide_req_ready_i &&
                                (!narrow_req_valid_i || request_legal);
    assign wide_req_valid_o = !cold_reset && !outstanding_q && narrow_req_valid_i && request_legal;
    assign wide_req_byte_address_o = {narrow_req_byte_address_i[25:3], 3'b000};

    assign narrow_rsp_valid_o = !cold_reset && outstanding_q && wide_rsp_valid_i;
    assign wide_rsp_ready_o = !cold_reset && outstanding_q && narrow_rsp_ready_i;

    generate
        if (DATA_BITS == 8) begin : g_byte_result
            always_comb begin
                case (accepted_lane_q)
                    3'd0: narrow_rsp_data_o = wide_rsp_data_i[ 7: 0];
                    3'd1: narrow_rsp_data_o = wide_rsp_data_i[15: 8];
                    3'd2: narrow_rsp_data_o = wide_rsp_data_i[23:16];
                    3'd3: narrow_rsp_data_o = wide_rsp_data_i[31:24];
                    3'd4: narrow_rsp_data_o = wide_rsp_data_i[39:32];
                    3'd5: narrow_rsp_data_o = wide_rsp_data_i[47:40];
                    3'd6: narrow_rsp_data_o = wide_rsp_data_i[55:48];
                    default: narrow_rsp_data_o = wide_rsp_data_i[63:56];
                endcase
            end
        end else if (DATA_BITS == 16) begin : g_word_result
            always_comb begin
                case (accepted_lane_q[2:1])
                    2'd0: narrow_rsp_data_o = {wide_rsp_data_i[ 7: 0], wide_rsp_data_i[15: 8]};
                    2'd1: narrow_rsp_data_o = {wide_rsp_data_i[23:16], wide_rsp_data_i[31:24]};
                    2'd2: narrow_rsp_data_o = {wide_rsp_data_i[39:32], wide_rsp_data_i[47:40]};
                    default: narrow_rsp_data_o = {wide_rsp_data_i[55:48], wide_rsp_data_i[63:56]};
                endcase
            end
        end else begin : g_unsupported_result
            always_comb narrow_rsp_data_o = '0;
        end
    endgenerate

    always_ff @(posedge clk_sys) begin
        if (cold_reset) begin
            outstanding_q <= 1'b0;
            accepted_lane_q <= 3'd0;
        end else begin
            if (!outstanding_q && narrow_req_valid_i && narrow_req_ready_o) begin
                outstanding_q <= 1'b1;
                accepted_lane_q <= narrow_req_byte_address_i[2:0];
            end else if (outstanding_q && wide_rsp_valid_i && wide_rsp_ready_o) begin
                outstanding_q <= 1'b0;
            end
        end
    end

`ifndef SYNTHESIS
    initial begin
        if (DATA_BITS != 8 && DATA_BITS != 16)
            $fatal(1, "bigfight_rom_narrow64 DATA_BITS must be 8 or 16");
    end
`endif

endmodule
