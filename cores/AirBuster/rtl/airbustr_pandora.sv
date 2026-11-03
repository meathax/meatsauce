// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from kuzearcade Arcade-SandScrp_MiSTer pandora.sv at
// d3ca399ce4cc20c68b70a4b6bbfb0e01b1fa5ac0 (GPL-3.0).
// DJ Boy 9c6299b1949da85c90171fc01b31a97ab5b9c37c is the
// 8-bit/address/page comparison. CPU permutation belongs to airbustr_memory.
// This module owns only the coherent snapshot and two 256x256 sprite planes.
// Snapshot stalls object RAM writes; scanout never reads the page being drawn.
// External aligned64-bit bursts fetch two adjacent rows of one8x8 quadrant.
module airbustr_pandora #(
    parameter bit SWAP_AT_VIS_START = 1'b1
) (
    input logic clk, reset, eof, vis_start,
    input logic clear_bitmap, flip_screen,
    output logic [8:0] object_addr,
    input logic [63:0] object_data,
    output logic cpu_hold,
    output logic rom_req_valid,
    input logic rom_req_ready,
    output logic [20:0] rom_req_addr,
    input logic rom_rsp_valid,rom_rsp_last,
    input logic [63:0] rom_rsp_data,
    input logic [7:0] rd_x, rd_y,
    output logic [7:0] rd_pix,
    output logic busy, completed, display_page,
    output logic [31:0] pass_cycles,
    output logic [15:0] late_swaps,
    output logic [9:0] objects_done
);
    typedef enum logic [3:0] {IDLE,COPY,CLRP,H0,H1,H2,EVAL,LREQ,LWAIT,RREQ,RWAIT,DRAW,FINISH,PAGEWAIT,PAIR} state_t;
    state_t state;
    // Entry words 0 (bytes 3..0) and 1 (bytes 7..4). The EOF copy takes one
    // whole 8-byte entry per clock (512 clocks), so the CPU object-RAM hold
    // that keeps the snapshot coherent lasts ~10.7 us instead of ~85 us.
    logic [31:0] snapshot_lo [0:511];
    logic [31:0] snapshot_hi [0:511];
    logic [31:0] snapshot_lo_q, snapshot_hi_q;
    logic header_sel_q;
    // Eight independent byte lanes retain two complete 256x256 pages.
    // Clearing all lanes together takes8192 clocks without changing scan latency.
    // Independent RAM banks: no dynamic unpacked RAM bank selection.
    logic [13:0] plane_wr_addr [0:7];
    logic [13:0] plane_rd_addr;
    logic [7:0] plane_wr_data [0:7];
    logic [7:0] plane_wr_en;
    logic [7:0] lane_q [0:7];
    logic [2:0] lane_select_q;
    logic plane_visible_q;
    assign plane_rd_addr = {read_page,rd_y,rd_x[7:3]};

    genvar lane;
    generate
    for(lane=0;lane<8;lane=lane+1) begin : plane_bank
        // PRIVATE: one pixel per constant lane, independent write addresses.
        localparam [2:0] LANE_ID = lane;
        wire [2:0] lane_offset = LANE_ID - plot_x[2:0];
        wire [3:0] lane_draw_x = px + {1'b0,lane_offset};
        wire [3:0] lane_source_x = fx ? ~lane_draw_x : lane_draw_x;
        wire signed [10:0] lane_plot_x = plot_x + $signed({8'b0,lane_offset});
        wire lane_plot_on = lane_plot_x >= 0 && lane_plot_x < 256 &&
                            plot_y >= 0 && plot_y < 256;
        wire [3:0] lane_pen;
        wire [20:0] lane_decode_address;
        airbustr_gfx_decode lane_decode(.code,.x(lane_source_x),.y(source_y),
            .data(lane_source_x[3] ? right_pair : left_pair),
            .address(lane_decode_address),.pen(lane_pen));
        assign plane_wr_addr[lane] = state == CLRP ? {draw_page,clear_addr[15:3]} :
                                    {draw_page,plot_y[7:0],lane_plot_x[7:3]};
        assign plane_wr_data[lane] = state == CLRP ? 8'b0 : {bank,lane_pen};
        assign plane_wr_en[lane] = state == CLRP ? clear_bitmap :
                                  state == DRAW && lane_plot_on && lane_pen != 0;
        (* ramstyle = "M10K" *) logic [7:0] memory [0:16383];
        always_ff @(posedge clk) begin
            if(plane_wr_en[lane]) memory[plane_wr_addr[lane]] <= plane_wr_data[lane];
            lane_q[lane] <= memory[plane_rd_addr];
        end
    end
    endgenerate
    always_ff @(posedge clk) begin
        lane_select_q <= rd_x[2:0];
        plane_visible_q <= display_valid || swap_ready;
    end
    // The registered lane selector and each bank Q refer to the same edge.
    // This mux is after the RAM output registers: external latency remains1.
    assign rd_pix = plane_visible_q ? lane_q[lane_select_q] : 8'b0;
    logic [12:0] copy_issue, copy_capture;
    logic copy_valid;
    logic [9:0] header_addr;
    logic [31:0] header_q, w0, w1;
    logic [15:0] clear_addr;
    logic draw_page, pass_done, pending_eof;
    logic [8:0] slot;
    logic [8:0] acc_x, acc_y;
    logic signed [9:0] sx, sy;
    logic [13:0] code;
    logic [3:0] bank, px, py;
    logic fx, fy;
    logic [63:0] left_pair, right_pair;
    (* ramstyle="M10K" *) logic [63:0] tile_words [0:15];
    logic [63:0] tile_q;logic [3:0] fetch_index,tile_read_addr;
    assign tile_read_addr={source_y[3],state!=RREQ,source_y[2:1]};
    always_ff @(posedge clk)tile_q<=tile_words[tile_read_addr];
    logic [31:0] cycles;
    logic [8:0] new_x,new_y;
    logic [3:0] source_x,source_y,pen;
    logic [20:0] decode_address;
    logic signed [10:0] plot_x,plot_y;
    logic tile_off,plot_on;
    logic [13:0] empty_tag [0:15];
    logic [15:0] empty_valid;
    logic tile_nonzero,last_signature_valid,display_valid,swap_ready;
    logic [37:0] candidate_signature,last_signature;
    logic known_empty,duplicate_object;
    logic read_page;
    assign candidate_signature = {w1[29:24],w1[23:16],w0[31:28],w1[31:30],new_x,new_y};
    assign known_empty = empty_valid[w1[19:16]] && empty_tag[w1[19:16]] == {w1[29:24],w1[23:16]};
    assign duplicate_object = last_signature_valid && candidate_signature == last_signature;
    assign swap_ready = (SWAP_AT_VIS_START ? vis_start : eof) && pass_done;
    assign read_page = swap_ready ? draw_page : display_page;
    assign new_x = w0[26] ? acc_x + {w0[24],w1[7:0]} : {w0[24],w1[7:0]};
    assign new_y = w0[26] ? acc_y + {w0[25],w1[15:8]} : {w0[25],w1[15:8]};
    wire [8:0] flip_x = flip_screen ? 9'd240 - new_x : new_x;
    wire [8:0] flip_y = flip_screen ? 9'd240 - new_y : new_y;
    // Modulo512 addition preserves final signed9-bit coordinates even through
    // arbitrarily long relative chains; high discarded bits cannot affect them.
    assign source_x = fx ? ~px : px;
    assign source_y = fy ? ~py : py;
    airbustr_gfx_decode decode(.code,.x(source_x),.y(source_y),
        .data(source_x[3] ? right_pair : left_pair),.address(decode_address),.pen);
    assign rom_req_addr = {code,7'b0};
    assign rom_req_valid = state == LREQ && !tile_off;
    assign object_addr = copy_issue[8:0];
    assign header_q = header_sel_q ? snapshot_hi_q : snapshot_lo_q;
    always_ff @(posedge clk) begin
        snapshot_lo_q <= snapshot_lo[header_addr[9:1]];
        snapshot_hi_q <= snapshot_hi[header_addr[9:1]];
        header_sel_q <= header_addr[0];
        if(state == COPY && copy_valid) begin
            snapshot_lo[copy_capture[8:0]] <= object_data[31:0];
            snapshot_hi[copy_capture[8:0]] <= object_data[63:32];
        end
    end
    assign cpu_hold = state == COPY;
    assign busy = state != IDLE;
    assign plot_x = {sx[9],sx} + $signed({7'b0,px});
    assign plot_y = {sy[9],sy} + $signed({7'b0,py});
    assign plot_on = plot_x >= 0 && plot_x < 256 && plot_y >= 0 && plot_y < 256;
    assign tile_off = sx > 255 || sx < -15 || sy > 255 || sy < -15;
    always_ff @(posedge clk) begin
        completed <= 1'b0;
        if(reset) begin
            state <= IDLE; display_page <= 0; draw_page <= 1;
            pass_done <= 0; pending_eof <= 0; late_swaps <= 0;
            pass_cycles <= 0; cycles <= 0; copy_issue <= 0; objects_done <= 0;
            empty_valid <= 0; last_signature_valid <= 0; display_valid <= 0;
        end else begin
            if(busy) cycles <= cycles + 32'd1;
            if(eof && busy) begin pending_eof <= 1; late_swaps <= late_swaps + 16'd1; end
            if(SWAP_AT_VIS_START && vis_start && busy && !pass_done) late_swaps <= late_swaps + 16'd1;
            if(swap_ready) begin
                display_page <= draw_page; pass_done <= 0; display_valid <= 1;
            end
            case(state)
                IDLE: if(eof || pending_eof) begin
                    // Snapshot is tied to EOF even when a completed page is
                    // waiting for its display boundary. Page writes wait later.
                    if(swap_ready) draw_page <= display_page;
                    else if(!pass_done) draw_page <= ~display_page;
                    pending_eof <= 0; copy_issue <= 0; copy_capture <= 0;
                    copy_valid <= 0; cycles <= 0; objects_done <= 0; state <= COPY;
                end
                COPY: begin
                    // External RAM has a registered read. Issue one address/cycle;
                    // copy_valid absorbs the initial latency, capture trails issue.
                    if(copy_issue < 512) copy_issue <= copy_issue + 13'd1;
                    copy_valid <= 1;
                    if(copy_valid) begin
                        copy_capture <= copy_capture + 13'd1;
                        if(copy_capture == 511) begin
                            clear_addr <= 0;
                            if(pass_done && !swap_ready) state <= PAGEWAIT;
                            else begin draw_page <= swap_ready ? ~draw_page : ~display_page; state <= CLRP; end
                        end
                    end
                end
                PAGEWAIT: if(!pass_done) begin draw_page <= ~display_page; clear_addr <= 0; state <= CLRP; end
                CLRP: begin
                    if(clear_addr == 65528 || !clear_bitmap) begin
                        slot <= 0; acc_x <= 0; acc_y <= 0; header_addr <= 0; last_signature_valid <= 0; state <= H0;
                    end else clear_addr <= clear_addr + 16'd8;
                end
                H0: begin header_addr <= {slot,1'b1}; state <= H1; end
                H1: begin w0 <= header_q; state <= H2; end
                H2: begin w1 <= header_q; state <= EVAL; end
                EVAL: begin
                    acc_x <= new_x; acc_y <= new_y;
                    // kan_pand.cpp draw(): flip is applied after the chain sum.
                    sx <= {flip_x[8],flip_x}; sy <= {flip_y[8],flip_y};
                    code <= {w1[29:24],w1[23:16]}; bank <= w0[31:28];
                    fx <= w1[31] ^ flip_screen; fy <= w1[30] ^ flip_screen; px <= 0; py <= 0; state <= LREQ;
                    tile_nonzero <= 0;fetch_index<=0; last_signature <= candidate_signature; last_signature_valid <= 1;
                    // Adjacent identical objects are idempotent, including
                    // overlap/transparent pixels; all relative coordinates
                    // above still advance. Empty tags are learned from all128
                    // actual ROM bytes, never assumed from a tile-code value.
                    if(known_empty || duplicate_object) begin
                        objects_done <= objects_done + 10'd1;
                        if(slot == 511) state <= FINISH;
                        else begin slot <= slot + 9'd1; header_addr <= {slot + 9'd1,1'b0}; state <= H0; end
                    end
                end
                LREQ: if(tile_off) begin
                    objects_done <= objects_done + 10'd1;
                    if(slot == 511) state <= FINISH;
                    else begin slot <= slot + 9'd1; header_addr <= {slot + 9'd1,1'b0}; state <= H0; end
                end else if(rom_req_ready) state <= LWAIT;
                LWAIT: if(rom_rsp_valid) begin
                    tile_words[fetch_index]<=rom_rsp_data;fetch_index<=fetch_index+4'd1;
                    tile_nonzero<=tile_nonzero || rom_rsp_data!=0;
                    if(rom_rsp_last)state<=RREQ;
                end
                RREQ: state<=RWAIT;
                RWAIT: begin left_pair<=tile_q;state<=PAIR;end
                PAIR: begin right_pair<=tile_q;state<=DRAW;end
                DRAW: begin
                    if(left_pair == 0 && right_pair == 0 && !py[0]) begin
                        // The pair contains both source rows, so skipping two
                        // transparent output rows preserves full-plane state.
                        py <= py + 4'd2;
                        if(py == 14) begin
                            if(!tile_nonzero) begin empty_tag[code[3:0]] <= code; empty_valid[code[3:0]] <= 1; end
                            objects_done <= objects_done + 10'd1;
                            if(slot == 511) state <= FINISH;
                            else begin slot <= slot + 9'd1; header_addr <= {slot + 9'd1,1'b0}; state <= H0; end
                        end else state <= RREQ;
                    end else begin
                    px <= px + 4'd8;
                    if(px == 8) begin
                        py <= py + 4'd1;
                        if(py == 15) begin
                            objects_done <= objects_done + 10'd1;
                            if(slot == 511) state <= FINISH;
                            else begin slot <= slot + 9'd1; header_addr <= {slot + 9'd1,1'b0}; state <= H0; end
                        end else if(py[0]) state <= RREQ; // two rows per burst pair
                    end
                    end
                end
                FINISH: begin pass_done <= 1; completed <= 1; pass_cycles <= cycles; state <= IDLE; end
                default: state <= IDLE;
            endcase
        end
    end
endmodule
