// MAME-derived Big Fight per-line scroll/page table reader.
// All requests and responses share clk_sys; no clock enable or generated clock
// is introduced. The VRAM service must flush any outstanding read on cold_reset.
module bigfight_video_tables (
    input  logic        clk_sys,
    input  logic        cold_reset,
    input  logic        req_i,
    input  logic [8:0]  req_y_i,
    output logic        req_ready_o,
    output logic        rsp_valid_o,
    input  logic        rsp_ready_i,
    output logic [8:0]  rsp_y_o,
    output logic [63:0] scrollx0_o,
    output logic [63:0] scrollx_line_o,
    output logic [63:0] scrolly0_o,
    output logic [63:0] scrolly_line_o,
    output logic [63:0] page_select_o,
    output logic        vram_req_o,
    input  logic        vram_ready_i,
    output logic        vram_bank_o,
    output logic [14:0] vram_word_addr_o,
    input  logic        vram_rsp_valid_i,
    output logic        vram_rsp_ready_o,
    input  logic [15:0] vram_rsp_data_i
);
    localparam logic [1:0] ST_IDLE = 2'd0;
    localparam logic [1:0] ST_READ = 2'd1;
    localparam logic [1:0] ST_WAIT = 2'd2;
    localparam logic [1:0] ST_HOLD = 2'd3;

    logic [1:0] state_q;
    logic [1:0] layer_q;
    logic [2:0] table_q;
    logic [8:0] line_y_q;
    logic [14:0] table_base;
    logic [14:0] address_calc;
    logic [63:0] scrollx0_q;
    logic [63:0] scrollx_line_q;
    logic [63:0] scrolly0_q;
    logic [63:0] scrolly_line_q;
    logic [63:0] page_select_q;

    always_comb begin
        // MAME draw_bg_layers maps layers 0/2 to offset 0x200 and 1/3
        // to offset 0. The bank is selected by layer[1].
        table_base = layer_q[0] ? 15'd0 : 15'd512;
        case (table_q)
            3'd0: address_calc = table_base;
            3'd1: address_calc = table_base + {6'd0, line_y_q};
            3'd2: address_calc = table_base + 15'd256;
            3'd3: address_calc = table_base + 15'd256 + {6'd0, line_y_q};
            3'd4: address_calc = table_base + 15'd511;
            default: address_calc = 15'd0;
        endcase
    end

    assign req_ready_o = (state_q == ST_IDLE) && !cold_reset;
    assign rsp_valid_o = (state_q == ST_HOLD) && !cold_reset;
    assign rsp_y_o = line_y_q;
    assign scrollx0_o = scrollx0_q;
    assign scrollx_line_o = scrollx_line_q;
    assign scrolly0_o = scrolly0_q;
    assign scrolly_line_o = scrolly_line_q;
    assign page_select_o = page_select_q;
    assign vram_req_o = (state_q == ST_READ) && !cold_reset;
    assign vram_bank_o = layer_q[1];
    assign vram_word_addr_o = address_calc;
    assign vram_rsp_ready_o = (state_q == ST_WAIT) && !cold_reset;

    always_ff @(posedge clk_sys) begin
        if (cold_reset) begin
            state_q <= ST_IDLE;
            layer_q <= 2'd0;
            table_q <= 3'd0;
            line_y_q <= 9'd0;
            scrollx0_q <= 64'd0;
            scrollx_line_q <= 64'd0;
            scrolly0_q <= 64'd0;
            scrolly_line_q <= 64'd0;
            page_select_q <= 64'd0;
        end else begin
            case (state_q)
                ST_IDLE: begin
                    if (req_i && req_ready_o) begin
                        line_y_q <= req_y_i;
                        layer_q <= 2'd0;
                        table_q <= 3'd0;
                        scrollx0_q <= 64'd0;
                        scrollx_line_q <= 64'd0;
                        scrolly0_q <= 64'd0;
                        scrolly_line_q <= 64'd0;
                        page_select_q <= 64'd0;
                        state_q <= ST_READ;
                    end
                end
                ST_READ: begin
                    if (vram_ready_i)
                        state_q <= ST_WAIT;
                end
                ST_WAIT: begin
                    if (vram_rsp_valid_i && vram_rsp_ready_o) begin
                        case (table_q)
                            3'd0: begin
                                case (layer_q)
                                    2'd0: scrollx0_q[15:0] <= vram_rsp_data_i;
                                    2'd1: scrollx0_q[31:16] <= vram_rsp_data_i;
                                    2'd2: scrollx0_q[47:32] <= vram_rsp_data_i;
                                    2'd3: scrollx0_q[63:48] <= vram_rsp_data_i;
                                endcase
                            end
                            3'd1: begin
                                case (layer_q)
                                    2'd0: scrollx_line_q[15:0] <= vram_rsp_data_i;
                                    2'd1: scrollx_line_q[31:16] <= vram_rsp_data_i;
                                    2'd2: scrollx_line_q[47:32] <= vram_rsp_data_i;
                                    2'd3: scrollx_line_q[63:48] <= vram_rsp_data_i;
                                endcase
                            end
                            3'd2: begin
                                case (layer_q)
                                    2'd0: scrolly0_q[15:0] <= vram_rsp_data_i;
                                    2'd1: scrolly0_q[31:16] <= vram_rsp_data_i;
                                    2'd2: scrolly0_q[47:32] <= vram_rsp_data_i;
                                    2'd3: scrolly0_q[63:48] <= vram_rsp_data_i;
                                endcase
                            end
                            3'd3: begin
                                case (layer_q)
                                    2'd0: scrolly_line_q[15:0] <= vram_rsp_data_i;
                                    2'd1: scrolly_line_q[31:16] <= vram_rsp_data_i;
                                    2'd2: scrolly_line_q[47:32] <= vram_rsp_data_i;
                                    2'd3: scrolly_line_q[63:48] <= vram_rsp_data_i;
                                endcase
                            end
                            3'd4: begin
                                case (layer_q)
                                    2'd0: page_select_q[15:0] <= vram_rsp_data_i;
                                    2'd1: page_select_q[31:16] <= vram_rsp_data_i;
                                    2'd2: page_select_q[47:32] <= vram_rsp_data_i;
                                    2'd3: page_select_q[63:48] <= vram_rsp_data_i;
                                endcase
                            end
                            default: begin end
                        endcase

                        if ((layer_q == 2'd3) && (table_q == 3'd4)) begin
                            state_q <= ST_HOLD;
                        end else if (table_q == 3'd4) begin
                            table_q <= 3'd0;
                            layer_q <= layer_q + 2'd1;
                            state_q <= ST_READ;
                        end else begin
                            table_q <= table_q + 3'd1;
                            state_q <= ST_READ;
                        end
                    end
                end
                ST_HOLD: begin
                    if (rsp_ready_i)
                        state_q <= ST_IDLE;
                end
                default: begin
                    state_q <= ST_IDLE;
                    layer_q <= 2'd0;
                    table_q <= 3'd0;
                end
            endcase
        end
    end
endmodule
