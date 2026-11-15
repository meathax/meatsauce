// Bounded implementation policy, not a claim of the PCB's internal DMA latch.
// Prefer the accepted E0 write in blank; when no selection is written, prepare
// unchanged state at line250. Prove this admission policy in live game traces.
module bigfight_frame_prepare (
    input logic clk_sys,cold_reset,load_mode,
    input logic ce_pixel_i,vblank_i,vblank_start_i,
    input logic [8:0] raster_x_i,raster_y_i,
`ifdef BIGFIGHT_EMPTY_E0
    input logic safe_empty_selection_i,empty_population_fault_i,
`endif
    input logic e0_write_accept_i,
    input logic [15:0] e0_write_data_i,
    input logic e0_write_uds_n_i,e0_write_lds_n_i,
    output logic object_req_o,
    input logic object_req_ready_i,
    output logic [7:0] object_word_address_o,
    input logic object_rsp_valid_i,
    output logic object_rsp_ready_o,
    input logic [15:0] object_rsp_data_i,
    output logic frame_prepare_valid_o,
    input logic frame_prepare_ready_i,
    output logic [15:0] frame_prepare_id_o,sprite_control_e0_o,
    output logic frame_epoch_valid_o,
    output logic protocol_fault_o,deadline_miss_o,
    output logic [31:0] prepared_count_o,late_selection_count_o,missed_window_count_o
);
    localparam logic [1:0] ST_IDLE=0,ST_READ_REQ=1,ST_READ_RSP=2,ST_OFFER=3;
    logic [1:0] state_q;
    logic [15:0] window_id_q,command_id_q,e0_q;
    logic started_q,accepted_q,miss_seen_q;
    // Compare only written byte lanes against the actual object-RAM value
    // captured for this frame. Startup can rewrite unchanged E0 in visible time.
    wire [15:0] e0_write_mask={{8{!e0_write_uds_n_i}},{8{!e0_write_lds_n_i}}};
    wire e0_write_changes_selected=|((e0_write_data_i ^ e0_q) & e0_write_mask);
    wire fallback = ce_pixel_i && raster_x_i==9'd0 && raster_y_i==9'd250;
    wire start_take = !cold_reset && !load_mode && vblank_i && !started_q &&
                      state_q==ST_IDLE && (e0_write_accept_i || fallback);
    function automatic [31:0] increment_sat(input logic [31:0] v);
        increment_sat=(&v)?v:v+32'd1;
    endfunction
    assign object_req_o=!cold_reset && !load_mode && state_q==ST_READ_REQ;
    assign object_word_address_o=8'he0;
    assign object_rsp_ready_o=!cold_reset && !load_mode && state_q==ST_READ_RSP;
    assign frame_prepare_valid_o=!cold_reset && !load_mode && state_q==ST_OFFER;
    assign frame_prepare_id_o=command_id_q;
    assign sprite_control_e0_o=e0_q;
    assign frame_epoch_valid_o=frame_prepare_valid_o && frame_prepare_ready_i;
    always_ff @(posedge clk_sys) begin
        if(cold_reset) begin
            state_q<=ST_IDLE;window_id_q<=0;command_id_q<=0;e0_q<=0;
            started_q<=0;accepted_q<=0;miss_seen_q<=0;
            protocol_fault_o<=0;deadline_miss_o<=0;
            prepared_count_o<=0;late_selection_count_o<=0;missed_window_count_o<=0;
        end else if(!load_mode) begin
            if(vblank_start_i) begin
                window_id_q<=window_id_q+16'd1;
                started_q<=0;accepted_q<=0;miss_seen_q<=0;
                if(state_q!=ST_IDLE) protocol_fault_o<=1;
            end
            if(e0_write_accept_i && (!vblank_i || started_q) && e0_write_changes_selected) begin
                late_selection_count_o<=increment_sat(late_selection_count_o);
                // The committed snapshot is immutable. Later accepted CPU writes
                // belong to the next blank; retain diagnostics without faulting.
                // Before commit, a changed selection still violates admission.
                if (!accepted_q) begin
`ifdef BIGFIGHT_EMPTY_E0
                if (safe_empty_selection_i !== 1'b1) protocol_fault_o<=1;
`else
                protocol_fault_o<=1;
`endif
                end
            end
            if(!vblank_i && !accepted_q && !miss_seen_q) begin
                deadline_miss_o<=1;miss_seen_q<=1;
                missed_window_count_o<=increment_sat(missed_window_count_o);
            end
            case(state_q)
                ST_IDLE: if(start_take) begin
                    command_id_q<=window_id_q;started_q<=1;state_q<=ST_READ_REQ;
                end
                ST_READ_REQ: if(object_req_o && object_req_ready_i) state_q<=ST_READ_RSP;
                ST_READ_RSP: if(object_rsp_valid_i && object_rsp_ready_o) begin
                    e0_q<=object_rsp_data_i;state_q<=ST_OFFER;
                end
                ST_OFFER: if(frame_epoch_valid_o) begin
                    prepared_count_o<=increment_sat(prepared_count_o);
                    accepted_q<=1;state_q<=ST_IDLE;
                    if(!vblank_i) begin protocol_fault_o<=1;deadline_miss_o<=1;end
                end
                default: begin state_q<=ST_IDLE;protocol_fault_o<=1;end
            endcase
        end
    end
endmodule
