// SPDX-License-Identifier: GPL-3.0-or-later
// HDMI display tap; native video and the board's pixel clock are untouched.
module osman_rotation (
    input wire clk, reset, ce_pix, enable, ccw,
    input wire [7:0] red, green, blue,
    input wire hs, vs, de,
    output wire FB_EN,
    output wire [4:0] FB_FORMAT,
    output wire [11:0] FB_WIDTH, FB_HEIGHT,
    output wire [31:0] FB_BASE,
    output wire [13:0] FB_STRIDE,
    input wire FB_VBL, FB_LL,
    output wire FB_FORCE_BLANK,
    output wire DDRAM_CLK,
    input wire DDRAM_BUSY,
    output wire [7:0] DDRAM_BURSTCNT,
    output wire [28:0] DDRAM_ADDR,
    output wire [63:0] DDRAM_DIN,
    output wire [7:0] DDRAM_BE,
    output wire DDRAM_RD, DDRAM_WE
);
    wire raw_fb_en, raw_we;
    wire [28:0] raw_addr;
    wire [63:0] raw_data;
    wire [7:0] raw_be;
    reg previous_vs, direction;
    wire frame_boundary = ce_pix && vs && !previous_vs;
    // The producer initializes its addresses on this same edge. Feed the
    // selected direction now, then retain it for all pixels of the new frame.
    wire selected_direction = frame_boundary ? ccw : direction;
    wire direction_change = frame_boundary && ccw != direction;
    always @(posedge clk) begin
        if (reset) begin previous_vs<=0; direction<=0; end
        else if (ce_pix) begin
            previous_vs<=vs;
            if (vs && !previous_vs) direction<=ccw;
        end
    end
    screen_rotate u_rotate (
        .CLK_VIDEO(clk),.CE_PIXEL(ce_pix),.VGA_R(red),.VGA_G(green),.VGA_B(blue),
        .VGA_HS(hs),.VGA_VS(vs),.VGA_DE(de),.rotate_ccw(selected_direction),.no_rotate(!enable),
        .flip(1'b0),.video_rotated(),.FB_EN(raw_fb_en),.FB_FORMAT(FB_FORMAT),
        .FB_WIDTH(FB_WIDTH),.FB_HEIGHT(FB_HEIGHT),.FB_BASE(FB_BASE),.FB_STRIDE(FB_STRIDE),
        .FB_VBL(FB_VBL),.FB_LL(FB_LL),.DDRAM_CLK(),.DDRAM_BUSY(1'b0),
        .DDRAM_BURSTCNT(),.DDRAM_ADDR(raw_addr),.DDRAM_DIN(raw_data),.DDRAM_BE(raw_be),
        .DDRAM_WE(raw_we),.DDRAM_RD()
    );
    // The pinned rotator emits pixel strobes without honoring DDRAM_BUSY.
    // Queue address/data/byte enable together and hold the request until accepted.
    reg [28:0] address_fifo [0:255];
    reg [31:0] data_fifo [0:255];
    reg [7:0] be_fifo [0:255];
    reg [7:0] read_pointer, write_pointer;
    reg [8:0] count;
    reg overflow;
    reg [1:0] warmup_frames, frame_buffer, tail_buffer;
    reg frame_open, frame_seen, completing;
    reg [8:0] tail_count;
    reg [3:0] fresh_buffers;
    wire take = DDRAM_WE && !DDRAM_BUSY;
    wire push = raw_we && enable && !overflow;
    wire put = push && (count<9'd256 || take);
    assign DDRAM_CLK=clk;
    assign DDRAM_BURSTCNT=8'd1;
    assign DDRAM_ADDR=address_fifo[read_pointer];
    assign DDRAM_DIN={data_fifo[read_pointer],data_fifo[read_pointer]};
    assign DDRAM_BE=be_fifo[read_pointer];
    assign DDRAM_WE=enable && !reset && count!=0;
    assign DDRAM_RD=1'b0;
    assign FB_EN=enable && !reset && raw_fb_en && fresh_buffers[FB_BASE[24:23]];
    assign FB_FORCE_BLANK=enable && overflow;
    always @(posedge clk) begin
        if (reset || !enable) begin
            count<=0; read_pointer<=0; write_pointer<=0; overflow<=0;
        end else begin
            if (push && !put) overflow<=1;
            if (put) begin
                address_fifo[write_pointer]<=raw_addr;
                data_fifo[write_pointer]<=raw_data[31:0];
                be_fifo[write_pointer]<=raw_be;
                write_pointer<=write_pointer+1'b1;
            end
            if (take) read_pointer<=read_pointer+1'b1;
            case ({put,take})
                2'b10: count<=count+1'b1;
                2'b01: count<=count-1'b1;
                default: ;
            endcase
        end
    end
    // The pinned producer has no reset port. Its enable/geometry pipeline
    // settles over three VS boundaries, even after a warm reset. After that,
    // qualify each buffer only after a whole new frame and its queued writes
    // have completed; never expose old DDR contents as a freshly reset image.
    always @(posedge clk) begin
        if (reset || !enable) begin
            warmup_frames<=0; frame_open<=0; frame_seen<=0;
            frame_buffer<=0; tail_buffer<=0; tail_count<=0;
            completing<=0; fresh_buffers<=0;
        end else begin
            if (!overflow && completing && take) begin
                if (tail_count==1) begin
                    fresh_buffers[tail_buffer]<=1;
                    completing<=0; tail_count<=0;
                end else tail_count<=tail_count-1'b1;
            end
            if (frame_boundary) begin
                // Old-orientation buffers must not qualify the new direction.
                if (direction_change) begin
                    fresh_buffers<=0; completing<=0; tail_count<=0;
                end else if (!overflow && frame_open && frame_seen) begin
                    if (count==0 || (take && count==1)) begin
                        fresh_buffers[frame_buffer]<=1;
                        completing<=0; tail_count<=0;
                    end else begin
                        tail_buffer<=frame_buffer;
                        tail_count<=count-(take ? 9'd1 : 9'd0);
                        completing<=1;
                    end
                end
                if (warmup_frames!=3) warmup_frames<=warmup_frames+1'b1;
                frame_open<=warmup_frames>=2;
                frame_seen<=0;
            end
            if (put && frame_open) begin
                if (!frame_seen) frame_buffer<=raw_addr[21:20];
                frame_seen<=1;
            end
        end
    end
endmodule
