// SPDX-License-Identifier: GPL-3.0-or-later
// HeavyUnit-inspired Hangzo video boundary. Uses the pinned Template sys video
// chain; CRT and framebuffer features stay disabled until the caller qualifies
// their native timing and downstream DDR ownership.
module hangzo_video_output #(
    parameter integer NATIVE_PIXEL_DIV=0,
    parameter integer NATIVE_HTOTAL=0,
    parameter integer NATIVE_VTOTAL=0,
    parameter integer NATIVE_HACTIVE_START=0,
    parameter integer NATIVE_HS_REFERENCE=0,
    parameter integer NATIVE_ACTIVE_WIDTH=320,
    parameter integer NATIVE_ACTIVE_HEIGHT=240,
    parameter integer CRT_HSIZE_MIN=0,CRT_HSIZE_MAX=0,
    parameter integer CRT_HPOS_MIN=0,CRT_HPOS_MAX=0,
    parameter integer CRT_VPOS_MIN=0,CRT_VPOS_MAX=0,
    parameter bit NATIVE_TIMING_VALIDATED=1'b0,
    parameter bit CRT_CONTROLS_VALIDATED=1'b0,
    parameter bit FRAMEBUFFER_SUPPORTED=1'b0,
    parameter bit DIRECT_VIDEO_ROTATION_SUPPORTED=1'b0
)(
    input  logic        clk_sys,
    input  logic        reset,
    input  logic        raw_ce,
    input  logic [23:0] raw_rgb,
    input  logic        raw_hs,
    input  logic        raw_vs,
    input  logic        raw_hblank,
    input  logic        raw_vblank,
    input  logic        native_frame_boundary,
    input  logic        native_sync_qualified,
    input  logic [127:0] status,
    inout  wire [21:0]  gamma_bus,
    input  logic        direct_video,
    input  logic        forced_scandoubler,
    input  logic [11:0] hdmi_width,
    input  logic [11:0] hdmi_height,
    input  logic        fb_vblank,
    input  logic        fb_low_latency,
    input  logic        ddram_busy,
    input  logic        rotation_pause_request,
    input  logic        rotation_owner_drained,
    output wire         rotation_quiescent,

    output wire         clk_video,
    output logic        output_ce,
    output wire [23:0]  output_rgb,
    output logic        output_hs,
    output logic        output_vs,
    output wire         output_de,
    output wire [1:0]   output_scanline,
    output logic [12:0] video_arx,
    output logic [12:0] video_ary,
    output logic [11:0] aspect_x,
    output logic [11:0] aspect_y,
    output wire [1:0]   aspect_mode,
    output wire [1:0]   scale_mode,
    output wire [2:0]   scale_code,
    output logic [2:0]  scanline_effect,
    output wire [1:0]   rotation_mode,
    output logic        rotation_available,
    output logic        video_rotated,
    // Level request for the game/platform to latch at its native frame
    // boundary. Direct video never invokes the DDR framebuffer producer.
    output wire         native_flip_requested,
    output logic [15:0] status_menumask,
    output logic        crt_available,
    output logic        crt_active,
    output logic        crt_range_clamped,
    output wire         crt_ranges_valid,
    output wire signed [4:0] crt_hsize_setting,
    output wire signed [6:0] crt_hposition_setting,
    output wire signed [4:0] crt_vposition_setting,

    // MiSTer screen_rotate producer interface. DDRAM_WE is a one-cycle write
    // pulse; this donor has no ready/hold protocol. The caller must enqueue
    // each pulse and drain it before disabling or changing framebuffer mode.
    output wire         DDRAM_CLK,
    input  logic        DDRAM_BUSY,
    output wire [7:0]   DDRAM_BURSTCNT,
    output wire [28:0]  DDRAM_ADDR,
    output wire [63:0]  DDRAM_DIN,
    output wire [7:0]   DDRAM_BE,
    output wire         DDRAM_WE,
    output wire         DDRAM_RD,
    output wire         FB_EN,
    output wire [4:0]   FB_FORMAT,
    output wire [11:0]  FB_WIDTH,
    output wire [11:0]  FB_HEIGHT,
    output wire [31:0]  FB_BASE,
    output wire [13:0]  FB_STRIDE
);

    function automatic bit menu_range_valid(input integer mn,mx,width);
        menu_range_valid=(width==5 || width==7) && mn<=0 && mx>=0 &&
            mn>=-(1<<(width-1)) && mx<(1<<(width-1));
    endfunction

    function automatic integer menu_decode(input integer index_value,mn,mx,width);
        begin
            menu_decode=0;
            if(menu_range_valid(mn,mx,width) && index_value>0 && index_value<(1+mx-mn)) begin
                if(index_value<=mx) menu_decode=index_value;
                else menu_decode=mn+(index_value-mx-1);
            end
        end
    endfunction

    localparam bit CRT_MENU_RANGES_VALID=
        menu_range_valid(CRT_HSIZE_MIN,CRT_HSIZE_MAX,5) &&
        menu_range_valid(CRT_HPOS_MIN,CRT_HPOS_MAX,7) &&
        menu_range_valid(CRT_VPOS_MIN,CRT_VPOS_MAX,5);
    assign crt_ranges_valid=CRT_MENU_RANGES_VALID;

    assign aspect_mode=status[122:121];
    assign scale_mode=status[47:46];
    always_comb begin
        case(aspect_mode)
            2'd0: begin aspect_x=12'd4; aspect_y=12'd3; end
            2'd1: begin aspect_x=12'd0; aspect_y=12'd0; end
            2'd2: begin aspect_x=12'd1; aspect_y=12'd0; end
            default: begin aspect_x=12'd2; aspect_y=12'd0; end
        endcase
    end

    wire quarter_turn_request=!direct_video &&
        (status[45:44]==2'd1 || status[45:44]==2'd2);
    wire direct_half_turn_request=direct_video && status[53];
    wire fb_rotation_path=FRAMEBUFFER_SUPPORTED && !direct_video;
    wire direct_rotation_path=DIRECT_VIDEO_ROTATION_SUPPORTED && direct_video;
    wire rotation_path=fb_rotation_path || direct_rotation_path;
    wire [1:0] requested_rotation=direct_video ? (status[53] ? 2'd3 : 2'd0) : status[45:44];
    assign rotation_available=rotation_path;
    assign rotation_mode=rotation_path ? requested_rotation : 2'd0;
    assign native_flip_requested=direct_rotation_path && direct_half_turn_request;
    wire rotate90=(rotation_mode==2'd1 || rotation_mode==2'd2);

    always_comb begin
        scanline_effect=direct_video ? 3'd0 : status[52:50];
        status_menumask='0;
        status_menumask[0]=!native_sync_qualified || direct_video;
        status_menumask[1]=direct_video || !FRAMEBUFFER_SUPPORTED;
        status_menumask[2]=!direct_video || !DIRECT_VIDEO_ROTATION_SUPPORTED;
        status_menumask[3]=!(crt_available && CRT_CONTROLS_VALIDATED && CRT_MENU_RANGES_VALID);
        status_menumask[4]=!status[54];
    end

    assign crt_hsize_setting=$signed(5'(menu_decode(int'(status[59:55]),CRT_HSIZE_MIN,CRT_HSIZE_MAX,5)));
    assign crt_hposition_setting=$signed(7'(menu_decode(int'(status[66:60]),CRT_HPOS_MIN,CRT_HPOS_MAX,7)));
    assign crt_vposition_setting=$signed(5'(menu_decode(int'(status[71:67]),CRT_VPOS_MIN,CRT_VPOS_MAX,5)));

    wire crt_ce,crt_hs,crt_vs,crt_hb,crt_vb;
    wire [23:0] crt_rgb;
    hangzo_native_crt_adjust #(
        .PIXEL_DIV(NATIVE_PIXEL_DIV),.HTOTAL(NATIVE_HTOTAL),.VTOTAL(NATIVE_VTOTAL),
        .HACTIVE_START(NATIVE_HACTIVE_START),.HS_REFERENCE(NATIVE_HS_REFERENCE),
        .ACTIVE_WIDTH(NATIVE_ACTIVE_WIDTH),.ACTIVE_HEIGHT(NATIVE_ACTIVE_HEIGHT),
        .HSIZE_MIN(CRT_HSIZE_MIN),.HSIZE_MAX(CRT_HSIZE_MAX),
        .HPOS_MIN(CRT_HPOS_MIN),.HPOS_MAX(CRT_HPOS_MAX),
        .VPOS_MIN(CRT_VPOS_MIN),.VPOS_MAX(CRT_VPOS_MAX)
    ) crt_adjust (
        .clk(clk_sys),.reset,.native_frame_boundary,
        .native_timing_valid(NATIVE_TIMING_VALIDATED && native_sync_qualified),
        .native_profile(NATIVE_TIMING_VALIDATED),.path_selected(1'b1),
        .scandoubler_enabled((status[52:50]!=3'd0 && !direct_video) || forced_scandoubler),
        .quarter_turn_selected(quarter_turn_request),
        .enable(status[54] && CRT_CONTROLS_VALIDATED && CRT_MENU_RANGES_VALID),
        .hsize(crt_hsize_setting),.hposition(crt_hposition_setting),.vposition(crt_vposition_setting),
        .ce_in(raw_ce),.rgb_in(raw_rgb),.hs_in(raw_hs),.vs_in(raw_vs),.hb_in(raw_hblank),.vb_in(raw_vblank),
        .ce_out(crt_ce),.rgb_out(crt_rgb),.hs_out(crt_hs),.vs_out(crt_vs),.hb_out(crt_hb),.vb_out(crt_vb),
        .active(crt_active),.available(crt_available),.range_clamped(crt_range_clamped)
    );

    wire std_ce,std_hs,std_vs,std_de;
    wire [7:0] std_r,std_g,std_b;
    wire [1:0] std_sl;
    hangzo_arcade_video #(.WIDTH(NATIVE_ACTIVE_WIDTH),.DW(24),.GAMMA(1)) standard_video (
        .clk_video(clk_sys),.ce_pix(crt_ce),.RGB_in(crt_rgb),
        .HBlank(crt_hb),.VBlank(crt_vb),.HSync(crt_hs),.VSync(crt_vs),
        .CLK_VIDEO(),.CE_PIXEL(std_ce),.VGA_R(std_r),.VGA_G(std_g),.VGA_B(std_b),
        .VGA_HS(std_hs),.VGA_VS(std_vs),.VGA_DE(std_de),.VGA_SL(std_sl),
        .fx(direct_video ? 3'd0 : status[52:50]),
        .forced_scandoubler(forced_scandoubler),.gamma_bus
    );
    assign clk_video=clk_sys;
    // The pinned arcade_video CE precedes its registered RGB/DE/sync outputs.
    // Delay by two CE events so a caller samples the matching processed pixel.
    logic [1:0] output_ce_event_history;
    always_ff @(posedge clk_sys) begin
        if (reset) begin
            output_ce<=1'b0;
            output_ce_event_history<=2'b00;
        end else begin
            output_ce<=1'b0;
            if (std_ce) begin
                output_ce<=output_ce_event_history[1];
                output_ce_event_history<={output_ce_event_history[0],1'b1};
            end
        end
    end
    assign output_rgb={std_r,std_g,std_b};
    assign {output_hs,output_vs}= {std_hs,std_vs};
    assign output_scanline=std_sl;

    wire [11:0] arx=rotate90 ? aspect_y : aspect_x;
    wire [11:0] ary=rotate90 ? aspect_x : aspect_y;
    wire [2:0] scale=scale_mode==2'd1 ? 3'd1 : scale_mode==2'd2 ? 3'd4 : 3'd0;
    assign scale_code=scale;
    wire crop_de;
    wire [12:0] normal_arx,normal_ary;
    video_freak presentation (
        .CLK_VIDEO(clk_sys),.CE_PIXEL(std_ce),.VGA_VS(std_vs),
        .HDMI_WIDTH(hdmi_width),.HDMI_HEIGHT(hdmi_height),.VGA_DE(crop_de),
        .VIDEO_ARX(normal_arx),.VIDEO_ARY(normal_ary),.VGA_DE_IN(std_de),
        .ARX(arx),.ARY(ary),.CROP_SIZE(12'd0),.CROP_OFF(5'd0),.SCALE(scale)
    );
    wire [11:0] scale_w=rotate90 ? 12'(NATIVE_ACTIVE_HEIGHT) : 12'(NATIVE_ACTIVE_WIDTH);
    wire [11:0] scale_h=rotate90 ? 12'(NATIVE_ACTIVE_WIDTH) : 12'(NATIVE_ACTIVE_HEIGHT);
    video_scale_int rotated_scale (
        .CLK_VIDEO(clk_sys),.HDMI_WIDTH(hdmi_width),.HDMI_HEIGHT(hdmi_height),.SCALE(scale),
        .hsize(scale_w),.vsize(scale_h),.arx_i(arx),.ary_i(ary),
        .arx_o(video_arx),.ary_o(video_ary)
    );
    assign output_de=crop_de;

    // status[53] selects a game-native half turn in direct video. It must not
    // start screen_rotate or its DDR writer, even when that request is enabled.
    wire rotate_fb_enable=fb_rotation_path && (rotation_mode!=2'd0);
    wire rotate_no_rotate=(rotation_mode==2'd0 || rotation_mode==2'd3);
    wire rotate_ccw=(rotation_mode==2'd2);
    wire rotate_flip=(rotation_mode==2'd3);
    wire producer_no_rotate=!fb_rotation_path || rotate_no_rotate;
    wire producer_ccw=fb_rotation_path && rotate_ccw;
    wire producer_flip=fb_rotation_path && rotate_flip;
    wire donor_fb_en,donor_video_rotated,donor_write,donor_read;
    wire [4:0] donor_format;
    wire [11:0] donor_width,donor_height;
    wire [31:0] donor_base;
    wire [13:0] donor_stride;
    wire [7:0] donor_burst,donor_be;
    wire [28:0] donor_addr;
    wire [63:0] donor_data;
    generate
        if (FRAMEBUFFER_SUPPORTED) begin : g_framebuffer
            hangzo_screen_rotate rotate_framebuffer (
                .CLK_VIDEO(clk_sys),.CE_PIXEL(raw_ce),
                .reset,.pause_request(rotation_pause_request),
                .owner_drained(rotation_owner_drained),.producer_quiescent(rotation_quiescent),
                .VGA_R(raw_rgb[23:16]),.VGA_G(raw_rgb[15:8]),.VGA_B(raw_rgb[7:0]),
                .VGA_HS(raw_hs),.VGA_VS(raw_vs),.VGA_DE(!raw_hblank && !raw_vblank),
                .requested_ccw(producer_ccw),.requested_no_rotate(producer_no_rotate),.requested_flip(producer_flip),
                .video_rotated(donor_video_rotated),.FB_EN(donor_fb_en),.FB_FORMAT(donor_format),
                .FB_WIDTH(donor_width),.FB_HEIGHT(donor_height),.FB_BASE(donor_base),.FB_STRIDE(donor_stride),
                .FB_VBL(fb_vblank),.FB_LL(fb_low_latency),.DDRAM_CLK(DDRAM_CLK),.DDRAM_BUSY(DDRAM_BUSY),
                .DDRAM_BURSTCNT(donor_burst),.DDRAM_ADDR(donor_addr),.DDRAM_DIN(donor_data),
                .DDRAM_BE(donor_be),.DDRAM_WE(donor_write),.DDRAM_RD(donor_read)
            );
            assign video_rotated=rotate_fb_enable && donor_fb_en && donor_video_rotated && rotate90;
            assign FB_EN=rotate_fb_enable && donor_fb_en;
            assign FB_FORMAT=rotate_fb_enable ? donor_format : 5'd0;
            assign FB_WIDTH=rotate_fb_enable ? donor_width : 12'd0;
            assign FB_HEIGHT=rotate_fb_enable ? donor_height : 12'd0;
            assign FB_BASE=rotate_fb_enable ? donor_base : 32'd0;
            assign FB_STRIDE=rotate_fb_enable ? donor_stride : 14'd0;
            // A live menu change must not erase a registered final write.
            // The producer suppresses new pixels; its accepted pulse still
            // reaches the owner before quiescence/drain allows ROM ownership.
            assign DDRAM_BURSTCNT=donor_burst;
            assign DDRAM_ADDR=donor_addr;
            assign DDRAM_DIN=donor_data;
            assign DDRAM_BE=donor_be;
            assign DDRAM_WE=donor_write;
            assign DDRAM_RD=donor_read;
        end else begin : g_framebuffer_unavailable
            assign rotation_quiescent=1'b1;
            assign video_rotated=1'b0;
            assign FB_EN=1'b0;
            assign FB_FORMAT=5'd0;
            assign FB_WIDTH=12'd0;
            assign FB_HEIGHT=12'd0;
            assign FB_BASE=32'd0;
            assign FB_STRIDE=14'd0;
            assign DDRAM_CLK=clk_sys;
            assign DDRAM_BURSTCNT=8'd0;
            assign DDRAM_ADDR=29'd0;
            assign DDRAM_DIN=64'd0;
            assign DDRAM_BE=8'd0;
            assign DDRAM_WE=1'b0;
            assign DDRAM_RD=1'b0;
        end
    endgenerate
endmodule
