// SPDX-License-Identifier: GPL-3.0-or-later
// Heavy Unit opaque tile line pipeline. Row-major addressing/registered RAM
// staging follows JTFRAME tilemap/tilebuf architecture; packed fetch follows
// the pinned Sand Scorpion decoder. No CPU-local memory mirror is owned here.
module heavyunit_tilemap (
    input logic clk, reset,
    input logic prepare_line,
    input logic line_commit,
    input logic [7:0] prepare_y,
    input logic [8:0] scroll_x, scroll_y,
    output logic busy, line_ready, line_pending,
    output logic [9:0] tile_addr,
    input logic [7:0] tile_code, tile_attr,
    output logic rom_req_valid,
    input logic rom_req_ready,
    output logic [18:0] rom_req_addr,
    input logic rom_rsp_valid,
    input logic [63:0] rom_rsp_data,
    input logic [7:0] rd_x,
    output logic [7:0] rd_pix
);
    typedef enum logic [3:0] {IDLE,MAP0,MAP1,LREQ,LWAIT,RREQ,RWAIT,DRAW,DONE} state_t;
    state_t state;
    logic [7:0] lines [0:511];
    logic display_page, draw_page;
    logic [8:0] source_x, source_y, output_x;
    logic [11:0] code;
    logic [3:0] bank, px;
    logic [63:0] left_pair, right_pair;
    logic [20:0] packed_address;
    logic [3:0] packed_pen;
    logic read_page;
    heavyunit_gfx_decode decode(.code({2'b0,code}),.x(px),.y(source_y[3:0]),
        .data(px[3] ? right_pair : left_pair),.address(packed_address),.pen(packed_pen));
    assign tile_addr = {source_y[8:4],source_x[8:4]};
    assign rom_req_valid = state == LREQ || state == RREQ;
    assign rom_req_addr = {code,7'b0} | {12'b0,source_y[3],state == RREQ,source_y[2:1],3'b0};
    assign busy = state != IDLE || line_pending;
    assign read_page = line_commit && line_pending ? draw_page : display_page;
    always_ff @(posedge clk) begin
        rd_pix <= lines[{read_page,rd_x}];
        line_ready <= 1'b0;
        if (reset) begin state <= IDLE; display_page <= 0; draw_page <= 1; line_pending <= 0; end
        else begin
            // Completion makes a page pending. Only the raster owner's explicit
            // boundary transfers it to scanout, even if preparation finishes
            // halfway through a currently displayed line.
            if(line_commit && line_pending) begin display_page <= draw_page; line_pending <= 0; end
            case(state)
            IDLE: if(prepare_line && (!line_pending || line_commit)) begin
                source_x <= scroll_x + 9'd96;
                source_y <= {1'b0,prepare_y} + scroll_y;
                output_x <= 0; draw_page <= line_pending ? display_page : ~display_page; state <= MAP0;
            end
            MAP0: state <= MAP1;
            MAP1: begin code <= {tile_attr[3:0],tile_code}; bank <= tile_attr[7:4];
                px <= source_x[3:0]; state <= LREQ; end
            LREQ: if(rom_req_ready) state <= LWAIT;
            LWAIT: if(rom_rsp_valid) begin left_pair <= rom_rsp_data; state <= RREQ; end
            RREQ: if(rom_req_ready) state <= RWAIT;
            RWAIT: if(rom_rsp_valid) begin right_pair <= rom_rsp_data; state <= DRAW; end
            DRAW: begin
                lines[{draw_page,output_x[7:0]}] <= {bank,packed_pen};
                output_x <= output_x + 9'd1; source_x <= source_x + 9'd1; px <= px + 4'd1;
                if(output_x == 9'd255) state <= DONE;
                else if(px == 4'd15) state <= MAP0;
            end
            DONE: begin line_pending <= 1'b1; line_ready <= 1'b1; state <= IDLE; end
            default: state <= IDLE;
            endcase
        end
    end
endmodule
