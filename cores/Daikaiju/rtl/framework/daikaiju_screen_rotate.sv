// SPDX-License-Identifier: GPL-2.0-or-later
// Derived from screen_rotate in MiSTer Template's sys/arcade_video.v
// (Copyright (C) 2017-2020 Sorgelig; GNU GPL version 2 or later).
// The transform, framebuffer format/stride, buffer rotation and DDR byte
// mapping follow that donor. This local copy adds reset and an explicit
// completed-frame mailbox with queue-drain publication: independent scanout may repeat, but never rewind
// into the spare slot or select a slot that has not been captured.
module daikaiju_screen_rotate (
	input         RESET,
	input         QUEUE_IDLE,
	input         QUEUE_FAULT,
	input         CLK_VIDEO,
	input         CE_PIXEL,
	input   [7:0] VGA_R,
	input   [7:0] VGA_G,
	input   [7:0] VGA_B,
	input         VGA_HS,
	input         VGA_VS,
	input         VGA_DE,
	input         rotate_ccw,
	input         no_rotate,
	input         flip,
	output        video_rotated,
	output        FB_EN,
	output  [4:0] FB_FORMAT,
	output reg [11:0] FB_WIDTH,
	output reg [11:0] FB_HEIGHT,
	output [31:0] FB_BASE,
	output [13:0] FB_STRIDE,
	input         FB_VBL,
	input         FB_LL,
	output        DDRAM_CLK,
	input         DDRAM_BUSY,
	output  [7:0] DDRAM_BURSTCNT,
	output [28:0] DDRAM_ADDR,
	output [63:0] DDRAM_DIN,
	output  [7:0] DDRAM_BE,
	output        DDRAM_WE,
	output        DDRAM_RD
);

parameter MEM_BASE = 7'b0010010; // byte 0x24000000, three 8 MiB buffers

reg do_flip;
// FB_VBL originates at ascal.o_vbl in clk_hdmi. sys_top samples it once
// into clk_vid; retain a complete local synchronizer before edge decoding.
// No combinational consumer uses the metastability-catching stage.
(* preserve, altera_attribute="-name SYNCHRONIZER_IDENTIFICATION FORCED" *) reg vbl_meta,vbl_sync;
always @(posedge CLK_VIDEO)begin
    if(RESET)begin vbl_meta<=1'b0;vbl_sync<=1'b0;end
    else begin vbl_meta<=FB_VBL;vbl_sync<=vbl_meta;end
end
assign DDRAM_CLK      = CLK_VIDEO;
assign DDRAM_BURSTCNT = 8'd1;
assign DDRAM_ADDR     = {MEM_BASE, i_fb, ram_addr[22:3]};
assign DDRAM_BE       = ram_addr[2] ? 8'hF0 : 8'h0F;
assign DDRAM_DIN      = {ram_data, ram_data};
assign DDRAM_WE       = ram_wr;
assign DDRAM_RD       = 1'b0;
assign FB_EN          = fb_en[2] && display_valid;
assign FB_FORMAT      = 5'b00110;
assign FB_BASE        = {MEM_BASE, o_fb, 23'd0};
assign FB_STRIDE      = stride;
assign video_rotated  = ~no_rotate;

function [1:0] buf_next;
	input [1:0] a,b;
	begin
		buf_next = 1;
		if ((a==0 && b==1) || (a==1 && b==0)) buf_next = 2;
		if ((a==1 && b==2) || (a==2 && b==1)) buf_next = 0;
	end
endfunction

reg [1:0] i_fb, o_fb;
reg [1:0] completed_fb;
reg completed_pending;
reg display_valid;
reg [2:0] fb_en;
reg [11:0] hsz, vsz;
reg [11:0] bwidth;
reg [22:0] bufsize;
reg [22:0] ram_addr, next_addr;
reg [31:0] ram_data;
reg ram_wr;
wire [13:0] stride = {bwidth[11:2], 4'd0};

always @(posedge CLK_VIDEO) begin : framebuffer_control
	reg old_vbl, old_vs;
	if (RESET) begin
		do_flip <= 1'b0;
		FB_WIDTH <= 12'd320;
		FB_HEIGHT <= 12'd240;
		i_fb <= 2'd1;
		o_fb <= 2'd0;
		completed_fb <= 2'd0;
		completed_pending <= 1'b0;
		display_valid <= 1'b0;
		old_vbl <= 1'b0;
		old_vs <= 1'b0;
	end else begin
		do_flip <= no_rotate && flip;
		if (do_flip) begin
			FB_WIDTH <= hsz;
			FB_HEIGHT <= vsz;
		end else begin
			FB_WIDTH <= vsz;
			FB_HEIGHT <= hsz;
		end

		old_vbl <= vbl_sync;
		old_vs <= VGA_VS;
		// A scanout vblank is not evidence that a new source frame exists.
		// Keep the displayed slot until a completed capture is pending. On
		// simultaneous publication/completion retain the newer completion and
		// allocate the writer against the slot the reader is about to own.
		if (~old_vbl & vbl_sync && completed_pending && QUEUE_IDLE && !QUEUE_FAULT) begin
			display_valid <= 1'b1;
			o_fb <= completed_fb;
			completed_pending <= 1'b0;
		end
		if (~old_vs & VGA_VS && fb_en[2]) begin
			completed_fb <= i_fb;
			completed_pending <= 1'b1;
			i_fb <= buf_next(i_fb, (~old_vbl & vbl_sync && completed_pending && QUEUE_IDLE && !QUEUE_FAULT) ? completed_fb : o_fb);
		end
	end
end

always @(posedge CLK_VIDEO) begin : source_geometry
	reg [11:0] hcnt, vcnt;
	reg old_vs, old_de;
	if (RESET) begin
		fb_en <= 3'b000;
		hsz <= 12'd320;
		vsz <= 12'd240;
		bwidth <= 12'd0;
		bufsize <= 23'd0;
		hcnt <= 12'd0;
		vcnt <= 12'd0;
		old_vs <= 1'b0;
		old_de <= 1'b0;
	end else if (CE_PIXEL) begin
		old_vs <= VGA_VS;
		old_de <= VGA_DE;

		hcnt <= hcnt + 1'd1;
		if (~old_de & VGA_DE) begin
			hcnt <= 12'd1;
			vcnt <= vcnt + 1'd1;
		end
		if (old_de & ~VGA_DE) begin
			hsz <= hcnt;
			if (do_flip) bwidth <= hcnt + 2'd3;
		end
		if (~old_vs & VGA_VS) begin
			vsz <= vcnt;
			if (!do_flip) bwidth <= vcnt + 2'd3;
			vcnt <= 12'd0;
			fb_en <= {fb_en[1:0], ~no_rotate | flip};
		end
		if (old_vs & ~VGA_VS) bufsize <= (do_flip ? vsz : hsz) * stride;
	end
end

always @(posedge CLK_VIDEO) begin : framebuffer_writer
	reg [13:0] hcnt;
	reg old_vs, old_de;
	if (RESET) begin
		ram_addr <= 23'd0;
		next_addr <= 23'd0;
		ram_data <= 32'd0;
		ram_wr <= 1'b0;
		hcnt <= 14'd0;
		old_vs <= 1'b0;
		old_de <= 1'b0;
	end else begin
		ram_wr <= 1'b0;
		if (CE_PIXEL && fb_en[2]) begin
			old_vs <= VGA_VS;
			old_de <= VGA_DE;

			if (~old_vs & VGA_VS) begin
				next_addr <= do_flip ? bufsize - 3'd4 :
							 rotate_ccw ? (bufsize - stride) : {vsz - 1'd1, 2'b00};
				hcnt <= rotate_ccw ? 14'd4 : {vsz - 2'd2, 2'b00};
			end
			if (VGA_DE) begin
				ram_wr <= 1'b1;
				ram_data <= {8'd0, VGA_B, VGA_G, VGA_R};
				ram_addr <= next_addr;
				next_addr <= do_flip ? next_addr - 3'd4 :
							 rotate_ccw ? (next_addr - stride) : (next_addr + stride);
			end
			if (old_de & ~VGA_DE & ~do_flip) begin
				next_addr <= rotate_ccw ? (bufsize - stride + hcnt) : hcnt;
				hcnt <= rotate_ccw ? (hcnt + 3'd4) : (hcnt - 3'd4);
			end
		end
	end
end

endmodule
