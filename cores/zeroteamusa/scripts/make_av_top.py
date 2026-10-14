"""Create the live board/video simulation seam from the established board wiring."""
from pathlib import Path
root=Path(__file__).resolve().parents[1]
target=root/'sim/zero_av_top.sv'
if target.exists(): raise SystemExit('Already created; edit active seam directly.')
s=(root/'sim/zero_board_top.sv').read_text()
s=s.replace('module zero_board_top (','module zero_av_top (')
old='output wire [15:0] bg_data, fg_data, mg_data, text_data, palette_data, sprite_data'
new=old+''',
    input wire [31:0] av_rom_data,
    input wire av_rom_valid,
    output wire av_rom_request,
    output wire [23:0] av_rom_address,
    output wire [2:0] av_rom_kind,
    output wire av_pixel_strobe,av_pixel_display,
    output wire [9:0] av_pixel_x,
    output wire [8:0] av_pixel_y,
    output wire [7:0] av_r,av_g,av_b'''
assert old in s
s=s.replace(old,new)
position=s.index('    ssbus_if')
s=s[:position]+'''    wire [10:0] render_bg,render_mg,render_fg,render_tx,render_spr,render_pal;
    wire video_vblank;
'''+s[position:]
for stem,addr in [('text','tx'),('spr','spr'),('bg','bg'),('fg','fg'),('mg','mg'),('pal','pal')]:
    old=f'.{stem}_vram_addr(video_probe_address)'
    assert old in s,old
    s=s.replace(old,f'.{stem}_vram_addr(pause ? video_probe_address : render_{addr})')
s=s.replace('.vblank_in(vblank)','.vblank_in(video_vblank)')
position=s.rindex('endmodule')
s=s[:position]+'''    ZeroTeam_video video (
        .clk(clk),.reset(reset),
        .layer_enable({board.crtc_layer_en_spr,board.crtc_layer_en_text,
                       board.crtc_layer_en_fg,board.crtc_layer_en_mg,board.crtc_layer_en_bg}),
        .flip_screen(board.crtc_flip_screen),
        .bg_x(board.crtc_scroll_bg_x),.bg_y(board.crtc_scroll_bg_y),
        .mg_x(board.crtc_scroll_mg_x),.mg_y(board.crtc_scroll_mg_y),
        .fg_x(board.crtc_scroll_fg_x),.fg_y(board.crtc_scroll_fg_y),
        .tx_x(16'd0),.tx_y(16'd0),
        .bg_address(render_bg),.mg_address(render_mg),.fg_address(render_fg),
        .tx_address(render_tx),.spr_address(render_spr),.pal_address(render_pal),
        .bg_data(bg_data),.mg_data(mg_data),.fg_data(fg_data),.tx_data(text_data),
        .spr_data(sprite_data),.pal_data(palette_data),
        .rom_request(av_rom_request),.rom_address(av_rom_address),.rom_kind(av_rom_kind),
        .rom_data(av_rom_data),.rom_valid(av_rom_valid),.vblank(video_vblank),
        .pixel_strobe(av_pixel_strobe),.pixel_display(av_pixel_display),
        .pixel_x(av_pixel_x),.pixel_y(av_pixel_y),.r(av_r),.g(av_g),.b(av_b)
    );
'''+s[position:]
target.write_text('// Live CPU/COP memory ports feed the actual target RTL video pipeline.\n'+s)
print('Created live board/video seam; no memory or CPU state injected.')
