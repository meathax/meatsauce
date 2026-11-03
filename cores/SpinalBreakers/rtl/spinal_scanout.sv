// SPDX-License-Identifier: GPL-3.0-or-later
// Fixed CE8 raster with a bounded queue of complete, tagged scanlines.
module spinal_scanout(
    input logic clk,cold_reset,game_reset,flip_screen,
    input logic [7:0] gfxbank,
    input logic [15:0] scrollx1,
    output logic mem_req,
    output logic [3:0] mem_space,
    output logic [21:0] mem_address,
    input logic mem_ready,
    input logic [63:0] mem_data,
    output wire [9:0] palette_address,
    input logic [15:0] palette_data,
    output logic ce_pixel,hs,vs,de,
    output logic [4:0] red,green,blue,
    output logic [8:0] pixel_x,pixel_y,
    output logic pixel_valid,
    output logic [31:0] underruns,
    output wire render_urgent,
    output wire raw_vblank_start
);
    wire raw_ce,raw_hs,raw_vs,hblank,vblank,frame_start,vblank_start;
    wire [8:0] x,y;
    assign raw_vblank_start=vblank_start;
    spinal_video_timing timing(.clk(clk),.cold_reset(cold_reset),.ce_pixel(raw_ce),.x(x),.y(y),
        .hs(raw_hs),.vs(raw_vs),.hblank(hblank),.vblank(vblank),
        .frame_start(frame_start),.vblank_start(vblank_start));
    logic epoch_valid,recover,frame_flip,frame_primed,frame_active;
    wire busy,done,line_ready;
    wire [7:0] ready_y;
    wire [9:0] read_color;
    wire starting_frame=raw_ce && x==0 && y==240;
    wire render_reset=cold_reset || game_reset || recover || starting_frame;
    // One bank is displayed; at most three others are queued or drawing.
    logic [1:0] display_bank,allocate_bank,active_bank,queue_read,queue_write;
    logic [2:0] queued;
    logic [7:0] queued_y[0:3];
    logic [1:0] queued_bank[0:3];
    logic [8:0] next_build;
    wire [3:0] committed_slots={1'b0,queued}+{3'd0,(busy || done)};
    // Keep the original line0/vblank admission. Further lookahead starts in
    // active display, without taking an early whole-frame snapshot of RAM.
    wire render_start=frame_active && !render_reset && !busy && next_build<240 &&
        committed_slots<3 && (next_build==0 || y<240);
    wire line_flip=frame_flip;
    wire [7:0] render_y=frame_flip ? 8'd239-next_build[7:0] : next_build[7:0];
    wire publication=raw_ce && x==470 && (y<239 || y==255);
    wire [7:0] display_expected_y=y==255 ? 8'd0 : y[7:0]+8'd1;
    wire [7:0] expected_y=frame_flip ? 8'd239-display_expected_y : display_expected_y;
    wire admission=(y<239 && frame_active) || (y==255 && frame_primed);
    wire completed_available=queued!=0 || done;
    wire [7:0] completed_y=queued!=0 ? queued_y[queue_read] : ready_y;
    wire [1:0] completed_bank=queued!=0 ? queued_bank[queue_read] : active_bank;
    wire publish=publication && admission && completed_available && completed_y==expected_y && !render_reset;
    wire missed=publication && admission && !publish && !render_reset;
    wire [8:0] read_x=frame_flip && x<352 ? 9'd351-x : x;
    // Reserve new video service when fewer than two complete future lines remain.
    // An in-flight CPU transaction and every CPU cache hit continue unchanged.
    assign render_urgent=busy && queued<2 && !render_reset;
    spinal_line_renderer #(.QUEUED(1),.LINE_BANKS(4)) renderer(
        .clk(clk),.reset(render_reset),.start(render_start),.publish(1'b0),.flip_line(line_flip),
        .draw_bank(allocate_bank),.show_bank(display_bank),
        .line_y(render_y),.gfxbank(gfxbank),.scrollx1(scrollx1),
        .busy(busy),.done(done),.line_ready(line_ready),.ready_y(ready_y),
        .mem_req(mem_req),.mem_space(mem_space),.mem_address(mem_address),.mem_ready(mem_ready),.mem_data(mem_data),
        .read_x(read_x),.read_color(read_color));
    assign palette_address=read_color;
    always_ff @(posedge clk)begin
        recover<=0;
        if(cold_reset)begin
            epoch_valid<=0;underruns<=0;frame_flip<=0;frame_primed<=0;frame_active<=0;
            display_bank<=0;allocate_bank<=1;active_bank<=0;queue_read<=0;queue_write<=0;queued<=0;next_build<=0;
        end else if(game_reset)begin
            epoch_valid<=0;frame_primed<=0;frame_active<=0;
            display_bank<=0;allocate_bank<=1;queue_read<=0;queue_write<=0;queued<=0;next_build<=0;
        end else if(starting_frame)begin
            frame_flip<=flip_screen;frame_primed<=1;frame_active<=1;
            allocate_bank<=display_bank+2'd1;queue_read<=0;queue_write<=0;queued<=0;next_build<=0;
        end else if(missed)begin
            epoch_valid<=0;recover<=1;underruns<=underruns+1'b1;
            allocate_bank<=display_bank+2'd1;queue_read<=0;queue_write<=0;queued<=0;
            next_build<={1'b0,display_expected_y}+9'd1;
            if(y==255)frame_primed<=0;
        end else if(!recover)begin
            if(render_start)begin
                active_bank<=allocate_bank;allocate_bank<=allocate_bank+2'd1;next_build<=next_build+9'd1;
            end
            if(done)begin
                queued_y[queue_write]<=ready_y;queued_bank[queue_write]<=active_bank;queue_write<=queue_write+2'd1;
            end
            if(publish)begin
                display_bank<=completed_bank;queue_read<=queue_read+2'd1;epoch_valid<=1;
                if(y==255)frame_primed<=0;
            end
            case({done,publish})
                2'b10:queued<=queued+3'd1;
                2'b01:queued<=queued-3'd1;
                default:begin end
            endcase
        end
    end
    always_ff @(posedge clk)begin
        if(cold_reset)begin
            ce_pixel<=0;hs<=0;vs<=0;de<=0;red<=0;green<=0;blue<=0;
            pixel_x<=0;pixel_y<=0;pixel_valid<=0;
        end else begin
            ce_pixel<=raw_ce;
            if(raw_ce)begin
                hs<=raw_hs;vs<=raw_vs;de<=!hblank && !vblank;
                pixel_x<=x;pixel_y<=y;pixel_valid<=epoch_valid && !game_reset;
                if(!hblank && !vblank && epoch_valid && !game_reset)begin
                    red<=palette_data[14:10];green<=palette_data[9:5];blue<=palette_data[4:0];
                end else begin red<=0;green<=0;blue<=0;end
            end
        end
    end
endmodule
