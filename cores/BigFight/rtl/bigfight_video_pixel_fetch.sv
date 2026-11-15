// Tagged RGB read adapter for one resident Big Fight combined video line.
// All ports use clk_sys. cold_reset must be shared with both backends so an
// old line/palette response cannot survive cancellation and qualify later.
module bigfight_video_pixel_fetch (
    input  logic         clk_sys,
    input  logic         cold_reset,

    input  logic         req_valid_i,
    output logic         req_ready_o,
    input  logic         req_bank_i,
    input  logic [8:0]   req_y_i,
    input  logic [8:0]   req_x_i,

    output logic         rsp_valid_o,
    input  logic         rsp_ready_i,
    output logic         rsp_bank_o,
    output logic [8:0]   rsp_y_o,
    output logic [8:0]   rsp_x_o,
    output logic [23:0]  rsp_rgb_o,
    output logic         rsp_reject_o,
    output logic [15:0]  rsp_latency_o,
    output logic         protocol_fault_o,

    output logic         scan_req_o,
    input  logic         scan_ready_i,
    output logic         scan_bank_o,
    output logic [8:0]   scan_y_o,
    output logic [8:0]   scan_x_o,
    input  logic         scan_rsp_valid_i,
    output logic         scan_rsp_ready_o,
    input  logic         scan_rsp_bank_i,
    input  logic [8:0]   scan_rsp_y_i,
    input  logic [8:0]   scan_rsp_x_i,
    input  logic [12:0]  scan_rsp_palette_i,
    input  logic         scan_rsp_shadow_i,
    input  logic         scan_rsp_reject_i,

    output logic         palette_req_o,
    input  logic         palette_ready_i,
    output logic [12:0]  palette_addr_o,
    input  logic         palette_rsp_valid_i,
    output logic         palette_rsp_ready_o,
    input  logic [15:0]  palette_rsp_data_i
);
    localparam logic [2:0] ST_IDLE          = 3'd0;
    localparam logic [2:0] ST_SCAN_REQUEST  = 3'd1;
    localparam logic [2:0] ST_SCAN_RESPONSE = 3'd2;
    localparam logic [2:0] ST_PALETTE_REQ   = 3'd3;
    localparam logic [2:0] ST_PALETTE_RSP   = 3'd4;
    localparam logic [2:0] ST_OUTPUT        = 3'd5;

    logic [2:0] state_q;
    logic req_bank_q;
    logic [8:0] req_y_q, req_x_q;
    logic [12:0] palette_addr_q;
    logic shadow_q;
    logic [15:0] latency_count_q;

    logic [7:0] red, green, blue;
    wire [23:0] converted_rgb = {red, green, blue};
    wire [15:0] latency_next = (latency_count_q == 16'hffff)
                             ? 16'hffff : latency_count_q + 16'd1;
    wire scan_tag_matches = (scan_rsp_bank_i == req_bank_q) &&
                            (scan_rsp_y_i == req_y_q) &&
                            (scan_rsp_x_i == req_x_q);

    bigfight_palette_rgb u_palette_rgb (
        .palette_word(palette_rsp_data_i),
        .shadow(shadow_q),
        .red(red), .green(green), .blue(blue)
    );

    always_comb begin
        req_ready_o = 1'b0;
        scan_req_o = 1'b0;
        scan_bank_o = req_bank_q;
        scan_y_o = req_y_q;
        scan_x_o = req_x_q;
        scan_rsp_ready_o = 1'b0;
        palette_req_o = 1'b0;
        palette_addr_o = palette_addr_q;
        palette_rsp_ready_o = 1'b0;

        if (!cold_reset) begin
            case (state_q)
                ST_IDLE:          req_ready_o = 1'b1;
                ST_SCAN_REQUEST:  scan_req_o = 1'b1;
                ST_SCAN_RESPONSE: scan_rsp_ready_o = 1'b1;
                ST_PALETTE_REQ:   palette_req_o = 1'b1;
                ST_PALETTE_RSP:   palette_rsp_ready_o = 1'b1;
                // Reuse the response-consume edge for the next request. This
                // remains one outstanding transaction: acceptance is possible
                // only when the old result is simultaneously retired.
                ST_OUTPUT:        req_ready_o = rsp_valid_o && rsp_ready_i;
                default: ;
            endcase
        end
    end

    always_ff @(posedge clk_sys) begin
        if (cold_reset) begin
            state_q <= ST_IDLE;
            req_bank_q <= 1'b0;
            req_y_q <= 9'b0;
            req_x_q <= 9'b0;
            palette_addr_q <= 13'b0;
            shadow_q <= 1'b0;
            latency_count_q <= 16'b0;
            rsp_valid_o <= 1'b0;
            rsp_bank_o <= 1'b0;
            rsp_y_o <= 9'b0;
            rsp_x_o <= 9'b0;
            rsp_rgb_o <= 24'b0;
            rsp_reject_o <= 1'b0;
            rsp_latency_o <= 16'b0;
            protocol_fault_o <= 1'b0;
        end else begin
            case (state_q)
                ST_IDLE: begin
                    if (req_valid_i && req_ready_o) begin
                        req_bank_q <= req_bank_i;
                        req_y_q <= req_y_i;
                        req_x_q <= req_x_i;
                        latency_count_q <= 16'b0;
                        state_q <= ST_SCAN_REQUEST;
                    end
                end

                ST_SCAN_REQUEST: begin
                    if (latency_count_q != 16'hffff)
                        latency_count_q <= latency_count_q + 16'd1;
                    if (scan_req_o && scan_ready_i)
                        state_q <= ST_SCAN_RESPONSE;
                end

                ST_SCAN_RESPONSE: begin
                    if (latency_count_q != 16'hffff)
                        latency_count_q <= latency_count_q + 16'd1;
                    if (scan_rsp_valid_i && scan_rsp_ready_o) begin
                        rsp_bank_o <= req_bank_q;
                        rsp_y_o <= req_y_q;
                        rsp_x_o <= req_x_q;
                        rsp_rgb_o <= 24'b0;
                        rsp_reject_o <= 1'b0;
                        rsp_latency_o <= latency_next;
                        if (!scan_tag_matches) begin
                            protocol_fault_o <= 1'b1;
                            rsp_reject_o <= 1'b1;
                            rsp_valid_o <= 1'b1;
                            state_q <= ST_OUTPUT;
                        end else if (scan_rsp_reject_i) begin
                            rsp_reject_o <= 1'b1;
                            rsp_valid_o <= 1'b1;
                            state_q <= ST_OUTPUT;
                        end else begin
                            palette_addr_q <= scan_rsp_palette_i;
                            shadow_q <= scan_rsp_shadow_i;
                            state_q <= ST_PALETTE_REQ;
                        end
                    end
                end

                ST_PALETTE_REQ: begin
                    if (latency_count_q != 16'hffff)
                        latency_count_q <= latency_count_q + 16'd1;
                    if (palette_req_o && palette_ready_i)
                        state_q <= ST_PALETTE_RSP;
                end

                ST_PALETTE_RSP: begin
                    if (latency_count_q != 16'hffff)
                        latency_count_q <= latency_count_q + 16'd1;
                    if (palette_rsp_valid_i && palette_rsp_ready_o) begin
                        rsp_bank_o <= req_bank_q;
                        rsp_y_o <= req_y_q;
                        rsp_x_o <= req_x_q;
                        rsp_rgb_o <= converted_rgb;
                        rsp_reject_o <= 1'b0;
                        rsp_latency_o <= latency_next;
                        rsp_valid_o <= 1'b1;
                        state_q <= ST_OUTPUT;
                    end
                end

                ST_OUTPUT: begin
                    if (rsp_valid_o && rsp_ready_i) begin
                        rsp_valid_o <= 1'b0;
                        if (req_valid_i && req_ready_o) begin
                            req_bank_q <= req_bank_i;
                            req_y_q <= req_y_i;
                            req_x_q <= req_x_i;
                            latency_count_q <= 16'b0;
                            state_q <= ST_SCAN_REQUEST;
                        end else begin
                            state_q <= ST_IDLE;
                        end
                    end
                end

                default: begin
                    state_q <= ST_IDLE;
                    rsp_valid_o <= 1'b0;
                    protocol_fault_o <= 1'b1;
                end
            endcase
        end
    end
endmodule
