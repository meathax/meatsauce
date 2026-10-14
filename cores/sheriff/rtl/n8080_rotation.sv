// SPDX-License-Identifier: GPL-2.0-or-later
// MiSTer screen_rotate supplies the pixel mapping and framebuffer ownership.
// Buffer its pixel strobes until the platform DDR port accepts each write.
module n8080_rotation #(
    parameter MEM_BASE = 7'b0010010,
    parameter FIFO_BITS = 9
) (
    input CLK_VIDEO, RESET, CE_PIXEL,
    input [7:0] VGA_R, VGA_G, VGA_B,
    input VGA_HS, VGA_VS, VGA_DE,
    input rotate_ccw, no_rotate, flip,
    output video_rotated, FB_EN,
    output [4:0] FB_FORMAT,
    output [11:0] FB_WIDTH, FB_HEIGHT,
    output [31:0] FB_BASE,
    output [13:0] FB_STRIDE,
    input FB_VBL, FB_LL,
    output DDRAM_CLK,
    input DDRAM_BUSY,
    output [7:0] DDRAM_BURSTCNT,
    output [28:0] DDRAM_ADDR,
    output [63:0] DDRAM_DIN,
    output [7:0] DDRAM_BE,
    output DDRAM_WE, DDRAM_RD,
    output reg overflow = 0
);
    wire [28:0] pixel_address;
    wire [63:0] pixel_data;
    wire [7:0] pixel_be;
    wire pixel_write;
    screen_rotate #(.MEM_BASE(MEM_BASE)) mapper (
        .CLK_VIDEO(CLK_VIDEO), .CE_PIXEL(CE_PIXEL),
        .VGA_R(VGA_R), .VGA_G(VGA_G), .VGA_B(VGA_B),
        .VGA_HS(VGA_HS), .VGA_VS(VGA_VS), .VGA_DE(VGA_DE),
        .rotate_ccw(rotate_ccw), .no_rotate(no_rotate), .flip(flip),
        .video_rotated(video_rotated), .FB_EN(FB_EN),
        .FB_FORMAT(FB_FORMAT), .FB_WIDTH(FB_WIDTH), .FB_HEIGHT(FB_HEIGHT),
        .FB_BASE(FB_BASE), .FB_STRIDE(FB_STRIDE), .FB_VBL(FB_VBL), .FB_LL(FB_LL),
        .DDRAM_CLK(), .DDRAM_BUSY(1'b0), .DDRAM_BURSTCNT(),
        .DDRAM_ADDR(pixel_address), .DDRAM_DIN(pixel_data), .DDRAM_BE(pixel_be),
        .DDRAM_WE(pixel_write), .DDRAM_RD()
    );

    // 512 words cover 100 us of continuous 5.04 MHz native pixels.
    // RAM has a synchronous read into the held Avalon transaction register.
    localparam DEPTH = 1 << FIFO_BITS;
    reg [61:0] queue [0:DEPTH-1];
    reg [FIFO_BITS-1:0] write_pointer = 0, read_pointer = 0;
    reg [FIFO_BITS:0] count = 0;
    reg [61:0] head;
    reg head_valid = 0;
    wire enqueue = pixel_write && count < DEPTH;
    wire prefetch = !head_valid && count != 0;

    assign DDRAM_CLK = CLK_VIDEO;
    assign DDRAM_BURSTCNT = 8'd1;
    assign DDRAM_ADDR = head[61:33];
    assign DDRAM_BE = head[32] ? 8'hf0 : 8'h0f;
    assign DDRAM_DIN = {head[31:0], head[31:0]};
    assign DDRAM_WE = head_valid && !RESET;
    assign DDRAM_RD = 1'b0;

    always @(posedge CLK_VIDEO) begin
        if (RESET) begin
            write_pointer <= 0;
            read_pointer <= 0;
            count <= 0;
            head_valid <= 0;
            overflow <= 0;
        end else begin
            if (pixel_write && !enqueue) overflow <= 1;
            if (enqueue) begin
                queue[write_pointer] <= {pixel_address, pixel_be[7], pixel_data[31:0]};
                write_pointer <= write_pointer + 1'b1;
            end
            if (prefetch) begin
                head <= queue[read_pointer];
                read_pointer <= read_pointer + 1'b1;
                head_valid <= 1;
            end else if (head_valid && !DDRAM_BUSY) head_valid <= 0;
            case ({enqueue, prefetch})
                2'b10: count <= count + 1'b1;
                2'b01: count <= count - 1'b1;
                default: ;
            endcase
        end
    end
endmodule
