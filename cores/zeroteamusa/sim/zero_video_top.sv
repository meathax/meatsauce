// Standalone video fixture uses the actual captured RTL buffers, never CPU emulation.
module zero_video_top (
    input wire clk,reset,flip,
    input wire [31:0] rom_data,
    input wire rom_valid,
    output wire rom_request,
    output wire [23:0] rom_address,
    output wire [2:0] rom_kind,
    output wire sprite_request,
    output wire [23:0] sprite_address,
    input wire [31:0] sprite_data,
    input wire sprite_valid,sprite_half,
    output wire ce_pixel,display_enable,vblank,
    output wire [9:0] x,
    output wire [8:0] y,
    output wire [7:0] r,g,b,
    output wire pixel_strobe,pixel_display,
    output wire [9:0] pixel_x,
    output wire [8:0] pixel_y
);
    wire [10:0] bg_a,mg_a,fg_a,tx_a,spr_a,pal_a;
    reg [15:0] bg[0:2047],mg[0:2047],fg[0:2047],tx[0:2047],spr[0:2047],pal[0:2047];
    initial begin
        $readmemh("sim/results/video-fixture-bg.mem",bg);
        $readmemh("sim/results/video-fixture-mg.mem",mg);
        $readmemh("sim/results/video-fixture-fg.mem",fg);
        $readmemh("sim/results/video-fixture-text.mem",tx);
        $readmemh("sim/results/video-fixture-sprite.mem",spr);
        $readmemh("sim/results/video-fixture-palette.mem",pal);
    end
    reg [15:0] bg_q,mg_q,fg_q,tx_q,spr_q,pal_q;
    always @(posedge clk) begin
        bg_q<=bg[bg_a]; mg_q<=mg[mg_a]; fg_q<=fg[fg_a]; tx_q<=tx[tx_a]; spr_q<=spr[spr_a]; pal_q<=pal[pal_a];
    end
    ZeroTeam_video video (
        .clk(clk),.reset(reset),.layer_enable(5'b11111),.flip_screen(flip),
        .bg_x(16'd0),.bg_y(16'd0),.mg_x(16'd0),.mg_y(16'd0),.fg_x(16'd0),.fg_y(16'd0),.tx_x(16'd0),.tx_y(16'd0),
        .bg_address(bg_a),.mg_address(mg_a),.fg_address(fg_a),.tx_address(tx_a),.spr_address(spr_a),.pal_address(pal_a),
        .bg_data(bg_q),.mg_data(mg_q),.fg_data(fg_q),.tx_data(tx_q),.spr_data(spr_q),.pal_data(pal_q),
        .rom_request(rom_request),.rom_address(rom_address),.rom_kind(rom_kind),.rom_data(rom_data),.rom_valid(rom_valid),
        .sprite_rom_request(sprite_request),.sprite_rom_address(sprite_address),.sprite_rom_data(sprite_data),
        .sprite_rom_valid(sprite_valid),.sprite_rom_half(sprite_half),
        .ce_pixel(ce_pixel),.display_enable(display_enable),.vblank(vblank),.x(x),.y(y),.r(r),.g(g),.b(b),
        .pixel_strobe(pixel_strobe),.pixel_display(pixel_display),.pixel_x(pixel_x),.pixel_y(pixel_y)
    );
endmodule
