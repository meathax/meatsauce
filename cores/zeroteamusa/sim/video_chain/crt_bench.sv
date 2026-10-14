// Zero Team output-chain bench: Raiden2_video_timing -> platform px stage -> sys arcade_video
// -> crt_adjust -> platform pixel-enable generator, wired as in ZeroTeam_platform.svh
// (the credits overlay is transparent when inactive and omitted).
// Pattern: r = x[7:0], g = x[8], b = y[7:0], so the visible source columns can be read back.
module chk #(parameter integer HSIZE=0, HOFF=0, VOFF=0, CRT=1, SD=0, NAME=0, DEBUG=0)(input clk, input reset, input report);
    wire ce_pixel,hblank,vblank,hsync,vsync,de; wire [9:0] hpos,vpos,ax; wire [8:0] ay,vv; wire [9:0] hv;
    Raiden2_video_timing t(.clk(clk),.reset(reset),.mode_60hz(1'b0),.ce_pix(ce_pixel),.hpos(hpos),.vpos(vpos),
        .active_x(ax),.active_y(ay),.hblank(hblank),.vblank(vblank),.hsync(hsync),.vsync(vsync),.de(de),
        .h_vis_start(hv),.v_vis_start(vv));
    reg de_d=0; reg [9:0] x_d=0; reg [8:0] y_d=0;
    reg sync_h=0,sync_v=0,sync_vb=1,sync_hb=1;
    reg px_hs=0,px_vs=0,px_hb=1,px_vb=1,px_ce=0; reg [7:0] px_r=0,px_g=0,px_b=0;
    always @(posedge clk) begin
        px_ce<=ce_pixel;
        if(ce_pixel) begin
            de_d<=de; x_d<=hpos; y_d<=vpos[8:0];
            px_r<=x_d[7:0]; px_g<={7'd0,x_d[8]}; px_b<=y_d[7:0];
            px_hb<=reset || (sync_vb ? sync_hb : !de_d); px_vb<=sync_vb;
            px_hs<=sync_h; px_vs<=sync_v;
            sync_h<=hsync; sync_v<=vsync; sync_vb<=vblank; sync_hb<=hblank;
        end
    end
    wire [7:0] vm_r,vm_g,vm_b; wire vm_hs,vm_vs,vm_de,vm_ce,clkv; wire [1:0] sl; wire [21:0] gb; assign gb[20:0]=21'd0;
    arcade_video #(.WIDTH(320),.DW(24),.GAMMA(0)) av(.clk_video(clk),.ce_pix(px_ce),.RGB_in({px_r,px_g,px_b}),
        .HBlank(px_hb),.VBlank(px_vb),.HSync(px_hs),.VSync(px_vs),.CLK_VIDEO(clkv),.CE_PIXEL(vm_ce),
        .VGA_R(vm_r),.VGA_G(vm_g),.VGA_B(vm_b),.VGA_HS(vm_hs),.VGA_VS(vm_vs),.VGA_DE(vm_de),.VGA_SL(sl),
        .fx(3'd0),.forced_scandoubler(SD!=0),.gamma_bus(gb));
    wire crt_on=CRT!=0;
    wire [7:0] crt_r,crt_g,crt_b; wire crt_hs,crt_vs,crt_hb,crt_vb,hs_ref; reg hs_ref_d=0; reg [7:0] read_acc=0;
    wire signed [4:0] hsize=HSIZE; wire [7:0] read_period=8'd96+{{3{hsize[4]}},hsize};
    wire read_tick=({1'b0,read_acc}+9'd8)>={1'b0,read_period};
    always @(posedge clk) begin
        hs_ref_d<=hs_ref;
        if(!crt_on || (hs_ref && !hs_ref_d)) read_acc<=0;
        else if(read_tick) read_acc<=read_acc+8'd8-read_period; else read_acc<=read_acc+8'd8;
    end
    wire signed [8:0] hposition=HOFF; wire signed [5:0] voffset_raw=VOFF;
    wire signed [5:0] voffset=voffset_raw;
    wire output_ce=crt_on ? read_tick : vm_ce;
    crt_adjust #(.VTOTAL(282),.HTOTAL(512),.HPOS_MODE(1)) geometry(.clk(clk),.pxl_cen(vm_ce),.pxl2_cen(output_ce),
        .active(crt_on),.hsize(hsize),.hoffset(hposition),.voffset(voffset),
        .r_in(vm_r),.g_in(vm_g),.b_in(vm_b),.hs_in(vm_hs),.vs_in(vm_vs),.hb_in(!vm_de),.vb_in(px_vb),
        .r_out(crt_r),.g_out(crt_g),.b_out(crt_b),.hs_out(crt_hs),.vs_out(crt_vs),.hb_out(crt_hb),.vb_out(crt_vb),
        .hs_ref_out(hs_ref));
    // The platform feeds the analog pins from crt_* always (bypass mode passes the stream through).
    wire vde = !crt_hb;   // platform: VGA_DE_IN = !crt_hb (RGB, HS and DE share the crt_adjust pipeline)
    wire ohs = crt_hs, ovs = crt_vs;
    // ---- measurements, sampled on the output pixel enable ----
    reg hs_p=0,vs_p=0,vde_p=0;
    reg [31:0] clk_n=0, last_ce=0, last_hs=0, hs_up=0, last_vs=0;
    reg [31:0] pix=0, frame=0, vis_lines=0, vsw_lines=0, since_vis=9999;
    reg [31:0] pmin=9999,pmax=0, wmin=9999,wmax=0, lmin=999999,lmax=0, hsw_min=9999,hsw_max=0, fmin=99999999,fmax=0;
    reg [31:0] vsw_min=9999,vsw_max=0, vl_min=9999,vl_max=0, fxmin=9999,fxmax=0, lxmin=9999,lxmax=0, lv_min=9999,lv_max=0;
    reg [31:0] tsmin=9999,tsmax=0,temin=9999,temax=0; reg [31:0] ts=0,te=0,lines_since_vsfall=0,lines_vs_to_first=0; reg [7:0] fy=0, ly=0; reg [31:0] fymin=9999,fymax=0,lymin=9999,lymax=0; reg first_line=1;
    reg [9:0] fx=0, lx=0; reg got_first=0; wire [31:0] wref = crt_on ? (96+HSIZE)/8 : 12;
    always @(posedge clk) begin
        clk_n<=clk_n+1;
        if(reset) frame<=0;
        else if(output_ce) begin
            hs_p<=ohs; vs_p<=ovs; vde_p<=vde;
            if(vde && vde_p && frame>=2) begin
                if(clk_n-last_ce<wmin) wmin<=clk_n-last_ce;
                if(clk_n-last_ce>wmax) wmax<=clk_n-last_ce;
            end
            last_ce<=clk_n;
            if(DEBUG && frame==3 && vde && vde_p && (clk_n-last_ce)!=wref) $display("DBG %0d width %0d at x=%0d y=%0d",NAME,clk_n-last_ce,{crt_g[0],crt_r},crt_b);
            if(DEBUG>1 && frame==3 && vde && pix<3) $display("DBG %0d px %0d rgb=%0d,%0d,%0d",NAME,pix,crt_r,crt_g,crt_b);
            if(vde) begin
                pix<=pix+1; if(!got_first) fx<={crt_g[0],crt_r}; lx<={crt_g[0],crt_r};
                if(!got_first) begin ts<=clk_n-hs_up; got_first<=1; if(first_line) begin lines_vs_to_first<=lines_since_vsfall; first_line<=0; end end
                te<=clk_n-hs_up;
            end
            if(vde_p && !vde) begin
                if(frame>=2) begin
                    if(pix<pmin) pmin<=pix; if(pix>pmax) pmax<=pix;
                    if(ts<tsmin) tsmin<=ts; if(ts>tsmax) tsmax<=ts;
                    if(te<temin) temin<=te; if(te>temax) temax<=te;
                    if(fx<fxmin) fxmin<=fx; if(fx>fxmax) fxmax<=fx;
                    if(lx<lxmin) lxmin<=lx; if(lx>lxmax) lxmax<=lx;
                end
                pix<=0; got_first<=0; vis_lines<=vis_lines+1; since_vis<=0;
            end
            if(!hs_p && ohs) begin
                if(frame>=2) begin
                    if(clk_n-last_hs<lmin) lmin<=clk_n-last_hs;
                    if(clk_n-last_hs>lmax) lmax<=clk_n-last_hs;
                end
                last_hs<=clk_n; hs_up<=clk_n; since_vis<=since_vis+1; lines_since_vsfall<=lines_since_vsfall+1;
                if(ovs) vsw_lines<=vsw_lines+1;
            end
            if(hs_p && !ohs && frame>=2) begin
                if(clk_n-hs_up<hsw_min) hsw_min<=clk_n-hs_up;
                if(clk_n-hs_up>hsw_max) hsw_max<=clk_n-hs_up;
            end
            if(!vs_p && ovs) begin
                if(frame>=2) begin
                    if(clk_n-last_vs<fmin) fmin<=clk_n-last_vs;
                    if(clk_n-last_vs>fmax) fmax<=clk_n-last_vs;
                    if(vis_lines<vl_min) vl_min<=vis_lines; if(vis_lines>vl_max) vl_max<=vis_lines;
                    if(since_vis<lv_min) lv_min<=since_vis; if(since_vis>lv_max) lv_max<=since_vis;
                end
                if(frame>=2) begin if(lines_vs_to_first<fymin)fymin<=lines_vs_to_first; if(lines_vs_to_first>fymax)fymax<=lines_vs_to_first; end
                first_line<=1; last_vs<=clk_n; vis_lines<=0; frame<=frame+1; vsw_lines<=0;
            end
            if(vs_p && !ovs && frame>=2) begin
                if(vsw_lines<vsw_min) vsw_min<=vsw_lines; if(vsw_lines>vsw_max) vsw_max<=vsw_lines;
            end
            if(vs_p && !ovs) lines_since_vsfall<=0;
        end
        if(report) $display("CFG %0d crt=%0d sd=%0d hsize=%0d hoff=%0d voff=%0d | px/line %0d..%0d tstart %0d..%0d tend %0d..%0d | pxw %0d..%0d | line %0d..%0d | hs %0d..%0d | vslines %0d..%0d | frame %0d..%0d | vislines %0d..%0d | lastvis->VS %0d..%0d | VSfall->firstvis lines %0d..%0d",
            NAME,CRT,SD,HSIZE,HOFF,VOFF,pmin,pmax,tsmin,tsmax,temin,temax,wmin,wmax,lmin,lmax,hsw_min,hsw_max,vsw_min,vsw_max,fmin,fmax,vl_min,vl_max,lv_min,lv_max,fymin,fymax);
    end
endmodule

module tbc;
    reg clk=0; always #5 clk=~clk; reg reset=1; reg report=0;
    chk #(.HSIZE(0),  .HOFF(0),   .VOFF(0),  .CRT(0), .SD(0), .NAME(0)) c0(clk,reset,report);
    chk #(.HSIZE(0),  .HOFF(0),   .VOFF(0),  .CRT(0), .SD(1), .NAME(1)) c1(clk,reset,report);
    chk #(.HSIZE(0),  .HOFF(0),   .VOFF(0),  .CRT(1), .SD(0), .NAME(2)) c2(clk,reset,report);
    chk #(.HSIZE(8),  .HOFF(0),   .VOFF(0),  .CRT(1), .SD(0), .NAME(3)) c3(clk,reset,report);
    chk #(.HSIZE(15), .HOFF(0),   .VOFF(0),  .CRT(1), .SD(0), .NAME(4)) c4(clk,reset,report);
    chk #(.HSIZE(-16),.HOFF(0),   .VOFF(0),  .CRT(1), .SD(0), .NAME(5)) c5(clk,reset,report);
    chk #(.HSIZE(0),  .HOFF(48),  .VOFF(0),  .CRT(1), .SD(0), .NAME(6)) c6(clk,reset,report);
    chk #(.HSIZE(0),  .HOFF(-48), .VOFF(0),  .CRT(1), .SD(0), .NAME(7)) c7(clk,reset,report);
    chk #(.HSIZE(0),  .HOFF(0),   .VOFF(19), .CRT(1), .SD(0), .NAME(8)) c8(clk,reset,report);
    chk #(.HSIZE(0),  .HOFF(0),   .VOFF(-2), .CRT(1), .SD(0), .NAME(9)) c9(clk,reset,report);
    chk #(.HSIZE(15), .HOFF(48),  .VOFF(0),  .CRT(1), .SD(0), .NAME(10)) c10(clk,reset,report);
    chk #(.HSIZE(15), .HOFF(-48), .VOFF(0),  .CRT(1), .SD(0), .NAME(11)) c11(clk,reset,report);
    chk #(.HSIZE(-16),.HOFF(48),  .VOFF(0),  .CRT(1), .SD(0), .NAME(12)) c12(clk,reset,report);
    chk #(.HSIZE(-16),.HOFF(-48), .VOFF(0),  .CRT(1), .SD(0), .NAME(13)) c13(clk,reset,report);
    chk #(.HSIZE(0),  .HOFF(-1),  .VOFF(0),  .CRT(1), .SD(0), .NAME(14)) c14(clk,reset,report);
    initial begin
        repeat(50) @(posedge clk); reset=0;
        repeat(6144*282*6) @(posedge clk);
        report=1; @(posedge clk); report=0; $finish;
    end
endmodule
