// SPDX-License-Identifier: GPL-2.0-or-later
// Derived from DEC8 rtl/d8_screen_rotate.sv; see docs/ROTATION_OUTPUT.md.
//============================================================================
//
//  Copyright (C) 2017-2020 Sorgelig
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//
//  This program is distributed in the hope that it will be useful, but WITHOUT
//  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
//  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
//  more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//
//============================================================================

//////////////////////////////////////////////////////////
// DW:
//  6 : 2R 2G 2B
//  8 : 3R 3G 2B
//  9 : 3R 3G 3B
// 12 : 4R 4G 4B
// 24 : 8R 8G 8B

module arblst_screen_rotate
(
	input         CLK_VIDEO,
	input         reset,
	output reg    overflow=0,
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

	output            FB_EN,
	output      [4:0] FB_FORMAT,
	output reg [11:0] FB_WIDTH,
	output reg [11:0] FB_HEIGHT,
	output     [31:0] FB_BASE,
	output     [13:0] FB_STRIDE,
	input             FB_VBL,
	input             FB_LL,

	output        DDRAM_CLK,
	input         DDRAM_BUSY,
	output  [7:0] DDRAM_BURSTCNT,
	output [28:0] DDRAM_ADDR,
	output [63:0] DDRAM_DIN,
	output  [7:0] DDRAM_BE,
	output        DDRAM_WE,
	output        DDRAM_RD
);

// Local reset, bypass and orientation changes invalidate the capture epoch.
// A presented Avalon write remains asserted until accepted, even if BUSY spans
// the request. Only unpublished queued work may be discarded after that edge.
reg [2:0] mode_history=3'd0;
reg quiescing=0;
wire mode_change=mode_history!={rotate_ccw,no_rotate,flip};
wire stop_capture=reset || mode_change || quiescing || inactive;
wire flush=stop_capture && (!head_valid || !DDRAM_BUSY);
always @(posedge CLK_VIDEO) begin
    mode_history<={rotate_ccw,no_rotate,flip};
    if(flush) quiescing<=0;
    else if(stop_capture) quiescing<=1;
end

parameter MEM_BASE    = 7'b0010010; // buffer at 0x24000000, 3x8MB

reg  do_flip;

assign DDRAM_CLK      = CLK_VIDEO;
assign DDRAM_BURSTCNT = 1;
assign DDRAM_ADDR     = head[61:33];
assign DDRAM_BE       = head[32] ? 8'hF0 : 8'h0F;
assign DDRAM_DIN      = {head[31:0],head[31:0]};
assign DDRAM_WE       = head_valid;
assign DDRAM_RD       = 0;

assign FB_EN     = capture_en && output_valid && !stop_capture;
assign FB_FORMAT = 5'b00110;
assign FB_BASE   = {MEM_BASE,o_fb,23'd0};
assign FB_STRIDE = stride;

function [1:0] buf_next;
	input [1:0] a,b;
	begin
		buf_next = 1;
		if ((a==0 && b==1) || (a==1 && b==0)) buf_next = 2;
		if ((a==1 && b==2) || (a==2 && b==1)) buf_next = 0;
	end
endfunction

assign video_rotated = ~no_rotate;

always @(posedge CLK_VIDEO) begin
	if(stop_capture) begin do_flip<=0;FB_WIDTH<=240;FB_HEIGHT<=320;end
	else begin
	do_flip <= no_rotate && flip;
	if( do_flip ) begin
		FB_WIDTH  <= hsz;
		FB_HEIGHT <= vsz;
	end else begin
		FB_WIDTH  <= vsz;
		FB_HEIGHT <= hsz;
	end
end

end

reg [1:0] i_fb,o_fb;

// Retain the proven 256-entry donor capacity for 384-pixel source lines; no promise
// about the DDR controller's maximum stall. Two synchronous read stages add
// service latency; sustained service is one tuple every two video clocks.
localparam DEPTH=256;
(* ramstyle="M10K, no_rw_check" *) reg [61:0] tuples[0:DEPTH-1];
reg [7:0] wrptr=0,rdptr=0;
reg [8:0] stored=0;
reg [61:0] ram_q,head;
reg read_pending=0,head_valid=0,output_valid=0;
reg [9:0] pending[0:2];
reg [2:0] frame_done=0,frame_bad=0,fresh=0;
reg [1:0] last_finished_bank=0;
reg last_source_vs=0,last_fb_vbl=0;
wire inactive=no_rotate && !flip;
wire source_edge=VGA_VS && !last_source_vs;
wire display_edge=FB_VBL && !last_fb_vbl;
wire capture_en=fb_en[2];
wire want=ram_wr && capture_en && !stop_capture && !frame_bad[i_fb];
wire enqueue=want && stored<DEPTH;
wire accept=head_valid && !DDRAM_BUSY;
wire fetch=stored!=0 && !read_pending && (!head_valid || accept) && !stop_capture;
wire [1:0] head_bank=head[54:53];
wire [61:0] producer_tuple={{MEM_BASE,i_fb,ram_addr[22:3]},ram_addr[2],ram_data};
reg [1:0] next_producer,publish_bank;
reg publish_ok;
function automatic eligible(input [1:0] bank,input [1:0] next_bank);
    eligible=bank<3 && frame_done[bank] && fresh[bank] && !frame_bad[bank] && pending[bank]==0 && bank!=i_fb;
endfunction
integer choice;
always @* begin
    next_producer=FB_LL ? {1'b0,~i_fb[0]} : buf_next(i_fb,o_fb);
    // Never start overwriting the displayed completed buffer, including when
    // low latency's two-buffer preference is unsafe under backpressure.
    if(output_valid && next_producer==o_fb) next_producer=buf_next(i_fb,o_fb);
    publish_bank=FB_LL ? {1'b0,~i_fb[0]} : buf_next(o_fb,i_fb);
    if(eligible(last_finished_bank,next_producer)) publish_bank=last_finished_bank;
    publish_ok=eligible(publish_bank,next_producer);
    for(choice=0;choice<3;choice=choice+1) begin
        if(!publish_ok && eligible(2'(choice),next_producer)) begin
            publish_bank=2'(choice);publish_ok=1;
        end
    end
    if(source_edge && display_edge && publish_ok) next_producer=buf_next(i_fb,publish_bank);
end
// Registered old-data read. Full simultaneous read/write is deliberately not
// admitted, so a mixed-port same-address collision never needs a RAM waiver.
always @(posedge CLK_VIDEO) begin
    if(enqueue) tuples[wrptr]<=producer_tuple;
    if(fetch) ram_q<=tuples[rdptr];
end
integer bank_index;
always @(posedge CLK_VIDEO) begin
    if(flush) begin
        wrptr<=0;rdptr<=0;stored<=0;read_pending<=0;head_valid<=0;
        output_valid<=0;frame_done<=0;frame_bad<=0;fresh<=0;last_finished_bank<=0;i_fb<=0;o_fb<=0;
        last_source_vs<=VGA_VS;last_fb_vbl<=FB_VBL;
        if(flush) overflow<=0;
        for(bank_index=0;bank_index<3;bank_index=bank_index+1) pending[bank_index]<=0;
    end else begin
        last_source_vs<=VGA_VS;last_fb_vbl<=FB_VBL;
        if(enqueue) wrptr<=wrptr+1'd1;
        if(fetch) rdptr<=rdptr+1'd1;
        case({enqueue,fetch})
            2'b10:stored<=stored+1'd1;
            2'b01:stored<=stored-1'd1;
            default:;
        endcase
        if(accept) head_valid<=0;
        if(read_pending) begin head<=ram_q;head_valid<=1;end
        read_pending<=fetch;
        for(bank_index=0;bank_index<3;bank_index=bank_index+1) begin
            case({enqueue && i_fb==2'(bank_index),accept && head_bank==2'(bank_index)})
                2'b10:pending[bank_index]<=pending[bank_index]+1'd1;
                2'b01:pending[bank_index]<=pending[bank_index]-1'd1;
                default:;
            endcase
        end
        if(want && !enqueue) begin
            overflow<=1;frame_bad[i_fb]<=1;frame_done[i_fb]<=0;
        end
        if(stop_capture) output_valid<=0;
        if(source_edge && !stop_capture) begin
            frame_done[i_fb]<=capture_en && !frame_bad[i_fb] && !(want && !enqueue);
            fresh[i_fb]<=capture_en && !frame_bad[i_fb] && !(want && !enqueue);
            last_finished_bank<=i_fb;
            i_fb<=next_producer;
            frame_done[next_producer]<=0;frame_bad[next_producer]<=0;fresh[next_producer]<=0;
        end
        if(display_edge && !stop_capture) begin
            if(publish_ok) begin
                o_fb<=publish_bank;output_valid<=1;
                for(bank_index=0;bank_index<3;bank_index=bank_index+1)
                    if(fresh[bank_index] && pending[bank_index]==0) fresh[bank_index]<=0;
            end
            // Track the original invisible bank lifecycle during warmup, but
            // never enable/display an incomplete frame.
            else if(!output_valid) o_fb<=FB_LL ? {1'b0,~i_fb[0]} : buf_next(o_fb,i_fb);
        end
    end
end

initial begin
	fb_en = 0;
end

reg  [2:0] fb_en = 0;
reg [11:0] hsz = 320, vsz = 240;
reg [11:0] bwidth;
reg [22:0] bufsize;
always @(posedge CLK_VIDEO) begin
	reg [11:0] hcnt = 0, vcnt = 0;
	reg old_vs, old_de;

	if(stop_capture) begin
		hcnt<=0;vcnt<=0;old_vs<=0;old_de<=0;hsz<=320;vsz<=240;bwidth<=243;bufsize<=0;fb_en<=0;
	end else if(CE_PIXEL) begin
		old_vs <= VGA_VS;
		old_de <= VGA_DE;

		hcnt <= hcnt + 1'd1;
		if(~old_de & VGA_DE) begin
			hcnt <= 1;
			vcnt <= vcnt + 1'd1;
		end
		if(old_de & ~VGA_DE) begin
			hsz <= hcnt;
			if( do_flip ) bwidth <= hcnt + 2'd3;
		end
		if(~old_vs & VGA_VS) begin
			vsz <= vcnt;
			if( !do_flip ) bwidth <= vcnt + 2'd3;
			vcnt <= 0;
			fb_en <= {fb_en[1:0], ~no_rotate | flip};
		end
		if(old_vs & ~VGA_VS) bufsize <= (do_flip ? vsz : hsz ) * stride;
	end
end

wire [13:0] stride = {bwidth[11:2], 4'd0};

reg [22:0] ram_addr, next_addr;
reg [31:0] ram_data;
reg        ram_wr;
always @(posedge CLK_VIDEO) begin
	reg [13:0] hcnt = 0;
	reg old_vs, old_de;

	if(stop_capture) begin
		hcnt<=0;old_vs<=0;old_de<=0;ram_wr<=0;ram_addr<=0;next_addr<=0;ram_data<=0;
	end else begin
	ram_wr <= 0;
	if(CE_PIXEL && capture_en && !inactive) begin
		old_vs <= VGA_VS;
		old_de <= VGA_DE;

		if(~old_vs & VGA_VS) begin
			next_addr <=
				do_flip    ? bufsize-3'd4 :
				rotate_ccw ? (bufsize - stride) : {vsz-1'd1, 2'b00};
			hcnt <= rotate_ccw ? 3'd4 : {vsz-2'd2, 2'b00};
		end
		if(VGA_DE) begin
			ram_wr <= 1;
			ram_data <= {8'd0,VGA_B,VGA_G,VGA_R};
			ram_addr <= next_addr;
			next_addr <=
				do_flip    ? next_addr-3'd4 :
				rotate_ccw ? (next_addr - stride) : (next_addr + stride);
		end
		if(old_de & ~VGA_DE & ~do_flip) begin
			next_addr <= rotate_ccw ? (bufsize - stride + hcnt) : hcnt;
			hcnt <= rotate_ccw ? (hcnt + 3'd4) : (hcnt - 3'd4);
		end
	end
end

end

endmodule
