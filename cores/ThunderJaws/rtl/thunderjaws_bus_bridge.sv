// SPDX-License-Identifier: GPL-3.0-or-later
// Target bus glue following the held-response contract in shared lesson2518.
// One outstanding backend request. All signals are synchronous to clk_sys.
// init_reset must also cancel/reset the backend. game_reset instead drains an
// accepted response. The backend must produce exactly one response per request;
// zero-latency responses are permitted. No timeout or timing exception implied.
// AS owns the address; each active data-strobe interval owns one transaction.
// TAS keeps AS asserted across separate read/write strobes (lesson21682).
module thunderjaws_bus_bridge (
    input wire clk_sys, init_reset, game_reset,
    input wire as_active, rw, uds_n, lds_n,
    input wire [2:0] fc,
    input wire [23:1] address,
    input wire [15:0] write_data,
    output wire dtack, vpa_n,
    output reg [15:0] read_data,
    output wire request_valid,
    input wire request_ready,
    output reg [23:1] request_address,
    output reg request_read,
    output reg [1:0] request_lanes,
    output reg [15:0] request_data,
    input wire response_valid,
    input wire [15:0] response_data
);
    localparam IDLE=0, LANES=1, REQUEST=2, RESPONSE=3, HOLD=4, WAIT_IDLE=5;
    reg [2:0] state;
    reg discard;
    assign request_valid = state == REQUEST && as_active && !game_reset && !init_reset;
    assign dtack = state == HOLD && as_active && (!uds_n || !lds_n) && !game_reset && !init_reset;
    assign vpa_n = !(as_active && fc == 3'b111 && !game_reset && !init_reset);
    always @(posedge clk_sys) begin
        if (init_reset) begin
            state <= IDLE;
            discard <= 1'b0;
            request_address <= 0;
            request_read <= 1'b1;
            request_lanes <= 0;
            request_data <= 0;
            read_data <= 0;
        end else begin
            case (state)
                IDLE: begin
                    discard <= 1'b0;
                    if (!game_reset && as_active) begin
                        request_address <= address;
                        request_read <= rw;
                        state <= fc == 3'b111 ? WAIT_IDLE : LANES;
                    end
                end
                LANES: begin
                    if (game_reset || !as_active) state <= WAIT_IDLE;
                    else if (!uds_n || !lds_n) begin
                        request_read <= rw;
                        request_lanes <= {!uds_n,!lds_n};
                        request_data <= write_data;
                        state <= REQUEST;
                    end
                end
                REQUEST: begin
                    if (game_reset || !as_active) state <= WAIT_IDLE;
                    else if (request_ready) begin
                        if (response_valid) begin
                            read_data <= response_data;
                            state <= HOLD;
                        end else state <= RESPONSE;
                    end
                end
                RESPONSE: begin
                    if (game_reset || !as_active) discard <= 1'b1;
                    if (response_valid) begin
                        read_data <= response_data;
                        state <= !discard && as_active && !game_reset ? HOLD : WAIT_IDLE;
                    end
                end
                HOLD: begin
                    if (!as_active || game_reset) state <= WAIT_IDLE;
                    else if (uds_n && lds_n) state <= LANES;
                end
                WAIT_IDLE: if (!as_active && !game_reset) state <= IDLE;
                default: state <= WAIT_IDLE;
            endcase
        end
    end
endmodule
