// Raw MiSTer video chain bench top: the core's native raster (cs_video_hold, the game's
// 455x262 / 320x240 geometry at one pixel enable per 12 clocks) -> CRT Adjust -> the real
// sys/arcade_video (video_mixer, scandoubler, HQ2x). This is what Direct Video, the analog
// DAC and a CRT see; HDMI rescales from DE and hides these errors.
module cs_sys_video (
    input  logic clk,
    input  logic [2:0] fx,
    input  logic forced_scandoubler,
    input  logic osd_on,
    input  logic [4:0] h_size,
    input  logic [3:0] h_offset, v_offset,
    output logic CE_PIXEL, VGA_HS, VGA_VS, VGA_DE,
    output logic [7:0] VGA_R, VGA_G, VGA_B
);
    logic ce, hb, vb, hs, vs, ahs, avs;
    logic [11:0] x, y;
    logic [23:0] rgb;
    cs_video_hold hold (.clk, .game_active(1'b0), .game_ce(1'b0), .game_hblank(1'b0), .game_vblank(1'b0),
        .game_hs(1'b1), .game_vs(1'b1), .game_x(12'd0), .game_y(12'd0), .game_rgb(24'd0),
        .ce, .hblank(hb), .vblank(vb), .hs, .vs, .x, .y, .rgb());
    // Test picture: every pixel distinct (x in red/green, y in blue) to catch dropped columns.
    assign rgb = {x[7:0], {4'b0,x[11:8]}, y[7:0]};
    // CRT Adjust exactly as CrystalSystem.sv wires it (active-high module, active-low core syncs).
    logic vb_d = 0;
    always_ff @(posedge clk) vb_d <= vb;
    wire vb_next = (y + 12'd1 >= 12'd240) && (y + 12'd1 < 12'd262);
    wire ace, ahb, avb, ahs_p, avs_p;
    wire [23:0] argb;
    crystal_crt_adjust adjust (.clk_sys(clk), .ce_pix(ce), .frame_event(vb && !vb_d),
        .osd_on, .osd_hsize(h_size), .osd_hpos(h_offset), .osd_vshift(v_offset),
        .sd_off(fx == 3'd0 && !forced_scandoubler), .vb_next, .wide(1'b0),
        .rgb_in(rgb), .hblank_in(hb), .vblank_in(vb), .hsync_in(!hs), .vsync_in(!vs),
        .ce_out(ace), .rgb_out(argb), .hblank_out(ahb), .vblank_out(avb), .hsync_out(ahs_p), .vsync_out(avs_p),
        .active(), .hsize_s(), .hpos_s(), .vsh_s());
    assign ahs = !ahs_p; assign avs = !avs_p;
    wire [21:0] gamma_bus;
    assign gamma_bus[20:0] = 21'd0;
    wire [1:0] sl;
    arcade_video #(.WIDTH(360), .DW(24)) video (.clk_video(clk), .ce_pix(ace), .RGB_in(argb),
        .HBlank(ahb), .VBlank(avb), .HSync(ahs), .VSync(avs),
        .CLK_VIDEO(), .CE_PIXEL, .VGA_R, .VGA_G, .VGA_B, .VGA_HS, .VGA_VS, .VGA_DE, .VGA_SL(sl),
        .fx, .forced_scandoubler, .gamma_bus);
endmodule
