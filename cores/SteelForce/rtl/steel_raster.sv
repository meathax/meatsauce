// Line-locked CRT raster. All totals come from steel_raster_params.vh (500 x 262 pixels at /6 of the
// 45.6 MHz board clock = 15.2 kHz, 58.015 Hz). Every pixel is exactly RASTER_PIXEL_DIV clocks, every
// line exactly RASTER_LINE_CLOCKS, every frame exactly RASTER_FRAME_CLOCKS; HS/VS widths and
// positions are constants. Synthetic sync positions are not PCB measurements.
// Render y+1 during y; prime y0 during final blank line. Late lines blank and recover.
//
// Native 180-degree flip: when flip is latched the renderer is asked for game row 239-d instead of d
// and the line buffer is scanned from x = 365 down to 0, so every output (analog, Direct Video,
// scandoubler, HDMI) sees the flipped picture. Latched with the CRT sync shifts once per frame at the
// final blank line, before display row 0 is primed and after display row 239 has been scanned.
// CRT position: h_shift moves HS and v_shift moves VS (both relative to the picture, in pixels / lines);
// VS stays tied to the HS leading edge. Pixel enable, picture, render timing and the CPU frame
// interrupt (steel_timing) never move. All three inputs at zero reproduce the unadjusted raster.
module steel_raster(
    input wire clk,reset,render_busy,line_ready,
    input wire flip,
    input wire signed [4:0] h_shift,v_shift,
    output wire render_start,render_swap,
    output wire [7:0] render_y,
    output wire scan_en,
    output wire [8:0] scan_x,
    output wire ce_pixel,hs,vs,hblank,vblank,
    output wire [8:0] pixel_x,
    output wire [7:0] pixel_y,
    output wire [31:0] pixel_frame,
    output reg [31:0] missed_lines
);
`include "rtl/steel_raster_params.vh"
    localparam [8:0] H_FIRST=RASTER_H_ACTIVE_FIRST,V_ACTIVE_9=RASTER_V_ACTIVE,HS0=RASTER_HS_START,VS0=RASTER_VS_LINE;
    reg [2:0] div;
    reg [8:0] h,v,job_y;
    reg [31:0] frame,job_frame;
    reg display_valid,vs_state,flip_l;
    reg signed [4:0] hsh_l,vsh_l;
    wire pixel_due=div==RASTER_PIXEL_DIV-1 && !reset;
    wire boundary=pixel_due && h==0;
    wire visible=v<RASTER_V_ACTIVE;
    wire last_line=v==RASTER_VTOTAL-1;
    wire latch_now=boundary && last_line;
    wire flip_eff=latch_now ? flip : flip_l;
    wire [8:0] disp_row=last_line ? 9'd0 : v+9'd1;
    wire line_matches=line_ready && job_y==v && job_frame==frame;
    assign render_swap=boundary && (visible || last_line) && line_ready && !render_busy;
    assign render_start=boundary && (v<RASTER_V_ACTIVE-1 || last_line) && !render_busy && (!line_ready || render_swap);
    assign render_y=flip_eff ? V_ACTIVE_9[7:0]-8'd1-disp_row[7:0] : disp_row[7:0];
    assign scan_en=pixel_due && visible && h>=RASTER_H_ACTIVE_FIRST && h<RASTER_H_ACTIVE_FIRST+RASTER_H_ACTIVE && display_valid;
    wire [8:0] x_in_line=h-H_FIRST;
    assign scan_x=flip_l ? (9'd365-x_in_line) : x_in_line;
    wire [8:0] hs_begin=HS0+{{4{hsh_l[4]}},hsh_l};
    wire [8:0] vs_line=VS0+{{4{vsh_l[4]}},vsh_l};
    reg [1:0] ce_pipe,hs_pipe,vs_pipe,hb_pipe,vb_pipe;
    reg [8:0] x_pipe[0:1];
    reg [7:0] y_pipe[0:1];
    reg [31:0] frame_pipe[0:1];
    assign ce_pixel=ce_pipe[1];
    assign hs=hs_pipe[1];assign vs=vs_pipe[1];
    assign hblank=hb_pipe[1];assign vblank=vb_pipe[1];
    assign pixel_x=x_pipe[1];assign pixel_y=y_pipe[1];assign pixel_frame=frame_pipe[1];
    always @(posedge clk) begin
        if(reset) begin
            div<=0;h<=0;v<=V_ACTIVE_9;frame<=0;job_y<=9'h1ff;job_frame<=0;
            display_valid<=0;vs_state<=0;missed_lines<=0;flip_l<=0;hsh_l<=0;vsh_l<=0;
            ce_pipe<=0;hs_pipe<=3;vs_pipe<=3;hb_pipe<=3;vb_pipe<=3;
            x_pipe[0]<=0;x_pipe[1]<=0;y_pipe[0]<=0;y_pipe[1]<=0;frame_pipe[0]<=0;frame_pipe[1]<=0;
        end else begin
            div<=pixel_due ? 3'd0 : div+3'd1;
            ce_pipe<={ce_pipe[0],pixel_due};
            hs_pipe<={hs_pipe[0],!(h>=hs_begin && h<hs_begin+RASTER_HS_WIDTH)};
            vs_pipe<={vs_pipe[0],!vs_state};
            hb_pipe<={hb_pipe[0],!(h>=RASTER_H_ACTIVE_FIRST && h<RASTER_H_ACTIVE_FIRST+RASTER_H_ACTIVE)};
            vb_pipe<={vb_pipe[0],!visible || !display_valid};
            x_pipe[0]<=x_in_line;x_pipe[1]<=x_pipe[0];
            y_pipe[0]<=v[7:0];y_pipe[1]<=y_pipe[0];frame_pipe[0]<=frame;frame_pipe[1]<=frame_pipe[0];
            if(latch_now) begin flip_l<=flip;hsh_l<=h_shift;vsh_l<=v_shift;end
            if(boundary) begin
                display_valid<=visible && line_matches;
                if(visible && !line_matches)missed_lines<=missed_lines+1'b1;
            end
            if(render_start)begin job_y<=disp_row;job_frame<=last_line ? frame+1'b1 : frame;end
            if(pixel_due) begin
                // VS rises and falls at the HS leading edge of fixed lines: constant sync-to-sync distance.
                if(h==hs_begin-9'd1) begin
                    if(v==vs_line)vs_state<=1;
                    else if(v==vs_line+RASTER_VS_LINES)vs_state<=0;
                end
                if(h==RASTER_HTOTAL-1)begin h<=0;v<=last_line ? 9'd0 : v+9'd1;if(last_line)frame<=frame+1'b1;end
                else h<=h+9'd1;
            end
        end
    end
endmodule
