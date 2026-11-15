// Complete isolated video datapath: renderer, stable display bank, palette and RGB.
// Raster supplies start/swap/scan enables and the vblank-start frame latch. All state and RAM use the board clock.
module steel_video(
    input wire clk,reset,mortalr,start,swap,frame_latch,
    input wire [7:0] line_y,
    output wire busy,done,line_ready,
    output wire ram_en,
    output wire [16:0] ram_addr,
    input wire [15:0] ram_data,
    output wire sprite_en,
    output wire [7:0] sprite_index,
    input wire [63:0] sprite_data,
    output wire gfx_req,
    output wire [22:0] gfx_addr,
    input wire gfx_ready,
    input wire [63:0] gfx_data,
    input wire palette_we,
    input wire [10:0] palette_addr,
    input wire [15:0] palette_data,
    input wire [1:0] palette_lanes,
    input wire scan_en,
    input wire [8:0] scan_x,
    output wire [10:0] scan_index,
    output wire [4:0] scan_priority,
    output wire rgb_valid,
    output wire [23:0] rgb
);
    wire line_ram_en;
    wire [16:0] line_ram_addr;
    wire [15:0] line_ram_data;
    steel_video_line line_renderer(.clk(clk),.reset(reset),.mortalr(mortalr),.start(start),.swap(swap),.line_y(line_y),
        .busy(busy),.done(done),.line_ready(line_ready),.ram_en(line_ram_en),.ram_addr(line_ram_addr),.ram_data(line_ram_data),
        .sprite_en(sprite_en),.sprite_index(sprite_index),.sprite_data(sprite_data),
        .gfx_req(gfx_req),.gfx_addr(gfx_addr),.gfx_ready(gfx_ready),.gfx_data(gfx_data),
        .scan_en(scan_en),.scan_x(scan_x),.scan_index(scan_index),.scan_priority(scan_priority));
    steel_scroll_shadow scroll_shadow(.clk(clk),.reset(reset),.latch(frame_latch),.render_busy(busy),
        .r_en(line_ram_en),.r_addr(line_ram_addr),.r_data(line_ram_data),
        .ram_en(ram_en),.ram_addr(ram_addr),.ram_data(ram_data));
    reg palette_en;
    always @(posedge clk) palette_en<=scan_en && !reset;
    steel_palette palette(.clk(clk),.reset(reset),.latch(frame_latch),.cpu_we(palette_we),.cpu_addr(palette_addr),
        .cpu_data(palette_data),.cpu_lanes(palette_lanes),.pixel_en(palette_en),.pixel_index(scan_index),
        .rgb_valid(rgb_valid),.rgb(rgb));
endmodule
