// Full tagged video datapath. Caller selects frame epoch and scanout timing.
// All memory services and state share clk_sys and cold_reset.
module bigfight_video_pipeline (
    input wire cyclwarr_i,
    input logic  clk_sys,
    input logic  cold_reset,
`ifdef BIGFIGHT_EMPTY_E0
    input logic empty_invalidate_i,empty_head_accept_i,empty_head_bank_i,
    input logic [15:0] empty_head_data_i,empty_live_control_i,empty_candidate_control_i,
    input logic empty_head_uds_n_i,empty_head_lds_n_i,
    output logic empty_safe_o,empty_protocol_fault_o,empty_population_fault_o,
`endif
    input logic  frame_prepare_valid_i,
    output logic  frame_prepare_ready_o,
    input logic [15:0] frame_id_i,
    input logic [15:0] sprite_control_e0_i,
    output logic [1:0] line_bank_valid_o,
    input logic [15:0] tile_bank_live_i,
    input logic [15:0] mixing_control_live_i,
    output logic  line_done_valid_o,
    input logic  line_done_ready_i,
    output logic [15:0] line_done_frame_id_o,
    output logic  line_done_bank_o,
    output logic [8:0] line_done_y_o,
    output logic  line_done_late_o,
    output logic [11:0] line_done_cycles_o,
    output logic  frame_done_valid_o,
    input logic  frame_done_ready_i,
    output logic [15:0] frame_done_id_o,
    output logic  spram_req_o,
    input logic  spram_ready_i,
    output logic [12:0] spram_word_addr_o,
    input logic  spram_valid_i,
    input logic [15:0] spram_data_i,
    output logic  tile_gfx_req_o,
    input logic  tile_gfx_ready_i,
    output logic [16:0] tile_gfx_row_addr_o,
    input logic  tile_gfx_rsp_valid_i,
    output logic  tile_gfx_rsp_ready_o,
    input logic [23:0] tile_gfx_rsp_data_i,
    output logic  tile_clut_req_o,
    input logic  tile_clut_ready_i,
    output logic [16:0] tile_clut_row_addr_o,
    input logic  tile_clut_rsp_valid_i,
    output logic  tile_clut_rsp_ready_o,
    input logic [63:0] tile_clut_rsp_data_i,
    output logic  sprite_rom_req_o,
    input logic  sprite_rom_ready_i,
    output logic  sprite_rom_bank_o,
    output logic [20:0] sprite_rom_byte_addr_o,
    input logic  sprite_rom_valid_i,
    input logic [31:0] sprite_rom_data_i,
    output logic  sprite_clut_req_o,
    input logic  sprite_clut_ready_i,
    output logic [8:0] sprite_clut_color_o,
    input logic  sprite_clut_valid_i,
    input logic [127:0] sprite_clut_bytes_i,
    output logic [11:0] line_done_collect_cycles_o,
    output logic [8:0] line_bank_y0_o,
    output logic [8:0] line_bank_y1_o,
    output logic [1:0] line_bank_late_o,
    input logic  line_release_valid_i,
    output logic  line_release_ready_o,
    input logic  line_release_bank_i,
    output logic  deadline_miss_o,
    input logic  pixel_req_valid_i,
    output logic  pixel_req_ready_o,
    input logic  pixel_req_bank_i,
    input logic [8:0] pixel_req_y_i,
    input logic [8:0] pixel_req_x_i,
    output logic  pixel_rsp_valid_o,
    input logic  pixel_rsp_ready_i,
    output logic  pixel_rsp_bank_o,
    output logic [8:0] pixel_rsp_y_o,
    output logic [8:0] pixel_rsp_x_o,
    output logic [23:0] pixel_rsp_rgb_o,
    output logic  pixel_rsp_reject_o,
    output logic [15:0] pixel_rsp_latency_o,
    output logic  palette_req_o,
    input logic  palette_ready_i,
    output logic [12:0] palette_addr_o,
    input logic  palette_rsp_valid_i,
    output logic  palette_rsp_ready_o,
    input logic [15:0] palette_rsp_data_i,
    output logic  vram_req_valid_o,
    input logic  vram_req_ready_i,
    output logic  vram_req_bank_o,
    output logic [14:0] vram_req_word_address_o,
    input logic  vram_rsp_valid_i,
    output logic  vram_rsp_ready_o,
    input logic [15:0] vram_rsp_data_i,
    output logic  spram_rsp_ready_o,
    output logic  protocol_fault_o
);
    logic  p_snapshot_req_o;
    logic [15:0] p_snapshot_control_e0_o;
`ifdef BIGFIGHT_EMPTY_E0
    logic [15:0] p_snapshot_epoch_o;
`endif
    logic  p_snapshot_ready_i;
    logic  p_tables_req_o;
    logic [8:0] p_tables_req_y_o;
    logic  p_tables_req_ready_i;
    logic  p_tables_rsp_valid_i;
    logic  p_tables_rsp_ready_o;
    logic [8:0] p_tables_rsp_y_i;
    logic [63:0] p_tables_scrollx0_i;
    logic [63:0] p_tables_scrollx_line_i;
    logic [63:0] p_tables_scrolly0_i;
    logic [63:0] p_tables_scrolly_line_i;
    logic [63:0] p_tables_page_select_i;
    logic  p_line_req_o;
    logic  p_line_ready_i;
    logic [8:0] p_line_y_o;
    logic [63:0] p_line_scrollx0_o;
    logic [63:0] p_line_scrollx_line_o;
    logic [63:0] p_line_scrolly0_o;
    logic [63:0] p_line_scrolly_line_o;
    logic [63:0] p_line_page_select_o;
    logic [15:0] p_line_tile_bank_o;
    logic [15:0] p_line_mixing_control_o;
    logic  p_line_done_valid_i;
    logic  p_line_done_ready_o;
    logic  p_line_done_bank_i;
    logic [8:0] p_line_done_y_i;
    logic  p_line_done_late_i;
    logic [11:0] p_line_done_cycles_i;
    logic  p_protocol_fault_o;
    logic  t_vram_req_o;
    logic  t_vram_ready_i;
    logic  t_vram_bank_o;
    logic [14:0] t_vram_word_addr_o;
    logic  t_vram_rsp_valid_i;
    logic  t_vram_rsp_ready_o;
    logic [15:0] t_vram_rsp_data_i;
    logic  l_tile_map_req_o;
    logic  l_tile_map_ready_i;
    logic  l_tile_map_bank_o;
    logic [14:0] l_tile_map_addr_o;
    logic  l_tile_map_rsp_valid_i;
    logic  l_tile_map_rsp_ready_o;
    logic [15:0] l_tile_map_rsp_data_i;
    logic  l_scan_req_i;
    logic  l_scan_ready_o;
    logic  l_scan_bank_i;
    logic [8:0] l_scan_y_i;
    logic [8:0] l_scan_x_i;
    logic  l_scan_rsp_valid_o;
    logic  l_scan_rsp_ready_i;
    logic  l_scan_rsp_reject_o;
    logic  l_scan_rsp_bank_o;
    logic [8:0] l_scan_rsp_y_o;
    logic [8:0] l_scan_rsp_x_o;
    logic [12:0] l_scan_rsp_palette_o;
    logic  l_scan_rsp_shadow_o;
    logic  line_fault;
    logic  pixel_fault;
    bigfight_video_producer u_producer (
        .clk_sys(clk_sys),
        .cold_reset(cold_reset),
        .frame_prepare_valid_i(frame_prepare_valid_i),
        .frame_prepare_ready_o(frame_prepare_ready_o),
        .frame_id_i(frame_id_i),
        .sprite_control_e0_i(sprite_control_e0_i),
        .line_bank_valid_i(line_bank_valid_o),
        .tile_bank_live_i(tile_bank_live_i),
        .mixing_control_live_i(mixing_control_live_i),
        .snapshot_req_o(p_snapshot_req_o),
        .snapshot_control_e0_o(p_snapshot_control_e0_o),
`ifdef BIGFIGHT_EMPTY_E0
        .snapshot_epoch_o(p_snapshot_epoch_o),
`endif
        .snapshot_ready_i(p_snapshot_ready_i),
        .tables_req_o(p_tables_req_o),
        .tables_req_y_o(p_tables_req_y_o),
        .tables_req_ready_i(p_tables_req_ready_i),
        .tables_rsp_valid_i(p_tables_rsp_valid_i),
        .tables_rsp_ready_o(p_tables_rsp_ready_o),
        .tables_rsp_y_i(p_tables_rsp_y_i),
        .tables_scrollx0_i(p_tables_scrollx0_i),
        .tables_scrollx_line_i(p_tables_scrollx_line_i),
        .tables_scrolly0_i(p_tables_scrolly0_i),
        .tables_scrolly_line_i(p_tables_scrolly_line_i),
        .tables_page_select_i(p_tables_page_select_i),
        .line_req_o(p_line_req_o),
        .line_ready_i(p_line_ready_i),
        .line_y_o(p_line_y_o),
        .line_scrollx0_o(p_line_scrollx0_o),
        .line_scrollx_line_o(p_line_scrollx_line_o),
        .line_scrolly0_o(p_line_scrolly0_o),
        .line_scrolly_line_o(p_line_scrolly_line_o),
        .line_page_select_o(p_line_page_select_o),
        .line_tile_bank_o(p_line_tile_bank_o),
        .line_mixing_control_o(p_line_mixing_control_o),
        .line_done_valid_i(p_line_done_valid_i),
        .line_done_ready_o(p_line_done_ready_o),
        .line_done_bank_i(p_line_done_bank_i),
        .line_done_y_i(p_line_done_y_i),
        .line_done_late_i(p_line_done_late_i),
        .line_done_cycles_i(p_line_done_cycles_i),
        .line_done_valid_o(line_done_valid_o),
        .line_done_ready_i(line_done_ready_i),
        .line_done_frame_id_o(line_done_frame_id_o),
        .line_done_bank_o(line_done_bank_o),
        .line_done_y_o(line_done_y_o),
        .line_done_late_o(line_done_late_o),
        .line_done_cycles_o(line_done_cycles_o),
        .frame_done_valid_o(frame_done_valid_o),
        .frame_done_ready_i(frame_done_ready_i),
        .frame_done_id_o(frame_done_id_o),
        .protocol_fault_o(p_protocol_fault_o)
    );

    bigfight_video_tables u_tables (
        .clk_sys(clk_sys),
        .cold_reset(cold_reset),
        .req_i(p_tables_req_o),
        .req_y_i(p_tables_req_y_o),
        .req_ready_o(p_tables_req_ready_i),
        .rsp_valid_o(p_tables_rsp_valid_i),
        .rsp_ready_i(p_tables_rsp_ready_o),
        .rsp_y_o(p_tables_rsp_y_i),
        .scrollx0_o(p_tables_scrollx0_i),
        .scrollx_line_o(p_tables_scrollx_line_i),
        .scrolly0_o(p_tables_scrolly0_i),
        .scrolly_line_o(p_tables_scrolly_line_i),
        .page_select_o(p_tables_page_select_i),
        .vram_req_o(t_vram_req_o),
        .vram_ready_i(t_vram_ready_i),
        .vram_bank_o(t_vram_bank_o),
        .vram_word_addr_o(t_vram_word_addr_o),
        .vram_rsp_valid_i(t_vram_rsp_valid_i),
        .vram_rsp_ready_o(t_vram_rsp_ready_o),
        .vram_rsp_data_i(t_vram_rsp_data_i)
    );

    bigfight_video_line u_line (.cyclwarr_i(cyclwarr_i), 
        .clk_sys(clk_sys),
        .cold_reset(cold_reset),
        .snapshot_req_i(p_snapshot_req_o),
        .snapshot_ready_o(p_snapshot_ready_i),
        .sprite_control_e0_i(p_snapshot_control_e0_o),
        .spram_req_o(spram_req_o),
        .spram_ready_i(spram_ready_i),
        .spram_word_addr_o(spram_word_addr_o),
        .spram_valid_i(spram_valid_i),
        .spram_data_i(spram_data_i),
        .line_req_i(p_line_req_o),
        .line_ready_o(p_line_ready_i),
        .line_y_i(p_line_y_o),
        .scrollx0_i(p_line_scrollx0_o),
        .scrollx_line_i(p_line_scrollx_line_o),
        .scrolly0_i(p_line_scrolly0_o),
        .scrolly_line_i(p_line_scrolly_line_o),
        .page_select_i(p_line_page_select_o),
        .tile_bank_i(p_line_tile_bank_o),
        .mixing_control_i(p_line_mixing_control_o),
        .tile_map_req_o(l_tile_map_req_o),
        .tile_map_ready_i(l_tile_map_ready_i),
        .tile_map_bank_o(l_tile_map_bank_o),
        .tile_map_addr_o(l_tile_map_addr_o),
        .tile_map_rsp_valid_i(l_tile_map_rsp_valid_i),
        .tile_map_rsp_ready_o(l_tile_map_rsp_ready_o),
        .tile_map_rsp_data_i(l_tile_map_rsp_data_i),
        .tile_gfx_req_o(tile_gfx_req_o),
        .tile_gfx_ready_i(tile_gfx_ready_i),
        .tile_gfx_row_addr_o(tile_gfx_row_addr_o),
        .tile_gfx_rsp_valid_i(tile_gfx_rsp_valid_i),
        .tile_gfx_rsp_ready_o(tile_gfx_rsp_ready_o),
        .tile_gfx_rsp_data_i(tile_gfx_rsp_data_i),
        .tile_clut_req_o(tile_clut_req_o),
        .tile_clut_ready_i(tile_clut_ready_i),
        .tile_clut_row_addr_o(tile_clut_row_addr_o),
        .tile_clut_rsp_valid_i(tile_clut_rsp_valid_i),
        .tile_clut_rsp_ready_o(tile_clut_rsp_ready_o),
        .tile_clut_rsp_data_i(tile_clut_rsp_data_i),
        .sprite_rom_req_o(sprite_rom_req_o),
        .sprite_rom_ready_i(sprite_rom_ready_i),
        .sprite_rom_bank_o(sprite_rom_bank_o),
        .sprite_rom_byte_addr_o(sprite_rom_byte_addr_o),
        .sprite_rom_valid_i(sprite_rom_valid_i),
        .sprite_rom_data_i(sprite_rom_data_i),
        .sprite_clut_req_o(sprite_clut_req_o),
        .sprite_clut_ready_i(sprite_clut_ready_i),
        .sprite_clut_color_o(sprite_clut_color_o),
        .sprite_clut_valid_i(sprite_clut_valid_i),
        .sprite_clut_bytes_i(sprite_clut_bytes_i),
        .line_done_valid_o(p_line_done_valid_i),
        .line_done_ready_i(p_line_done_ready_o),
        .line_done_bank_o(p_line_done_bank_i),
        .line_done_y_o(p_line_done_y_i),
        .line_done_late_o(p_line_done_late_i),
        .line_done_cycles_o(p_line_done_cycles_i),
        .line_done_collect_cycles_o(line_done_collect_cycles_o),
        .line_bank_valid_o(line_bank_valid_o),
        .line_bank_y0_o(line_bank_y0_o),
        .line_bank_y1_o(line_bank_y1_o),
        .line_bank_late_o(line_bank_late_o),
        .line_release_valid_i(line_release_valid_i),
        .line_release_ready_o(line_release_ready_o),
        .line_release_bank_i(line_release_bank_i),
        .scan_req_i(l_scan_req_i),
        .scan_ready_o(l_scan_ready_o),
        .scan_bank_i(l_scan_bank_i),
        .scan_y_i(l_scan_y_i),
        .scan_x_i(l_scan_x_i),
        .scan_rsp_valid_o(l_scan_rsp_valid_o),
        .scan_rsp_ready_i(l_scan_rsp_ready_i),
        .scan_rsp_reject_o(l_scan_rsp_reject_o),
        .scan_rsp_bank_o(l_scan_rsp_bank_o),
        .scan_rsp_y_o(l_scan_rsp_y_o),
        .scan_rsp_x_o(l_scan_rsp_x_o),
        .scan_rsp_palette_o(l_scan_rsp_palette_o),
        .scan_rsp_shadow_o(l_scan_rsp_shadow_o),
        .deadline_miss_o(deadline_miss_o),
        .protocol_fault_o(line_fault)
    );

    bigfight_video_pixel_fetch u_pixel (
        .clk_sys(clk_sys),
        .cold_reset(cold_reset),
        .req_valid_i(pixel_req_valid_i),
        .req_ready_o(pixel_req_ready_o),
        .req_bank_i(pixel_req_bank_i),
        .req_y_i(pixel_req_y_i),
        .req_x_i(pixel_req_x_i),
        .rsp_valid_o(pixel_rsp_valid_o),
        .rsp_ready_i(pixel_rsp_ready_i),
        .rsp_bank_o(pixel_rsp_bank_o),
        .rsp_y_o(pixel_rsp_y_o),
        .rsp_x_o(pixel_rsp_x_o),
        .rsp_rgb_o(pixel_rsp_rgb_o),
        .rsp_reject_o(pixel_rsp_reject_o),
        .rsp_latency_o(pixel_rsp_latency_o),
        .protocol_fault_o(pixel_fault),
        .scan_req_o(l_scan_req_i),
        .scan_ready_i(l_scan_ready_o),
        .scan_bank_o(l_scan_bank_i),
        .scan_y_o(l_scan_y_i),
        .scan_x_o(l_scan_x_i),
        .scan_rsp_valid_i(l_scan_rsp_valid_o),
        .scan_rsp_ready_o(l_scan_rsp_ready_i),
        .scan_rsp_bank_i(l_scan_rsp_bank_o),
        .scan_rsp_y_i(l_scan_rsp_y_o),
        .scan_rsp_x_i(l_scan_rsp_x_o),
        .scan_rsp_palette_i(l_scan_rsp_palette_o),
        .scan_rsp_shadow_i(l_scan_rsp_shadow_o),
        .scan_rsp_reject_i(l_scan_rsp_reject_o),
        .palette_req_o(palette_req_o),
        .palette_ready_i(palette_ready_i),
        .palette_addr_o(palette_addr_o),
        .palette_rsp_valid_i(palette_rsp_valid_i),
        .palette_rsp_ready_o(palette_rsp_ready_o),
        .palette_rsp_data_i(palette_rsp_data_i)
    );

    bigfight_video_vram_arb u_vram_arb (
        .clk_sys(clk_sys),
        .cold_reset(cold_reset),
        .c0_req_valid_i(t_vram_req_o),
        .c0_req_ready_o(t_vram_ready_i),
        .c0_req_bank_i(t_vram_bank_o),
        .c0_req_word_address_i(t_vram_word_addr_o),
        .c0_rsp_valid_o(t_vram_rsp_valid_i),
        .c0_rsp_ready_i(t_vram_rsp_ready_o),
        .c0_rsp_data_o(t_vram_rsp_data_i),
        .c1_req_valid_i(l_tile_map_req_o),
        .c1_req_ready_o(l_tile_map_ready_i),
        .c1_req_bank_i(l_tile_map_bank_o),
        .c1_req_word_address_i(l_tile_map_addr_o),
        .c1_rsp_valid_o(l_tile_map_rsp_valid_i),
        .c1_rsp_ready_i(l_tile_map_rsp_ready_o),
        .c1_rsp_data_o(l_tile_map_rsp_data_i),
        .mem_req_valid_o(vram_req_valid_o),
        .mem_req_ready_i(vram_req_ready_i),
        .mem_req_bank_o(vram_req_bank_o),
        .mem_req_word_address_o(vram_req_word_address_o),
        .mem_rsp_valid_i(vram_rsp_valid_i),
        .mem_rsp_ready_o(vram_rsp_ready_o),
        .mem_rsp_data_i(vram_rsp_data_i)
    );
`ifdef BIGFIGHT_EMPTY_E0
    bigfight_empty_snapshot_proof u_empty_proof (
        .clk(clk_sys),.reset(cold_reset),.invalidate_epoch_i(empty_invalidate_i),
        .frame_epoch_i(p_snapshot_epoch_o),
        .snapshot_accept_i(p_snapshot_req_o && p_snapshot_ready_i),
        .snapshot_epoch_i(p_snapshot_epoch_o),.snapshot_control_i(p_snapshot_control_e0_o),
        .snapshot_rsp_accept_i(spram_valid_i && spram_rsp_ready_o),.snapshot_rsp_data_i(spram_data_i),
        .head_write_accept_i(empty_head_accept_i),.head_write_bank_i(empty_head_bank_i),
        .head_write_data_i(empty_head_data_i),.head_write_uds_n_i(empty_head_uds_n_i),
        .head_write_lds_n_i(empty_head_lds_n_i),.live_control_i(empty_live_control_i),
        .candidate_control_i(empty_candidate_control_i),.safe_bank_only_change_o(empty_safe_o),
        .protocol_fault_o(empty_protocol_fault_o),.diverged_population_fault_o(empty_population_fault_o)
    );
`ifdef VERILATOR
    // Once copied, the sprite snapshot owns its data until the next capture.
    // CPU writes to the source RAM cannot mutate that committed cache.
    logic witnessed_snapshot_q;
    logic [15:0] witnessed_head_q;
    logic witnessed_bank_q;
    always_ff @(posedge clk_sys) begin
        if(cold_reset || (p_snapshot_req_o && p_snapshot_ready_i) ||
           !u_line.snapshot_complete_q || !u_line.u_sprite.snapshot_valid_q)
            witnessed_snapshot_q <= 0;
        else begin
            if(witnessed_snapshot_q) begin
                assert(u_line.u_sprite.shadow_w4[0] === witnessed_head_q)
                    else $fatal(1,"committed sprite cache head changed without new capture");
                assert(u_line.u_sprite.snapshot_bank_q === witnessed_bank_q)
                    else $fatal(1,"committed sprite cache bank changed without new capture");
            end
            witnessed_snapshot_q <= 1;
            witnessed_head_q <= u_line.u_sprite.shadow_w4[0];
            witnessed_bank_q <= u_line.u_sprite.snapshot_bank_q;
        end
    end
    // Independent assertion against the actual parser cache, not tracked live heads.
    always_ff @(posedge clk_sys) if(!cold_reset && (empty_safe_o === 1'b1)) begin
        assert(u_line.snapshot_complete_q === 1'b1) else $fatal(1,"empty proof before line cache complete");
        assert(u_line.u_sprite.snapshot_valid_q === 1'b1) else $fatal(1,"empty proof before sprite cache valid");
        assert(u_line.u_sprite.shadow_w4[0] === 16'hffff) else $fatal(1,"empty proof contradicts actual cached scale");
        assert(u_line.u_sprite.snapshot_bank_q === p_snapshot_control_e0_o[12]) else $fatal(1,"empty proof cache/control bank mismatch");
    end
`endif
`endif
    // Sprite snapshot consumes its one outstanding RAM reply immediately.
    assign spram_rsp_ready_o = !cold_reset;
`ifdef BIGFIGHT_EMPTY_E0
    // Population divergence is retained as a raw legacy diagnostic. The
    // committed cache is isolated from later CPU RAM writes and E0 changes.
    assign protocol_fault_o = p_protocol_fault_o | line_fault | pixel_fault | empty_protocol_fault_o;
`else
    assign protocol_fault_o = p_protocol_fault_o | line_fault | pixel_fault;
`endif
endmodule
