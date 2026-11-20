// SPDX-License-Identifier: BSD-3-Clause
// Presentation bridge: preserve the native 400-line/60-Hz sequence while
// reading active pixels on a uniform 12-MHz cadence (96 MHz / 8). Native CPU,
// GPU and IRQ timing remain at the MAME raster. Blank porch widths are adapted
// to 500 pixels per line; this is not evidence of the original PCB sync timing.
module gs_video_retime(
    input wire source_clk,video_clk,reset,ce_in,
    input wire [23:0] rgb_in,input wire hs_in,vs_in,hb_in,vb_in,
    output reg ce_out,output reg [23:0] rgb_out,
    output reg hs_out,vs_out,hb_out,vb_out,output reg fault
);
    (* ramstyle="M10K, no_rw_check" *) reg [23:0] pixels[0:1279];
    reg [23:0] pixel_q;
    reg [1:0] bank;
    reg [8:0] write_x;
    reg old_hs,primed,line_vs,line_vb;
    // Eight descriptors; Gray pointers are the only continuously changing CDC
    // signals. Descriptor data stays stable until its consumer retires it.
    (* ramstyle="M10K, no_rw_check" *) reg [4:0] rows[0:7]; // valid, VS, VB, bank
    reg [3:0] wp,wgray,rp,rgray;
    (* altera_attribute="-name SYNCHRONIZER_IDENTIFICATION FORCED" *) reg [3:0] rgray_s1,rgray_s2,wgray_s1,wgray_s2;
    wire [3:0] wp_next=wp+1'b1;
    wire [3:0] wgray_next=(wp_next>>1)^wp_next;
    wire full=wgray_next==(rgray_s2^4'b1100);
    reg source_fault;
    wire [10:0] pixel_write_address=bank*11'd320+write_x;
    // Keep the mixed-clock RAM ports independent of the control/reset logic.
    // The output cadence leaves seven clocks to prefetch the current pixel.
    always @(posedge source_clk)
        if(ce_in && !hb_in && !vb_in && write_x<320)
            pixels[pixel_write_address]<=rgb_in;
    always @(posedge source_clk)begin
        rgray_s1<=rgray;rgray_s2<=rgray_s1;
        old_hs<=hs_in;
        if(hs_in && !old_hs)begin
            if(primed)begin
                if(!full)begin
                    rows[wp[2:0]]<={write_x==320,line_vs,line_vb,bank};
                    wp<=wp_next;wgray<=wgray_next;
                end else source_fault<=1;
                bank<=bank+1'b1;
            end
            primed<=1;write_x<=0;line_vs<=vs_in;line_vb<=vb_in;
        end
        if(ce_in && !hb_in && !vb_in)begin
            if(write_x<320)begin write_x<=write_x+1'b1;end
            else source_fault<=1;
        end
        if(reset)begin
            wp<=0;wgray<=0;bank<=0;write_x<=0;old_hs<=0;primed<=0;
            line_vs<=0;line_vb<=1;source_fault<=0;rgray_s1<=0;rgray_s2<=0;
        end
    end
    function automatic [3:0] ungray(input [3:0] g);
        integer i;
        begin ungray[3]=g[3];for(i=2;i>=0;i=i-1)ungray[i]=ungray[i+1]^g[i];end
    endfunction
    wire [3:0] available=ungray(wgray_s2)-rp;
    wire [3:0] rp_next=rp+1'b1;
    reg started;
    reg [2:0] phase;
    reg [8:0] x;
    reg [4:0] row;
    // Registered dual-clock descriptor read removes the source-to-video mux
    // from the line-boundary decode. The Gray-pointer delay admits only
    // completed descriptors; rp stays fixed for the entire output line.
    reg [4:0] row_prefetch;
    always @(posedge video_clk) row_prefetch<=rows[rp[2:0]];
    wire [8:0] pixel_read_x=x>=94 && x<414 ? x-9'd94 : 9'd0;
    wire [10:0] pixel_read_address=row[1:0]*11'd320+pixel_read_x;
    always @(posedge video_clk) pixel_q<=pixels[pixel_read_address];
    (* altera_attribute="-name SYNCHRONIZER_IDENTIFICATION FORCED" *) reg source_fault_s1,source_fault_s2;
    always @(posedge video_clk)begin
        wgray_s1<=wgray;wgray_s2<=wgray_s1;
        source_fault_s1<=source_fault;source_fault_s2<=source_fault_s1;
        fault<=fault || source_fault_s2;
        phase<=phase+1'b1;ce_out<=phase==7;
        if(!started && available>=2)started<=1;
        if(phase==7)begin
            x<=x==499 ? 9'd0 : x+1'b1;
            hs_out<=x<32;
            if(x==0 && started)begin
                if(available!=0)begin
                    row<=row_prefetch;rp<=rp_next;rgray<=(rp_next>>1)^rp_next;
                    vs_out<=row_prefetch[3];vb_out<=row_prefetch[2];
                    if(available>3)fault<=1;
                end else begin row<=5'b00100;vb_out<=1;fault<=1;end
            end
            hb_out<=x<94 || x>=414;
            rgb_out<=started && row[4] && !row[2] && x>=94 && x<414 ?
                pixel_q : 24'b0;
        end
        if(reset)begin
            rp<=0;rgray<=0;wgray_s1<=0;wgray_s2<=0;phase<=0;x<=0;started<=0;row<=5'b00100;
            ce_out<=0;rgb_out<=0;hs_out<=0;vs_out<=0;hb_out<=1;vb_out<=1;fault<=0;
            source_fault_s1<=0;source_fault_s2<=0;
        end
    end
endmodule
