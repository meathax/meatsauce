// Big Fight four-layer scanline prefetcher.
// Coordinates and tile decode follow MAME 0.289 cyclwarr_state::draw_bg.
// The backend has independent ready/valid map, packed-plane-row, and CLUT-row
// ports. One map request is outstanding; one decoded tile span is rendered at
// a time while the map walker fills a small descriptor FIFO.
module bigfight_tile_scanline #(parameter QUAD_COLLECT=0) (
    input wire cyclwarr_i,
    input  logic         clk,
    input  logic         cold_reset,

    input  logic         line_req,
    output logic         line_ready,
    input  logic [8:0]   line_y_i,
    input  logic [63:0]  scrollx0_i,
    input  logic [63:0]  scrollx_line_i,
    input  logic [63:0]  scrolly0_i,
    input  logic [63:0]  scrolly_line_i,
    input  logic [63:0]  page_select_i,
    input  logic [15:0]  tile_bank_i,

    output logic         map_req,
    input  logic         map_ready,
    output logic         map_bank,
    output logic [14:0]  map_addr,
    input  logic         map_rsp_valid,
    output logic         map_rsp_ready,
    input  logic [15:0]  map_rsp_data,

    output logic         gfx_req,
    input  logic         gfx_ready,
    output logic [16:0]  gfx_row_addr,
    input  logic         gfx_rsp_valid,
    output logic         gfx_rsp_ready,
    input  logic [23:0]  gfx_rsp_data,

    output logic         clut_req,
    input  logic         clut_ready,
    output logic [16:0]  clut_row_addr,
    input  logic         clut_rsp_valid,
    output logic         clut_rsp_ready,
    input  logic [63:0]  clut_rsp_data,

    output logic         line_done_valid,
    input  logic         line_done_ready,
    output logic         line_done_bank,
    output logic [8:0]   line_done_y,
    input  logic         line_release_valid,
    input  logic         line_release_bank,

    input  logic         scan_req,
    output logic         scan_ready,
    input  logic         scan_bank,
    input  logic [8:0]   scan_y,
    input  logic [8:0]   scan_x,
    output logic         scan_rsp_valid,
    input  logic         scan_rsp_ready,
    output logic         scan_rsp_bank,
    output logic [8:0]   scan_rsp_y,
    output logic [8:0]   scan_rsp_x,
    output logic [51:0]  scan_pixels,
    output wire [207:0] scan_quad_pixels,

    input  logic         deadline_check,
    input  logic [8:0]   deadline_y,
    output logic         deadline_miss
);
    localparam integer FIFO_DEPTH = 4;
    localparam integer PTR_W = 2;

    typedef enum logic [1:0] {W_IDLE, W_MAP_REQ, W_MAP_WAIT} walk_state_t;
    typedef enum logic [1:0] {D_IDLE, D_FETCH, D_WRITE} draw_state_t;
    walk_state_t walk_state;
    draw_state_t draw_state;

    logic render_active;
    logic active_bank_q;
    logic [8:0] line_y_q;
    logic [15:0] tile_bank_q;
    logic [63:0] scrollx0_q, scrollx_line_q;
    logic [63:0] scrolly0_q, scrolly_line_q, page_select_q;
    logic [1:0] walk_layer_q;
    logic [8:0] walk_x_q;

    logic [1:0] bank_valid_q;
    logic [8:0] bank_y0_q, bank_y1_q;
    logic free_bank;
    logic free_found;

    logic [1:0] coord_layer;
    logic [8:0] coord_x;
    logic [15:0] coord_scrollx0, coord_scrollx_line;
    logic [15:0] coord_scrolly0, coord_scrolly_line, coord_page;
    wire coord_map_bank;
    wire [14:0] coord_map_addr;
    wire [9:0] coord_world_x;
    wire [10:0] coord_world_y;
    wire [2:0] coord_local_x, coord_local_y;
    logic [9:0] remaining_x;
    logic [3:0] tile_remaining;
    logic [3:0] span_pixels;

    logic [1:0] fifo_layer [0:FIFO_DEPTH-1];
    logic [8:0] fifo_screen_x [0:FIFO_DEPTH-1];
    logic [2:0] fifo_local_x [0:FIFO_DEPTH-1];
    logic [2:0] fifo_local_y [0:FIFO_DEPTH-1];
    logic [3:0] fifo_pixels [0:FIFO_DEPTH-1];
    logic [13:0] fifo_tile_code [0:FIFO_DEPTH-1];
    logic [2:0] fifo_color [0:FIFO_DEPTH-1];
    logic fifo_force [0:FIFO_DEPTH-1];
    logic fifo_category [0:FIFO_DEPTH-1];
    logic [PTR_W-1:0] fifo_wr_ptr_q, fifo_rd_ptr_q;
    logic [PTR_W:0] fifo_count_q;
    wire fifo_push;
    wire fifo_pop;

    logic [1:0] draw_layer_q;
    logic [8:0] draw_screen_x_q;
    logic [2:0] draw_local_x_q, draw_local_y_q;
    logic [3:0] draw_pixels_q;
    logic [13:0] draw_tile_code_q;
    logic [2:0] draw_color_q;
    logic draw_force_q, draw_category_q;
    logic fetch_active_q;
    logic [1:0] fetch_layer_q;
    logic [8:0] fetch_screen_x_q;
    logic [2:0] fetch_local_x_q,fetch_local_y_q;
    logic [3:0] fetch_pixels_q;
    logic [13:0] fetch_tile_code_q;
    logic [2:0] fetch_color_q;
    logic fetch_force_q,fetch_category_q;
    logic [23:0] fetch_gfx_row_q;
    logic [63:0] fetch_clut_row_q;
    logic gfx_req_sent_q, clut_req_sent_q;
    logic gfx_have_q, clut_have_q;
    logic [23:0] gfx_row_q;
    logic [63:0] clut_row_q;
    logic [3:0] draw_pixel_index_q;

    wire gfx_rsp_take = gfx_rsp_valid && gfx_rsp_ready;
    wire clut_rsp_take = clut_rsp_valid && clut_rsp_ready;
    wire scan_accept = scan_req && scan_ready;
    wire pixel_write = (draw_state == D_WRITE);

    logic [8:0] ram_wr_addr;
    logic [12:0] ram_wr_data;
    wire [12:0] ram_q [0:7];
    logic scan_rsp_bank_q;
    logic [8:0] scan_rsp_y_q, scan_rsp_x_q;

    assign free_found = !bank_valid_q[0] || !bank_valid_q[1];
    assign free_bank = bank_valid_q[0];
    assign line_ready = !render_active && !line_done_valid && free_found;

    always @* begin
        coord_layer = walk_layer_q;
        coord_x = walk_x_q;
        coord_scrollx0 = scrollx0_q[walk_layer_q*16 +: 16];
        coord_scrollx_line = scrollx_line_q[walk_layer_q*16 +: 16];
        coord_scrolly0 = scrolly0_q[walk_layer_q*16 +: 16];
        coord_scrolly_line = scrolly_line_q[walk_layer_q*16 +: 16];
        coord_page = page_select_q[walk_layer_q*16 +: 16];
        remaining_x = 10'd320 - {1'b0, walk_x_q};
        tile_remaining = 4'd8 - {1'b0, coord_local_x};
        if (remaining_x < {6'b0, tile_remaining})
            span_pixels = remaining_x[3:0];
        else
            span_pixels = tile_remaining;
    end

    logic [1:0] coord_road_bank;
    bigfight_tile_math u_coordinate (
        .cyclwarr_i(cyclwarr_i), .road_bank(coord_road_bank),
        .layer(coord_layer), .pix_x(coord_x), .pix_y(line_y_q),
        .scrollx0_i(coord_scrollx0), .scrollx_line_i(coord_scrollx_line),
        .scrolly0_i(coord_scrolly0), .scrolly_line_i(coord_scrolly_line),
        .page_select_i(coord_page), .map_bank(coord_map_bank),
        .map_addr(coord_map_addr), .world_x(coord_world_x), .world_y(coord_world_y),
        .local_x(coord_local_x), .local_y(coord_local_y)
    );

    assign map_req = (walk_state == W_MAP_REQ);
    assign map_bank = coord_map_bank;
    assign map_addr = coord_map_addr;
    assign map_rsp_ready = (walk_state == W_MAP_WAIT) &&
                           ((fifo_count_q < FIFO_DEPTH) || fifo_pop);
    assign fifo_push = map_rsp_valid && map_rsp_ready;
    assign fifo_pop = !fetch_active_q && (fifo_count_q != 0);

    assign gfx_req = fetch_active_q && !gfx_req_sent_q;
    assign gfx_row_addr = {fetch_tile_code_q, fetch_local_y_q};
    assign gfx_rsp_ready = fetch_active_q && gfx_req_sent_q && !gfx_have_q;
    assign clut_req = fetch_active_q && !clut_req_sent_q;
    assign clut_row_addr = {fetch_tile_code_q, 3'b000};
    assign clut_rsp_ready = fetch_active_q && clut_req_sent_q && !clut_have_q;

    logic [3:0] pixel_x_in_tile;
    logic [2:0] raw_pen;
    logic [7:0] selected_clut;
    logic [10:0] selected_palette;
    logic selected_opaque;
    always @* begin
        pixel_x_in_tile = {1'b0, draw_local_x_q} + draw_pixel_index_q[2:0];
        raw_pen = {gfx_row_q[23-pixel_x_in_tile],
                   gfx_row_q[15-pixel_x_in_tile],
                   gfx_row_q[7-pixel_x_in_tile]};
        selected_clut = clut_row_q[raw_pen*8 +: 8];
        selected_palette = {draw_color_q, selected_clut};
        selected_opaque = draw_force_q || (raw_pen != 3'd0) ||
                          (selected_clut[2:0] != 3'd0);
        ram_wr_addr = draw_screen_x_q + {5'b0, draw_pixel_index_q};
        ram_wr_data = {selected_opaque, draw_category_q, selected_palette};
    end

    wire [51:0] ram_quad [0:7];
    genvar layer_g, bank_g;
    generate
        for (layer_g = 0; layer_g < 4; layer_g = layer_g + 1) begin : g_layer_ram
            for (bank_g = 0; bank_g < 2; bank_g = bank_g + 1) begin : g_bank_ram
                wire wr_en = pixel_write && (draw_layer_q == layer_g) &&
                             (active_bank_q == bank_g);
                wire rd_en = scan_accept && (scan_bank == bank_g);
                bigfight_tile_line_ram #(.QUAD_COLLECT(QUAD_COLLECT)) u_ram (
                    .clk, .wr_en, .wr_addr(ram_wr_addr), .wr_data(ram_wr_data),
                    .rd_en, .rd_addr(scan_x), .rd_data(ram_q[layer_g*2+bank_g]), .rd_quad(ram_quad[layer_g*2+bank_g])
                );
            end
        end
    endgenerate

    // A held response may be replaced on the edge that consumes it.
    assign scan_ready = (!scan_rsp_valid || scan_rsp_ready) &&
                        (scan_x < 9'd320) &&
                        bank_valid_q[scan_bank] &&
                        ((scan_bank ? bank_y1_q : bank_y0_q) == scan_y);
    assign scan_rsp_bank = scan_rsp_bank_q;
    assign scan_rsp_y = scan_rsp_y_q;
    assign scan_rsp_x = scan_rsp_x_q;
    assign scan_pixels = {ram_q[6 + scan_rsp_bank_q], ram_q[4 + scan_rsp_bank_q],
                          ram_q[2 + scan_rsp_bank_q], ram_q[0 + scan_rsp_bank_q]};

    assign scan_quad_pixels[0+:52]={ram_quad[6+scan_rsp_bank_q][0+:13],ram_quad[4+scan_rsp_bank_q][0+:13],ram_quad[2+scan_rsp_bank_q][0+:13],ram_quad[scan_rsp_bank_q][0+:13]};
    assign scan_quad_pixels[52+:52]={ram_quad[6+scan_rsp_bank_q][13+:13],ram_quad[4+scan_rsp_bank_q][13+:13],ram_quad[2+scan_rsp_bank_q][13+:13],ram_quad[scan_rsp_bank_q][13+:13]};
    assign scan_quad_pixels[104+:52]={ram_quad[6+scan_rsp_bank_q][26+:13],ram_quad[4+scan_rsp_bank_q][26+:13],ram_quad[2+scan_rsp_bank_q][26+:13],ram_quad[scan_rsp_bank_q][26+:13]};
    assign scan_quad_pixels[156+:52]={ram_quad[6+scan_rsp_bank_q][39+:13],ram_quad[4+scan_rsp_bank_q][39+:13],ram_quad[2+scan_rsp_bank_q][39+:13],ram_quad[scan_rsp_bank_q][39+:13]};
    logic complete_now;
    assign complete_now = render_active && (walk_state == W_IDLE) &&
                          (fifo_count_q == 0) && !fetch_active_q && (draw_state == D_IDLE);

    always_ff @(posedge clk) begin
        if (cold_reset) begin
            walk_state <= W_IDLE;
            draw_state <= D_IDLE;
            render_active <= 1'b0;
            active_bank_q <= 1'b0;
            line_y_q <= '0;
            tile_bank_q <= '0;
            scrollx0_q <= '0;
            scrollx_line_q <= '0;
            scrolly0_q <= '0;
            scrolly_line_q <= '0;
            page_select_q <= '0;
            walk_layer_q <= '0;
            walk_x_q <= '0;
            bank_valid_q <= 2'b00;
            bank_y0_q <= '0;
            bank_y1_q <= '0;
            fifo_wr_ptr_q <= '0;
            fifo_rd_ptr_q <= '0;
            fifo_count_q <= '0;
            draw_layer_q <= '0;
            draw_screen_x_q <= '0;
            draw_local_x_q <= '0;
            draw_local_y_q <= '0;
            draw_pixels_q <= '0;
            draw_tile_code_q <= '0;
            draw_color_q <= '0;
            draw_force_q <= 1'b0;
            draw_category_q <= 1'b0;
            fetch_active_q <= 0;
            fetch_layer_q <= 0;fetch_screen_x_q <= 0;
            fetch_local_x_q <= 0;fetch_local_y_q <= 0;fetch_pixels_q <= 0;
            fetch_tile_code_q <= 0;fetch_color_q <= 0;
            fetch_force_q <= 0;fetch_category_q <= 0;
            fetch_gfx_row_q <= 0;fetch_clut_row_q <= 0;
            gfx_req_sent_q <= 1'b0;
            clut_req_sent_q <= 1'b0;
            gfx_have_q <= 1'b0;
            clut_have_q <= 1'b0;
            gfx_row_q <= '0;
            clut_row_q <= '0;
            draw_pixel_index_q <= '0;
            line_done_valid <= 1'b0;
            line_done_bank <= 1'b0;
            line_done_y <= '0;
            scan_rsp_valid <= 1'b0;
            scan_rsp_bank_q <= 1'b0;
            scan_rsp_y_q <= '0;
            scan_rsp_x_q <= '0;
            deadline_miss <= 1'b0;
        end else begin
            if (line_req && line_ready) begin
                render_active <= 1'b1;
                active_bank_q <= free_bank;
                line_y_q <= line_y_i;
                tile_bank_q <= tile_bank_i;
                scrollx0_q <= scrollx0_i;
                scrollx_line_q <= scrollx_line_i;
                scrolly0_q <= scrolly0_i;
                scrolly_line_q <= scrolly_line_i;
                page_select_q <= page_select_i;
                walk_layer_q <= 2'd0;
                walk_x_q <= 9'd0;
                walk_state <= W_MAP_REQ;
            end

            if (walk_state == W_MAP_REQ && map_ready)
                walk_state <= W_MAP_WAIT;

            if (fifo_push) begin
                fifo_layer[fifo_wr_ptr_q] <= walk_layer_q;
                fifo_screen_x[fifo_wr_ptr_q] <= walk_x_q;
                fifo_local_x[fifo_wr_ptr_q] <= coord_local_x;
                fifo_local_y[fifo_wr_ptr_q] <= coord_local_y;
                fifo_pixels[fifo_wr_ptr_q] <= span_pixels;
                fifo_tile_code[fifo_wr_ptr_q] <= {
                    tile_bank_q[{map_rsp_data[11:10], 2'b00} +: 4], map_rsp_data[9:0]};
                fifo_color[fifo_wr_ptr_q] <= {(walk_layer_q != 2'd0), map_rsp_data[13:12] | coord_road_bank};
                fifo_force[fifo_wr_ptr_q] <= map_rsp_data[14];
                fifo_category[fifo_wr_ptr_q] <= map_rsp_data[15];
                fifo_wr_ptr_q <= fifo_wr_ptr_q + 1'b1;

                if ({1'b0, walk_x_q} + {6'b0, span_pixels} >= 10'd320) begin
                    walk_x_q <= 9'd0;
                    if (walk_layer_q == 2'd3)
                        walk_state <= W_IDLE;
                    else begin
                        walk_layer_q <= walk_layer_q + 1'b1;
                        walk_state <= W_MAP_REQ;
                    end
                end else begin
                    walk_x_q <= walk_x_q + span_pixels;
                    walk_state <= W_MAP_REQ;
                end
            end

            if (fifo_pop) begin
                fetch_layer_q <= fifo_layer[fifo_rd_ptr_q];
                fetch_screen_x_q <= fifo_screen_x[fifo_rd_ptr_q];
                fetch_local_x_q <= fifo_local_x[fifo_rd_ptr_q];
                fetch_local_y_q <= fifo_local_y[fifo_rd_ptr_q];
                fetch_pixels_q <= fifo_pixels[fifo_rd_ptr_q];
                fetch_tile_code_q <= fifo_tile_code[fifo_rd_ptr_q];
                fetch_color_q <= fifo_color[fifo_rd_ptr_q];
                fetch_force_q <= fifo_force[fifo_rd_ptr_q];
                fetch_category_q <= fifo_category[fifo_rd_ptr_q];
                gfx_req_sent_q <= 1'b0;
                clut_req_sent_q <= 1'b0;
                gfx_have_q <= 1'b0;
                clut_have_q <= 1'b0;
                fetch_active_q <= 1;
                fifo_rd_ptr_q <= fifo_rd_ptr_q + 1'b1;
            end

            case (fifo_push ? {1'b1, fifo_pop} : {1'b0, fifo_pop})
                2'b10: fifo_count_q <= fifo_count_q + 1'b1;
                2'b01: fifo_count_q <= fifo_count_q - 1'b1;
                default: fifo_count_q <= fifo_count_q;
            endcase

            if (fetch_active_q) begin
                if (gfx_req && gfx_ready)
                    gfx_req_sent_q <= 1'b1;
                if (clut_req && clut_ready)
                    clut_req_sent_q <= 1'b1;
                if (gfx_rsp_take) begin
                    fetch_gfx_row_q <= gfx_rsp_data;
                    gfx_have_q <= 1'b1;
                end
                if (clut_rsp_take) begin
                    fetch_clut_row_q <= clut_rsp_data;
                    clut_have_q <= 1'b1;
                end
            end

            if (draw_state == D_WRITE) begin
                if (draw_pixel_index_q + 1'b1 >= draw_pixels_q) begin
                    draw_state <= D_IDLE;
                    draw_pixel_index_q <= 4'd0;
                end else begin
                    draw_pixel_index_q <= draw_pixel_index_q + 1'b1;
                end
            end

            // A completed fetch can replace the final drawing span on this edge.
            if (fetch_active_q && (gfx_have_q || gfx_rsp_take) &&
                (clut_have_q || clut_rsp_take) &&
                ((draw_state == D_IDLE) || ((draw_state == D_WRITE) &&
                 (draw_pixel_index_q + 1'b1 >= draw_pixels_q)))) begin
                draw_layer_q <= fetch_layer_q;draw_screen_x_q <= fetch_screen_x_q;
                draw_local_x_q <= fetch_local_x_q;draw_local_y_q <= fetch_local_y_q;
                draw_pixels_q <= fetch_pixels_q;draw_tile_code_q <= fetch_tile_code_q;
                draw_color_q <= fetch_color_q;draw_force_q <= fetch_force_q;
                draw_category_q <= fetch_category_q;draw_pixel_index_q <= 0;
                gfx_row_q <= gfx_have_q ? fetch_gfx_row_q : gfx_rsp_data;
                clut_row_q <= clut_have_q ? fetch_clut_row_q : clut_rsp_data;
                draw_state <= D_WRITE;fetch_active_q <= 0;
            end

            if (complete_now) begin
                render_active <= 1'b0;
                bank_valid_q[active_bank_q] <= 1'b1;
                if (active_bank_q)
                    bank_y1_q <= line_y_q;
                else
                    bank_y0_q <= line_y_q;
                line_done_valid <= 1'b1;
                line_done_bank <= active_bank_q;
                line_done_y <= line_y_q;
            end

            if (line_done_valid && line_done_ready)
                line_done_valid <= 1'b0;

            if (line_release_valid && bank_valid_q[line_release_bank])
                bank_valid_q[line_release_bank] <= 1'b0;

            if (scan_accept) begin
                scan_rsp_valid <= 1'b1;
                scan_rsp_bank_q <= scan_bank;
                scan_rsp_y_q <= scan_y;
                scan_rsp_x_q <= scan_x;
            end else if (scan_rsp_valid && scan_rsp_ready) begin
                scan_rsp_valid <= 1'b0;
            end

            if (deadline_check &&
                !((bank_valid_q[0] && bank_y0_q == deadline_y) ||
                  (bank_valid_q[1] && bank_y1_q == deadline_y)))
                deadline_miss <= 1'b1;
        end
    end
endmodule

// Four 16-bit slots share a 64-bit word. Two byte enables update one
// 13-bit pixel; padding preserves independent writes without a merge read.
module bigfight_tile_line_ram #(parameter QUAD_COLLECT=0)(
 input logic clk,wr_en,input logic [8:0] wr_addr,input logic [12:0] wr_data,
 input logic rd_en,input logic [8:0] rd_addr,
 output logic [12:0] rd_data,output wire [51:0] rd_quad);
 genvar k;
 generate if(!QUAD_COLLECT)begin:g_scalar
   logic [12:0] memory[0:319];
   always_ff @(posedge clk)begin
     if(wr_en)memory[wr_addr]<=wr_data;
     if(rd_en)rd_data<=memory[rd_addr];
   end
   assign rd_quad='0;
 end else begin:g_quad
   logic [1:0] lane_q;
   wire [63:0] packed_q;
   always_ff @(posedge clk)if(rd_en)lane_q<=rd_addr[1:0];
   bigfight_tile_packed_ram ram(
     .clk(clk),.wr_en(wr_en),.wr_addr(wr_addr[8:2]),
     .wr_data({4{{3'd0,wr_data}}}),
     .wr_byteena(8'd3 << {wr_addr[1:0],1'b0}),
     .rd_en(rd_en),.rd_addr(rd_addr[8:2]),.rd_data(packed_q));
   for(k=0;k<4;k=k+1)begin:g_lane
     assign rd_quad[13*k+:13]=packed_q[16*k+:13];
   end
   always_comb rd_data=rd_quad[13*lane_q+:13];
 end endgenerate
endmodule

// Cyclone V simple-dual-port byte-enable layout. Address registration gives
// the same one-clock read as the behavioural model; mixed-port OLD_DATA is
// retained. Parameter pattern follows corpus ki_fb_ram/gd_word_ram; neither
// donor clocks nor timing constraints are imported.
module bigfight_tile_packed_ram #(parameter WORDS=80)(
 input wire clk,wr_en,rd_en,input wire [6:0] wr_addr,rd_addr,
 input wire [63:0] wr_data,input wire [7:0] wr_byteena,
 output wire [63:0] rd_data);
`ifdef VERILATOR
 `define BIGFIGHT_PACKED_RAM_MODEL
`elsif __ICARUS__
 `define BIGFIGHT_PACKED_RAM_MODEL
`endif
`ifdef BIGFIGHT_PACKED_RAM_MODEL
 reg [63:0] memory[0:WORDS-1];
 reg [63:0] q;
 integer b;
 always @(posedge clk) begin
   if(wr_en) for(b=0;b<8;b=b+1)
     if(wr_byteena[b]) memory[wr_addr][8*b+:8]<=wr_data[8*b+:8];
   if(rd_en) q<=memory[rd_addr];
 end
 assign rd_data=q;
`else
 altsyncram #(
   .operation_mode("DUAL_PORT"),.intended_device_family("Cyclone V"),
   .lpm_type("altsyncram"),.ram_block_type("M10K"),.byte_size(8),
   .width_a(64),.width_b(64),.widthad_a(7),.widthad_b(7),
   .numwords_a(WORDS),.numwords_b(WORDS),.width_byteena_a(8),
   // Variable read-enable and every B-port input use the same clock
   // selector. Q17 otherwise defaults read control to CLOCK1.
   .address_reg_b("CLOCK0"),.rdcontrol_reg_b("CLOCK0"),
   .indata_reg_b("CLOCK0"),.byteena_reg_b("CLOCK0"),
   .wrcontrol_wraddress_reg_b("CLOCK0"),.outdata_reg_b("UNREGISTERED"),
   .clock_enable_input_a("BYPASS"),.clock_enable_input_b("BYPASS"),
   .clock_enable_output_b("BYPASS"),
   .read_during_write_mode_mixed_ports("OLD_DATA")
 ) ram_i(
   .clock0(clk),.clock1(1'b1),.clocken0(1'b1),.clocken1(1'b1),
   .clocken2(1'b1),.clocken3(1'b1),.aclr0(1'b0),.aclr1(1'b0),
   .address_a(wr_addr),.data_a(wr_data),.byteena_a(wr_byteena),
   .wren_a(wr_en),.address_b(rd_addr),.rden_b(rd_en),.q_b(rd_data)
 );
`endif
endmodule
