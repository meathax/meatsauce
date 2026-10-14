//============================================================================
//  System 32 VRAM: 128KB (64K x 16), true dual port.
//  Port A: CPU (0x300000-0x31ffff window).  Port B: video fetch.
//  Mirrors the real board's dual-port DRAM array (DESIGN.md §6.1).
//  Also latches the video register file ($31FF00-$31FFFF) into discrete
//  registers for the render pipeline (Appendix C).
//============================================================================

module s32_vram (
    input             clk,
    input             vid_clk,

    // CPU port
    input             cpu_we,
    input      [15:0] cpu_addr,     // word address
    input      [15:0] cpu_wdata,
    input       [1:0] cpu_be,
    output     [15:0] cpu_rdata,

    // video fetch port (read only)
    input      [15:0] vid_addr,
    output     [15:0] vid_rdata,

    // latched video registers (Appendix C) — subset the pipeline consumes
    output reg [15:0] reg_1ff00,    // width/bitmap fmt/tilebank lsb/flips
    output reg [15:0] reg_1ff02,    // enables / clip modes
    output reg [15:0] reg_1ff04,    // rowscroll/rowselect ctl
    output reg [15:0] reg_1ff06,    // clip selects
    output reg [15:0] reg_scrollfracx [0:1], // $1FF10/$1FF18 (bits 15:8)
    output reg [15:0] reg_scrollfracy [0:1], // $1FF14/$1FF1C (bits 15:9)
    output reg [15:0] reg_scrollx [0:3],  // $1FF12/$1FF1A/$1FF22/$1FF2A
    output reg [15:0] reg_scrolly [0:3],  // $1FF16/$1FF1E/$1FF26/$1FF2E
    output reg [15:0] reg_offsx   [0:3],  // $1FF30/34/38/3C
    output reg [15:0] reg_offsy   [0:3],  // $1FF32/36/3A/3E
    output reg [15:0] reg_pages   [0:7],  // $1FF40-$1FF4E (2 words per layer)
    output reg [15:0] reg_zoomx   [0:1],  // $1FF50/$1FF54 (NBG0/1)
    output reg [15:0] reg_zoomy   [0:1],  // $1FF52/$1FF56
    output reg [15:0] reg_1ff5c,    // text page/bank
    output reg [15:0] reg_1ff5e,    // backdrop
    output reg [15:0] reg_clips [0:19], // $1FF60-$1FF86 five clip rects
    output reg [15:0] reg_1ff88,    // bitmap xscroll
    output reg [15:0] reg_1ff8a,    // bitmap yscroll
    output reg [15:0] reg_1ff8c,    // bitmap palette base
    output reg [15:0] reg_1ff8e     // per-layer disable set 2
);

// Register shadows must observe the same byte enables as the backing VRAM.
// Byte writes are common on the V60 bus; replacing the disabled lane with
// cpu_wdata corrupts scroll, clip, zoom, and layer-control state.
function automatic [15:0] merge_be(
    input [15:0] old_value,
    input [15:0] new_value,
    input  [1:0] be
);
    merge_be = {be[1] ? new_value[15:8] : old_value[15:8],
                be[0] ? new_value[7:0]  : old_value[7:0]};
endfunction

// Keep clip-register indices explicitly five bits wide.  The low block maps
// to entries 0..15 and the high block maps to entries 16..19; expressing the
// leading zero only inside the array subscript let older Quartus versions
// reduce the low expression to four bits and warn that it could not address
// the complete 20-word array.
wire [4:0] clip_index_lo = {1'b0, cpu_addr[3:0]};
wire [4:0] clip_index_hi = {3'b100, cpu_addr[1:0]};

s32_big_dpram #(
    .ADDR_WIDTH(16),
    .NUM_WORDS(65536),
    .MIXED_RDW_MODE("DONT_CARE"),
    .PORT_B_READ_ONLY(1'b1)
) video_ram (
    .clock_a(clk), .address_a(cpu_addr),
    .data_a(cpu_wdata), .byteena_a(cpu_be),
    .wren_a(cpu_we), .q_a(cpu_rdata),
    .clock_b(vid_clk), .address_b(vid_addr),
    .data_b(16'h0000), .byteena_b(2'b00),
    .wren_b(1'b0), .q_b(vid_rdata)
);

always @(posedge clk) begin
    // register shadow (word writes into $1FF00 region)
    if (cpu_we && (cpu_addr >= 16'hFF80)) begin
        case (cpu_addr[6:0])
            7'h00: reg_1ff00 <= merge_be(reg_1ff00, cpu_wdata, cpu_be);
            7'h01: reg_1ff02 <= merge_be(reg_1ff02, cpu_wdata, cpu_be);
            7'h02: reg_1ff04 <= merge_be(reg_1ff04, cpu_wdata, cpu_be);
            7'h03: reg_1ff06 <= merge_be(reg_1ff06, cpu_wdata, cpu_be);
            7'h08: reg_scrollfracx[0] <= merge_be(reg_scrollfracx[0], cpu_wdata, cpu_be);
            7'h09: reg_scrollx[0] <= merge_be(reg_scrollx[0], cpu_wdata, cpu_be);
            7'h0a: reg_scrollfracy[0] <= merge_be(reg_scrollfracy[0], cpu_wdata, cpu_be);
            7'h0b: reg_scrolly[0] <= merge_be(reg_scrolly[0], cpu_wdata, cpu_be);
            7'h0c: reg_scrollfracx[1] <= merge_be(reg_scrollfracx[1], cpu_wdata, cpu_be);
            7'h0d: reg_scrollx[1] <= merge_be(reg_scrollx[1], cpu_wdata, cpu_be);
            7'h0e: reg_scrollfracy[1] <= merge_be(reg_scrollfracy[1], cpu_wdata, cpu_be);
            7'h0f: reg_scrolly[1] <= merge_be(reg_scrolly[1], cpu_wdata, cpu_be);
            7'h11: reg_scrollx[2] <= merge_be(reg_scrollx[2], cpu_wdata, cpu_be);
            7'h13: reg_scrolly[2] <= merge_be(reg_scrolly[2], cpu_wdata, cpu_be);
            7'h15: reg_scrollx[3] <= merge_be(reg_scrollx[3], cpu_wdata, cpu_be);
            7'h17: reg_scrolly[3] <= merge_be(reg_scrolly[3], cpu_wdata, cpu_be);
            7'h18: reg_offsx[0] <= merge_be(reg_offsx[0], cpu_wdata, cpu_be);
            7'h19: reg_offsy[0] <= merge_be(reg_offsy[0], cpu_wdata, cpu_be);
            7'h1a: reg_offsx[1] <= merge_be(reg_offsx[1], cpu_wdata, cpu_be);
            7'h1b: reg_offsy[1] <= merge_be(reg_offsy[1], cpu_wdata, cpu_be);
            7'h1c: reg_offsx[2] <= merge_be(reg_offsx[2], cpu_wdata, cpu_be);
            7'h1d: reg_offsy[2] <= merge_be(reg_offsy[2], cpu_wdata, cpu_be);
            7'h1e: reg_offsx[3] <= merge_be(reg_offsx[3], cpu_wdata, cpu_be);
            7'h1f: reg_offsy[3] <= merge_be(reg_offsy[3], cpu_wdata, cpu_be);
            7'h20: reg_pages[0] <= merge_be(reg_pages[0], cpu_wdata, cpu_be);
            7'h21: reg_pages[1] <= merge_be(reg_pages[1], cpu_wdata, cpu_be);
            7'h22: reg_pages[2] <= merge_be(reg_pages[2], cpu_wdata, cpu_be);
            7'h23: reg_pages[3] <= merge_be(reg_pages[3], cpu_wdata, cpu_be);
            7'h24: reg_pages[4] <= merge_be(reg_pages[4], cpu_wdata, cpu_be);
            7'h25: reg_pages[5] <= merge_be(reg_pages[5], cpu_wdata, cpu_be);
            7'h26: reg_pages[6] <= merge_be(reg_pages[6], cpu_wdata, cpu_be);
            7'h27: reg_pages[7] <= merge_be(reg_pages[7], cpu_wdata, cpu_be);
            7'h28: reg_zoomx[0] <= merge_be(reg_zoomx[0], cpu_wdata, cpu_be);
            7'h29: reg_zoomy[0] <= merge_be(reg_zoomy[0], cpu_wdata, cpu_be);
            7'h2a: reg_zoomx[1] <= merge_be(reg_zoomx[1], cpu_wdata, cpu_be);
            7'h2b: reg_zoomy[1] <= merge_be(reg_zoomy[1], cpu_wdata, cpu_be);
            7'h2e: reg_1ff5c <= merge_be(reg_1ff5c, cpu_wdata, cpu_be);
            7'h2f: reg_1ff5e <= merge_be(reg_1ff5e, cpu_wdata, cpu_be);
            7'h30, 7'h31, 7'h32, 7'h33, 7'h34, 7'h35, 7'h36, 7'h37,
            7'h38, 7'h39, 7'h3a, 7'h3b, 7'h3c, 7'h3d, 7'h3e, 7'h3f:
                reg_clips[clip_index_lo] <=
                    merge_be(reg_clips[clip_index_lo], cpu_wdata, cpu_be);
            7'h40, 7'h41, 7'h42, 7'h43:                // 5th rect (bitmap)
                // Fifth rectangle occupies clip words 16..19. The former
                // four-bit concatenation decoded as 8..11 and overwrote rect 3.
                reg_clips[clip_index_hi] <=
                    merge_be(reg_clips[clip_index_hi], cpu_wdata, cpu_be);
            7'h44: reg_1ff88 <= merge_be(reg_1ff88, cpu_wdata, cpu_be);
            7'h45: reg_1ff8a <= merge_be(reg_1ff8a, cpu_wdata, cpu_be);
            7'h46: reg_1ff8c <= merge_be(reg_1ff8c, cpu_wdata, cpu_be);
            7'h47: reg_1ff8e <= merge_be(reg_1ff8e, cpu_wdata, cpu_be);
            default: ;
        endcase
    end
end

integer __vr;
initial begin
    // register file powers up 0 (Cyclone V flops); $1FF00 gets the MAME
    // device_start default. Eliminates X-poisoning of the render pipeline's
    // address arithmetic before the game programs the registers.
    reg_1ff00 = 16'h8000;   // 416-wide default (MAME device_start)
    reg_1ff02 = 0; reg_1ff04 = 0; reg_1ff06 = 0;
    reg_1ff5c = 0; reg_1ff5e = 0;
    reg_1ff88 = 0; reg_1ff8a = 0; reg_1ff8c = 0; reg_1ff8e = 0;
    for (__vr = 0; __vr < 4; __vr = __vr + 1) begin
        reg_scrollx[__vr] = 0; reg_scrolly[__vr] = 0;
        reg_offsx[__vr] = 0;   reg_offsy[__vr] = 0;
    end
    for (__vr = 0; __vr < 8; __vr = __vr + 1) reg_pages[__vr] = 0;
    for (__vr = 0; __vr < 2; __vr = __vr + 1) begin
        reg_scrollfracx[__vr] = 0;
        reg_scrollfracy[__vr] = 0;
        reg_zoomx[__vr] = 16'h0200;  // 1.0 (neutral zoom)
        reg_zoomy[__vr] = 16'h0200;
    end
    for (__vr = 0; __vr < 20; __vr = __vr + 1) reg_clips[__vr] = 0;
end

endmodule
