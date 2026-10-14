// Isolated strip/palette/SDRAM fixture, not CPU boot or game acceptance.
module alpha68kn_render_fixture (
    input wire clk,reset,load_wr,strip_wr,refresh,line_start,flip,stingray,
    input wire [24:0] load_addr,
    input wire [15:0] load_data,strip_din,
    input wire [11:0] strip_write_addr,
    input wire [8:0] line_y,video_y,
    input wire [7:0] video_x,background,
    output wire [23:0] rgb,
    output wire load_wait,load_busy,initialized,
    output wire [11:0] worst_line_cycles,
    output wire [31:0] completed_lines,deadline_misses,row_overflows,
    inout wire [15:0] sdram_dq,
    output wire [15:0] sdram_din,
    output wire [12:0] sdram_a,
    output wire [1:0] sdram_ba,
    output wire sdram_dqml,sdram_dqmh,sdram_nwe,sdram_ncas,sdram_nras,sdram_ncs,sdram_cke
);
    reg [15:0] strips[0:4095];
    wire [11:0] strip_addr;
    reg [15:0] strip_data;
    wire [12:0] color_addr;
    wire [7:0] color_data;
    wire [8:0] pen;
    wire gfx_req,gfx_ack,gfx_ready;
    wire [18:0] gfx_addr;
    wire [15:0] gfx_data;
    always @(posedge clk) begin
        if(strip_wr) strips[strip_write_addr]<=strip_din;
        strip_data<=strips[strip_addr];
    end
    alpha68kn_video_rom rom (
        .clk(clk),.load_wr(load_wr),.load_addr(load_addr),.load_data(load_data),
        .color_addr(color_addr),.color_data(color_data),.pen(pen),.background(background),
        .rgb(rgb),.debug_kind(4'd0),.debug_addr(13'd0),.debug_data()
    );
    alpha68kn_renderer renderer (
        .clk(clk),.reset(reset),.line_start(line_start),.line_y(line_y),
        .video_y(video_y),.video_x(video_x),.video_pen(pen),.flip(flip),.stingray(stingray),
        .strip_addr(strip_addr),.strip_data(strip_data),.color_addr(color_addr),.color_data(color_data),
        .gfx_req(gfx_req),.gfx_addr(gfx_addr),.gfx_ack(gfx_ack),.gfx_ready(gfx_ready),.gfx_data(gfx_data),
        .worst_line_cycles(worst_line_cycles),.completed_lines(completed_lines),
        .deadline_misses(deadline_misses),.row_overflows(row_overflows)
    );
    alpha68kn_gfxmem gfxmem (
        .clk(clk),.reset(reset),.load_wr(load_wr && load_addr>=25'h40000 && load_addr<25'ha0000),
        .load_addr(19'(load_addr-25'h40000)),.load_data(load_data),
        .load_wait(load_wait),.load_busy(load_busy),.initialized(initialized),.loaded_words(),
        .refresh(refresh),.read_req(gfx_req),.read_addr(gfx_addr),
        .read_ack(gfx_ack),.read_ready(gfx_ready),.read_data(gfx_data),
        .sdram_dq(sdram_dq),.sdram_din(sdram_din),.sdram_a(sdram_a),.sdram_ba(sdram_ba),
        .sdram_dqml(sdram_dqml),.sdram_dqmh(sdram_dqmh),.sdram_nwe(sdram_nwe),
        .sdram_ncas(sdram_ncas),.sdram_nras(sdram_nras),.sdram_ncs(sdram_ncs),.sdram_cke(sdram_cke)
    );
endmodule
