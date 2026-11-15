// Shared MAME 0.289 Big Fight tile coordinate and scroll/page calculation.
// cyclwarr_i selects MAME cyclwarr_state::video_start geometry: layers 0/2/3
// are 64x512 tiles (layer 0 page 0x100), layer 1 is 128x256 with the
// per-scanline road colour bank of draw_bg(is_road). 0 keeps bigfight_state.
module bigfight_tile_math (
    input  logic        cyclwarr_i,
    output logic [1:0]  road_bank,
    input  logic [1:0]  layer,
    input  logic [8:0]  pix_x,
    input  logic [8:0]  pix_y,
    input  logic [15:0] scrollx0_i,
    input  logic [15:0] scrollx_line_i,
    input  logic [15:0] scrolly0_i,
    input  logic [15:0] scrolly_line_i,
    input  logic [15:0] page_select_i,
    output logic        map_bank,
    output logic [14:0] map_addr,
    output logic [9:0]  world_x,
    output logic [10:0] world_y,
    output logic [2:0]  local_x,
    output logic [2:0]  local_y
);
    logic [10:0] src_x;
    logic [10:0] src_y;
    logic [10:0] src_y_wrapped;
    logic [12:0] current_page;
    logic [16:0] page_limit;
    logic [11:0] world_x_sum;
    logic [11:0] world_y_sum;
    logic page_wrap;
    logic page_disable;
    logic [15:0] scrolly_sel;
    logic narrow;
    logic road;
    logic [11:0] world_y12;

    always @* begin
        // MAME draw_bg indexes the horizontal table by x_base when bit 13 is
        // clear, and the vertical table by y_base when bit 12 is clear.
        src_x = scrollx0_i[13] ? scrollx0_i[10:0] : scrollx_line_i[10:0];
        scrolly_sel = scrollx0_i[12] ? scrolly0_i : scrolly_line_i;
        src_y = scrolly_sel[10:0];
        narrow = cyclwarr_i && (layer != 2'd1);
        road = cyclwarr_i && (layer == 2'd1) && scrolly_sel[15];
        road_bank = road ? scrolly_sel[14:13] : 2'd0;
        // Road mode disables page wraparound.
        page_disable = scrolly_sel[11] || road;
        current_page = {2'b00, src_y} + {4'b0000, pix_y};
        page_limit = {1'b0, page_select_i} +
                     ((cyclwarr_i && layer == 2'd0) ? 17'd256 : 17'd512);
        page_wrap = !page_disable && ({4'b0000, current_page} >= page_limit);
        src_y_wrapped = page_wrap ? (src_y - 11'd512) : src_y;
        // 64x512 maps wrap at 4096 rows: subtract the page in 12 bits.
        world_y12 = {1'b0, src_y} + {3'b000, pix_y} -
                    (page_wrap ? ((layer == 2'd0) ? 12'd256 : 12'd512) : 12'd0);

        // tilemap_t::set_scrolldx is -16 for layer 0 and -8 for layers 1..3.
        world_x_sum = {3'b000, pix_x} + {1'b0, src_x} +
                      ((layer == 2'd0) ? 12'd16 : 12'd8);
        world_y_sum = {3'b000, pix_y} + {1'b0, src_y_wrapped};
        world_x = world_x_sum[9:0];
        world_y = world_y_sum[10:0];
        local_x = world_x[2:0];
        local_y = world_y[2:0];
        map_bank = layer[1];
        // 128 columns by 256 rows, row-major.
        map_addr = {world_y[10:3], world_x[9:3]};
        if (narrow) begin
            // 64 columns by 512 rows, row-major; x wraps at 512 pixels.
            world_y = world_y12[10:0];
            local_y = world_y12[2:0];
            map_addr = {world_y12[11:3], world_x[8:3]};
        end
    end
endmodule
