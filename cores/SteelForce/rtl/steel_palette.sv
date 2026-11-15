// CPU byte writes mirror the board palette (live banks). Scanout reads a display copy that
// latch (vblank start) refreshes from the live banks, so a whole frame uses one palette state
// as MAME's end-of-frame draw does; the game writes the palette throughout the frame and live
// lookup split colours at the write line. Common clk, one-cycle lookup. Explicit forwarding
// defines a CPU write to the address being copied in the same cycle.
module steel_palette(
    input wire clk,reset,latch,
    input wire cpu_we,
    input wire [10:0] cpu_addr,
    input wire [15:0] cpu_data,
    input wire [1:0] cpu_lanes,
    input wire pixel_en,
    input wire [10:0] pixel_index,
    output reg rgb_valid,
    output wire [23:0] rgb
);
    wire [15:0] live_q,q,unused_live,unused_show;
    reg pending,copying,wr;
    reg [10:0] count,wr_addr;
    reg [1:0] forward_lanes;
    reg [15:0] forward_data;
    steel_dpram8 #(.AW(11)) hi_bank(.clk(clk),.cpu_we(cpu_we && cpu_lanes[1]),
        .cpu_addr(cpu_addr),.cpu_data(cpu_data[15:8]),.cpu_q(unused_live[15:8]),
        .video_en(copying),.video_addr(count),.video_q(live_q[15:8]));
    steel_dpram8 #(.AW(11)) lo_bank(.clk(clk),.cpu_we(cpu_we && cpu_lanes[0]),
        .cpu_addr(cpu_addr),.cpu_data(cpu_data[7:0]),.cpu_q(unused_live[7:0]),
        .video_en(copying),.video_addr(count),.video_q(live_q[7:0]));
    wire [15:0] copy_data={forward_lanes[1] ? forward_data[15:8] : live_q[15:8],
                           forward_lanes[0] ? forward_data[7:0] : live_q[7:0]};
    steel_dpram8 #(.AW(11)) show_hi(.clk(clk),.cpu_we(wr),.cpu_addr(wr_addr),.cpu_data(copy_data[15:8]),.cpu_q(unused_show[15:8]),
        .video_en(pixel_en),.video_addr(pixel_index),.video_q(q[15:8]));
    steel_dpram8 #(.AW(11)) show_lo(.clk(clk),.cpu_we(wr),.cpu_addr(wr_addr),.cpu_data(copy_data[7:0]),.cpu_q(unused_show[7:0]),
        .video_en(pixel_en),.video_addr(pixel_index),.video_q(q[7:0]));
    always @(posedge clk) begin
        rgb_valid<=pixel_en && !reset;
        wr<=copying && !reset;
        wr_addr<=count;
        forward_lanes<=copying && cpu_we && cpu_addr==count ? cpu_lanes : 2'b0;
        forward_data<=cpu_data;
        if(reset) begin
            pending<=1'b1;copying<=1'b0;count<=0;
        end else begin
            if(latch) pending<=1'b1;
            if(copying) begin
                count<=count+11'd1;
                if(count==11'h7ff) copying<=1'b0;
            end else if(pending && !latch) begin
                pending<=1'b0;copying<=1'b1;count<=0;
            end
        end
    end
    // Palette is BGR555. Replicate high bits to cover the full eight-bit range.
    assign rgb={{q[4:0],q[4:2]}, {q[9:5],q[9:7]}, {q[14:10],q[14:12]}};
endmodule
