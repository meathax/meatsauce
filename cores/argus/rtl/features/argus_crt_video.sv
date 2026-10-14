// Parameters must come from the parent's measured/accepted physical raster.
// This stage belongs before arcade_video; sys/ remains pristine.
module argus_crt_video #(
    parameter integer H_TOTAL=0, V_TOTAL=0, PIXEL_DIV=0,
    parameter integer HPOS_MODE=0
)(
    input logic clk_sys, reset, frame_start, ce_pixel, enable,
    input logic signed [4:0] hsize,
    input logic signed [8:0] hposition,
    input logic signed [5:0] vposition, vsize,
    input logic tube_mode,
    input logic [7:0] r_in,g_in,b_in,
    input logic hs_in,vs_in,hblank_in,vblank_in,
    output wire [7:0] r_out,g_out,b_out,
    output wire hs_out,vs_out,hblank_out,vblank_out,ce_out
);
    initial begin
        if(H_TOTAL<1 || V_TOTAL<1 || PIXEL_DIV<8)
            $error("CRT adapter requires accepted physical totals and integer PIXEL_DIV>=8");
    end
    logic enabled, tube;
    logic signed [4:0] horizontal_size;
    logic signed [8:0] horizontal_position;
    logic signed [5:0] vertical_position,vertical_size;
    always_ff @(posedge clk_sys) begin
        if(reset) begin
            enabled<=0;tube<=0;horizontal_size<=0;horizontal_position<=0;
            vertical_position<=0;vertical_size<=0;
        end else if(frame_start) begin
            enabled<=enable;tube<=tube_mode;horizontal_size<=hsize;
            horizontal_position<=hposition;vertical_position<=vposition;
            // The pinned ring has 46 rows: |vsize| <= 46/2-2 = 21.
            vertical_size<=(vsize>21)?6'sd21:(vsize < -21)?-6'sd21:vsize;
        end
    end
    wire [7:0] vr,vg,vb;
    wire vhs,vvs,vde,vblank,vce,vertical_retimed;
    // Mirror the vertical stage's pixel pipeline. A single register leads
    // its RGB by one native pixel; preserve independently aligned HBlank
    // edges throughout VBlank for scandoubler/HQ2x.
    logic [1:0] native_hblank_pipe=2'b11;
    always_ff @(posedge clk_sys) begin
        if(reset) native_hblank_pipe<=2'b11;
        else if(ce_pixel) native_hblank_pipe<={native_hblank_pipe[0],hblank_in};
    end
    // Reserve the downstream row expansion (256 pixels, at most three
    // extra clocks each), H-position's 16-pixel advance, and four read
    // periods. The vertical writer uses the native pixel period; its
    // DE clamp must also fit the expanded horizontal read before sync.
    localparam integer VERTICAL_FRONT_MIN=16*PIXEL_DIV+256*3+4*(PIXEL_DIV+3);
    // The latest +15-pixel shifted bank boundary must precede DE,
    // with four read periods covering the RAM/output pipeline.
    localparam integer VERTICAL_BACK_MIN=16*PIXEL_DIV+4*(PIXEL_DIV+3);
    argus_crt_vsize #(.RING_LINES(46),.LINE_PX(257),
                      .FRONT_MIN(VERTICAL_FRONT_MIN),.BACK_MIN(VERTICAL_BACK_MIN)) vertical(
        .clk(clk_sys),.pxl_cen(ce_pixel),.active(enabled),.tube_mode(tube),.vsize(vertical_size),
        .r_in(r_in),.g_in(g_in),.b_in(b_in),.hs_in(~hs_in),.vs_in(~vs_in),
        .de_in(!hblank_in && !vblank_in),.vb_in(vblank_in),
        .r_out(vr),.g_out(vg),.b_out(vb),.hs_out(vhs),.vs_out(vvs),.de_out(vde),.vb_out(vblank),.ce_out(vce),.timing_active(vertical_retimed));
    wire reference_hs;
    logic last_hs;
    logic [15:0] read_accumulator;
    wire signed [16:0] period_signed=17'(PIXEL_DIV*4)+{{12{horizontal_size[4]}},horizontal_size};
    wire [16:0] period=period_signed[16:0];
    wire [16:0] accumulator_next={1'b0,read_accumulator}+17'd4;
    wire read_tick=accumulator_next>=period;
    always_ff @(posedge clk_sys) begin
        if(reset) begin last_hs<=0;read_accumulator<=0;end
        else begin
            last_hs<=reference_hs;
            if(reference_hs && !last_hs) read_accumulator<=0;
            else if(read_tick) read_accumulator<=16'(accumulator_next-period);
            else read_accumulator<=accumulator_next[15:0];
        end
    end
    wire read_ce=enabled ? read_tick : vce;
    argus_crt_adjust #(.VTOTAL(V_TOTAL),.HTOTAL(H_TOTAL),.PIXEL_DIV(PIXEL_DIV),.HPOS_MODE(HPOS_MODE)) horizontal(
        .clk(clk_sys),.pxl_cen(vce),.pxl2_cen(read_ce),.active(enabled),.retimed(vertical_retimed),
        .hsize(horizontal_size),.hoffset(horizontal_position),.voffset(vertical_position),
        .r_in(vr),.g_in(vg),.b_in(vb),.hs_in(~vhs),.vs_in(~vvs),
        .hb_in(enabled ? !vde : native_hblank_pipe[1]),.vb_in(vblank),
        .r_out(r_out),.g_out(g_out),.b_out(b_out),.hs_out(hs_out),.vs_out(vs_out),
        .hb_out(hblank_out),.vb_out(vblank_out),.hs_ref_out(reference_hs));
    assign ce_out=read_ce;
endmodule
`include "argus_crt_adjust.sv"
`include "argus_crt_vsize.sv"
