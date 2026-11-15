// Explicit frame/line producer for the Big Fight table and combined-line units.
// All handshakes share clk_sys. Frame/raster epoch selection remains external.
module bigfight_video_producer (
    input  logic         clk_sys,
    input  logic         cold_reset,

    input  logic         frame_prepare_valid_i,
    output logic         frame_prepare_ready_o,
    input  logic [15:0]  frame_id_i,
    input  logic [15:0]  sprite_control_e0_i,
    input  logic [1:0]   line_bank_valid_i,
    input  logic [15:0]  tile_bank_live_i,
    input  logic [15:0]  mixing_control_live_i,

    output logic         snapshot_req_o,
`ifdef BIGFIGHT_EMPTY_E0
    output logic [15:0]  snapshot_epoch_o,
`endif
    output logic [15:0]  snapshot_control_e0_o,
    input  logic         snapshot_ready_i,

    output logic         tables_req_o,
    output logic [8:0]   tables_req_y_o,
    input  logic         tables_req_ready_i,
    input  logic         tables_rsp_valid_i,
    output logic         tables_rsp_ready_o,
    input  logic [8:0]   tables_rsp_y_i,
    input  logic [63:0]  tables_scrollx0_i,
    input  logic [63:0]  tables_scrollx_line_i,
    input  logic [63:0]  tables_scrolly0_i,
    input  logic [63:0]  tables_scrolly_line_i,
    input  logic [63:0]  tables_page_select_i,

    output logic         line_req_o,
    input  logic         line_ready_i,
    output logic [8:0]   line_y_o,
    output logic [63:0]  line_scrollx0_o,
    output logic [63:0]  line_scrollx_line_o,
    output logic [63:0]  line_scrolly0_o,
    output logic [63:0]  line_scrolly_line_o,
    output logic [63:0]  line_page_select_o,
    output logic [15:0]  line_tile_bank_o,
    output logic [15:0]  line_mixing_control_o,

    input  logic         line_done_valid_i,
    output logic         line_done_ready_o,
    input  logic         line_done_bank_i,
    input  logic [8:0]   line_done_y_i,
    input  logic         line_done_late_i,
    input  logic [11:0]  line_done_cycles_i,
    output logic         line_done_valid_o,
    input  logic         line_done_ready_i,
    output logic [15:0]  line_done_frame_id_o,
    output logic         line_done_bank_o,
    output logic [8:0]   line_done_y_o,
    output logic         line_done_late_o,
    output logic [11:0]  line_done_cycles_o,

    output logic         frame_done_valid_o,
    input  logic         frame_done_ready_i,
    output logic [15:0]  frame_done_id_o,
    output logic         protocol_fault_o
);
    typedef enum logic [3:0] {
        ST_IDLE,
        ST_SNAPSHOT_REQ,
        ST_SNAPSHOT_WAIT_BUSY,
        ST_SNAPSHOT_WAIT_DONE,
        ST_TABLE_REQ,
        ST_TABLE_RSP,
        ST_LINE_OFFER,
        ST_LINE_DONE,
        ST_FRAME_DONE,
        ST_FAULT
    } state_t;

    state_t state_q;
    logic [15:0] frame_id_q;
    logic [15:0] sprite_control_q;
    logic [8:0] line_y_q;
    logic [63:0] scrollx0_q;
    logic [63:0] scrollx_line_q;
    logic [63:0] scrolly0_q;
    logic [63:0] scrolly_line_q;
    logic [63:0] page_select_q;
    logic [15:0] tile_bank_q;
    logic [15:0] mixing_control_q;
    logic frame_prepare_accept;
    logic line_done_take;

    always_comb begin
        frame_prepare_ready_o = 1'b0;
        snapshot_req_o = 1'b0;
        snapshot_control_e0_o = sprite_control_q;
`ifdef BIGFIGHT_EMPTY_E0
        snapshot_epoch_o = frame_id_q;
`endif
        tables_req_o = 1'b0;
        tables_req_y_o = line_y_q;
        tables_rsp_ready_o = 1'b0;
        line_req_o = 1'b0;
        line_y_o = line_y_q;
        line_scrollx0_o = scrollx0_q;
        line_scrollx_line_o = scrollx_line_q;
        line_scrolly0_o = scrolly0_q;
        line_scrolly_line_o = scrolly_line_q;
        line_page_select_o = page_select_q;
        line_tile_bank_o = tile_bank_q;
        line_mixing_control_o = mixing_control_q;
        line_done_ready_o = 1'b0;
        line_done_valid_o = 1'b0;
        line_done_frame_id_o = frame_id_q;
        line_done_bank_o = line_done_bank_i;
        line_done_y_o = line_done_y_i;
        line_done_late_o = line_done_late_i;
        line_done_cycles_o = line_done_cycles_i;
        frame_done_valid_o = 1'b0;
        frame_done_id_o = frame_id_q;

        if (!cold_reset) begin
            case (state_q)
                ST_IDLE: begin
                    frame_prepare_ready_o = (line_bank_valid_i == 2'b00) &&
                                            snapshot_ready_i;
                end
                ST_SNAPSHOT_REQ: snapshot_req_o = 1'b1;
                ST_TABLE_REQ: tables_req_o = 1'b1;
                ST_TABLE_RSP: tables_rsp_ready_o = 1'b1;
                ST_LINE_OFFER: line_req_o = 1'b1;
                ST_LINE_DONE: begin
                    line_done_ready_o = line_done_ready_i;
                    line_done_valid_o = line_done_valid_i;
                end
                ST_FRAME_DONE: frame_done_valid_o = 1'b1;
                default: ;
            endcase
        end
    end

    assign frame_prepare_accept = frame_prepare_valid_i && frame_prepare_ready_o;
    assign line_done_take = line_done_valid_o && line_done_ready_i;

    always_ff @(posedge clk_sys) begin
        if (cold_reset) begin
            state_q <= ST_IDLE;
            frame_id_q <= 16'b0;
            sprite_control_q <= 16'b0;
            line_y_q <= 9'b0;
            scrollx0_q <= 64'b0;
            scrollx_line_q <= 64'b0;
            scrolly0_q <= 64'b0;
            scrolly_line_q <= 64'b0;
            page_select_q <= 64'b0;
            tile_bank_q <= 16'b0;
            mixing_control_q <= 16'b0;
            protocol_fault_o <= 1'b0;
        end else begin
            case (state_q)
                ST_IDLE: begin
                    if (frame_prepare_accept) begin
                        frame_id_q <= frame_id_i;
                        sprite_control_q <= sprite_control_e0_i;
                        line_y_q <= 9'd0;
                        state_q <= ST_SNAPSHOT_REQ;
                    end
                end

                // snapshot_ready_i is high before request acceptance, goes low
                // while the 2,052-word copy runs, then returns high at completion.
                ST_SNAPSHOT_REQ: begin
                    if (snapshot_req_o && snapshot_ready_i)
                        state_q <= ST_SNAPSHOT_WAIT_BUSY;
                end

                ST_SNAPSHOT_WAIT_BUSY: begin
                    if (!snapshot_ready_i)
                        state_q <= ST_SNAPSHOT_WAIT_DONE;
                end

                ST_SNAPSHOT_WAIT_DONE: begin
                    if (snapshot_ready_i)
                        state_q <= ST_TABLE_REQ;
                end

                ST_TABLE_REQ: begin
                    if (tables_req_o && tables_req_ready_i)
                        state_q <= ST_TABLE_RSP;
                end

                ST_TABLE_RSP: begin
                    if (tables_rsp_valid_i && tables_rsp_ready_o) begin
                        if (tables_rsp_y_i != line_y_q) begin
                            protocol_fault_o <= 1'b1;
                            state_q <= ST_FAULT;
                        end else begin
                            scrollx0_q <= tables_scrollx0_i;
                            scrollx_line_q <= tables_scrollx_line_i;
                            scrolly0_q <= tables_scrolly0_i;
                            scrolly_line_q <= tables_scrolly_line_i;
                            page_select_q <= tables_page_select_i;
                            // Sample the live board registers for this line when
                            // its stable line-request payload is first presented.
                            tile_bank_q <= tile_bank_live_i;
                            mixing_control_q <= mixing_control_live_i;
                            state_q <= ST_LINE_OFFER;
                        end
                    end
                end

                ST_LINE_OFFER: begin
                    if (line_req_o && line_ready_i)
                        state_q <= ST_LINE_DONE;
                end

                ST_LINE_DONE: begin
                    if (line_done_valid_i && (line_done_y_i != line_y_q))
                        protocol_fault_o <= 1'b1;
                    if (line_done_take) begin
                        if (line_done_y_i != line_y_q) begin
                            state_q <= ST_FAULT;
                        end else if (line_y_q == 9'd239) begin
                            state_q <= ST_FRAME_DONE;
                        end else begin
                            line_y_q <= line_y_q + 9'd1;
                            state_q <= ST_TABLE_REQ;
                        end
                    end
                end

                ST_FRAME_DONE: begin
                    if (frame_done_valid_o && frame_done_ready_i)
                        state_q <= ST_IDLE;
                end

                ST_FAULT: begin
                    state_q <= ST_FAULT;
                end

                default: begin
                    protocol_fault_o <= 1'b1;
                    state_q <= ST_FAULT;
                end
            endcase
        end
    end
endmodule
