// Single-clock arbiter joining the video-table and tile-map clients to the
// shared work-RAM VRAM read port. One request remains owned through response
// consumption; cold_reset is shared with the backend and cancels that work.
module bigfight_video_vram_arb (
    input  logic        clk_sys,
    input  logic        cold_reset,

    input  logic        c0_req_valid_i,
    output logic        c0_req_ready_o,
    input  logic        c0_req_bank_i,
    input  logic [14:0] c0_req_word_address_i,
    output logic        c0_rsp_valid_o,
    input  logic        c0_rsp_ready_i,
    output logic [15:0] c0_rsp_data_o,

    input  logic        c1_req_valid_i,
    output logic        c1_req_ready_o,
    input  logic        c1_req_bank_i,
    input  logic [14:0] c1_req_word_address_i,
    output logic        c1_rsp_valid_o,
    input  logic        c1_rsp_ready_i,
    output logic [15:0] c1_rsp_data_o,

    output logic        mem_req_valid_o,
    input  logic        mem_req_ready_i,
    output logic        mem_req_bank_o,
    output logic [14:0] mem_req_word_address_o,
    input  logic        mem_rsp_valid_i,
    output logic        mem_rsp_ready_o,
    input  logic [15:0] mem_rsp_data_i
);
    localparam logic [1:0] ST_IDLE       = 2'd0;
    localparam logic [1:0] ST_MEM_REQ    = 2'd1;
    localparam logic [1:0] ST_MEM_RSP    = 2'd2;
    localparam logic [1:0] ST_CLIENT_RSP = 2'd3;

    logic [1:0] state_q;
    logic       owner_q;
    logic       prefer_c1_q;
    logic       req_bank_q;
    logic [14:0] req_word_address_q;
    logic [15:0] rsp_data_q;

    always_comb begin
        c0_req_ready_o = 1'b0;
        c1_req_ready_o = 1'b0;
        c0_rsp_valid_o = 1'b0;
        c1_rsp_valid_o = 1'b0;
        c0_rsp_data_o = rsp_data_q;
        c1_rsp_data_o = rsp_data_q;
        mem_req_valid_o = 1'b0;
        mem_req_bank_o = req_bank_q;
        mem_req_word_address_o = req_word_address_q;
        mem_rsp_ready_o = 1'b0;

        if (!cold_reset) begin
            case (state_q)
                ST_IDLE: begin
                    if (prefer_c1_q) begin
                        if (c1_req_valid_i)
                            c1_req_ready_o = 1'b1;
                        else if (c0_req_valid_i)
                            c0_req_ready_o = 1'b1;
                    end else begin
                        if (c0_req_valid_i)
                            c0_req_ready_o = 1'b1;
                        else if (c1_req_valid_i)
                            c1_req_ready_o = 1'b1;
                    end
                end
                ST_MEM_REQ: begin
                    mem_req_valid_o = 1'b1;
                end
                ST_MEM_RSP: begin
                    mem_rsp_ready_o = 1'b1;
                end
                ST_CLIENT_RSP: begin
                    if (owner_q)
                        c1_rsp_valid_o = 1'b1;
                    else
                        c0_rsp_valid_o = 1'b1;
                end
                default: begin
                    // The synchronous reset below returns illegal state to idle.
                end
            endcase
        end
    end

    always_ff @(posedge clk_sys) begin
        if (cold_reset) begin
            state_q <= ST_IDLE;
            owner_q <= 1'b0;
            prefer_c1_q <= 1'b0;
            req_bank_q <= 1'b0;
            req_word_address_q <= 15'd0;
            rsp_data_q <= 16'd0;
        end else begin
            case (state_q)
                ST_IDLE: begin
                    if (c0_req_valid_i && c0_req_ready_o) begin
                        owner_q <= 1'b0;
                        req_bank_q <= c0_req_bank_i;
                        req_word_address_q <= c0_req_word_address_i;
                        state_q <= ST_MEM_REQ;
                    end else if (c1_req_valid_i && c1_req_ready_o) begin
                        owner_q <= 1'b1;
                        req_bank_q <= c1_req_bank_i;
                        req_word_address_q <= c1_req_word_address_i;
                        state_q <= ST_MEM_REQ;
                    end
                end
                ST_MEM_REQ: begin
                    if (mem_req_valid_o && mem_req_ready_i)
                        state_q <= ST_MEM_RSP;
                end
                ST_MEM_RSP: begin
                    if (mem_rsp_valid_i && mem_rsp_ready_o) begin
                        rsp_data_q <= mem_rsp_data_i;
                        state_q <= ST_CLIENT_RSP;
                    end
                end
                ST_CLIENT_RSP: begin
                    if ((owner_q && c1_rsp_valid_o && c1_rsp_ready_i) ||
                        (!owner_q && c0_rsp_valid_o && c0_rsp_ready_i)) begin
                        // Rotate after completion so a continuously waiting peer
                        // gets the next transaction even if this client stays busy.
                        prefer_c1_q <= !owner_q;
                        state_q <= ST_IDLE;
                    end
                end
                default: begin
                    state_q <= ST_IDLE;
                end
            endcase
        end
    end
endmodule
