// Frame-coherent tile, scroll RAM and video attributes for the line renderer.
// The game also clears and rewrites the layer tile RAM (0x100000-0x1027ff) every frame
// (MAME 0.289 write tap: PC 0xccfe zeroes the layer-1 map ~1.4 ms after vblank, PC 0x14f0 refills it);
// fetching it live blanked the top of layer 1 (the attract nebula). The shadow therefore covers
// renderer words 0x0000-0x1fff (tile maps, text map, row scroll, vidattr).
// The game rewrites 0x103000-0x103fff (row scroll and vidattr) from its main loop near line 117
// (MAME 0.289 write tap, PC 0x142e); fetching them live per line split the picture at that line.
// latch (vblank start) copies the 8,192-word window (renderer words 0x0000-0x1fff) into a shadow
// while the renderer is idle; renderer reads of the window return the shadow, so every visible
// line of a frame uses the state of the preceding vblank, as MAME's end-of-frame draw does.
// Reads outside the window and their one-cycle latency are unchanged.
module steel_scroll_shadow(
    input wire clk,reset,latch,render_busy,
    input wire r_en,
    input wire [16:0] r_addr,
    output wire [15:0] r_data,
    output wire ram_en,
    output wire [16:0] ram_addr,
    input wire [15:0] ram_data
);
    reg pending,copying,wr,hit;
    reg [12:0] count,wr_addr;
    wire [15:0] shadow_q,unused;
    wire window=r_addr[16:13]==4'h0;
    assign ram_en=copying || (r_en && !window);
    assign ram_addr=copying ? {4'h0,count} : r_addr;
    assign r_data=hit ? shadow_q : ram_data;
    always @(posedge clk) begin
        wr<=copying && !reset;
        wr_addr<=count;
        if(r_en) hit<=window;
        if(reset) begin
            pending<=1'b1;copying<=1'b0;count<=0; // fill once after reset so the first frame is defined
        end else begin
            if(latch) pending<=1'b1;
            if(copying) begin
                count<=count+13'd1;
                if(count==13'h1fff) copying<=1'b0;
            end else if(pending && !latch && !render_busy) begin
                pending<=1'b0;copying<=1'b1;count<=0;
            end
        end
    end
    steel_dpram8 #(.AW(13)) hi_bank(.clk(clk),.cpu_we(wr),.cpu_addr(wr_addr),.cpu_data(ram_data[15:8]),.cpu_q(unused[15:8]),
        .video_en(r_en && window),.video_addr(r_addr[12:0]),.video_q(shadow_q[15:8]));
    steel_dpram8 #(.AW(13)) lo_bank(.clk(clk),.cpu_we(wr),.cpu_addr(wr_addr),.cpu_data(ram_data[7:0]),.cpu_q(unused[7:0]),
        .video_en(r_en && window),.video_addr(r_addr[12:0]),.video_q(shadow_q[7:0]));
endmodule
