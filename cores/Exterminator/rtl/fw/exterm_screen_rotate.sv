//============================================================================
//  exterm_screen_rotate -- hardened copy of sys/arcade_video.v `screen_rotate`
//  (Sorgelig 2020, GPL-2.0-or-later).  Same ports, same framebuffer layout (+90 / -90 /
//  180-degree flip into a triple buffer at 0x24000000), same HDMI scaler contract.
//
//  Two defects of the stock module are fixed here (sys/ stays unmodified):
//
//  1. DDRAM_BUSY is ignored by the stock writer: it pulses DDRAM_WE one clock per pixel, so
//     writes issued while the scaler/HPS hold the DDR port busy are lost (dashed columns on
//     rotated cores; lessons 4860, 10336, 10901).  Every write tuple (address, data, byte
//     enable) is queued in a FIFO and held on DDRAM_* until DDRAM_BUSY is low.  Overflow drops
//     the pixel and latches `fifo_ovf` (cleared on the next vertical sync) -- it is wired to
//     LED_USER by the top so it is visible.
//
//  2. Stock non-low-latency mode advances the reader buffer on EVERY FB_VBL (lesson 10276).
//     When the HDMI output rate is higher than the core frame rate (59.56 Hz core vs 60 Hz out)
//     a frame periodically has not completed yet, so the reader steps back to the OLDER frame
//     (visible judder every ~136 frames).  Here the reader only advances when a complete frame
//     has arrived since the previous switch (fb_new); if the writer's VS lands in the same
//     clock as FB_VBL the reader takes the frame that just completed.
//============================================================================
module exterm_screen_rotate
(
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
	output        DDRAM_RD,

	output reg    fifo_ovf
);

parameter MEM_BASE    = 7'b0010010; // buffer at 0x24000000, 3x8MB

reg  do_flip;

assign DDRAM_CLK      = CLK_VIDEO;
assign DDRAM_BURSTCNT = 8'd1;
assign DDRAM_RD       = 1'b0;

assign FB_EN     = fb_en[2];
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
	do_flip <= no_rotate && flip;
	if( do_flip ) begin
		FB_WIDTH  <= hsz;
		FB_HEIGHT <= vsz;
	end else begin
		FB_WIDTH  <= vsz;
		FB_HEIGHT <= hsz;
	end
end

// ---------------------------------------------------------------------------
// triple buffer pointers (fix 2)
// ---------------------------------------------------------------------------
reg [1:0] i_fb = 2'd0, o_fb = 2'd1;
reg       fb_new = 1'b0;
always @(posedge CLK_VIDEO) begin
	reg old_vbl, old_vs;
	reg vbl_rise, vs_rise;
	old_vbl <= FB_VBL;
	old_vs  <= VGA_VS;
	vbl_rise = ~old_vbl & FB_VBL;
	vs_rise  = ~old_vs  & VGA_VS;

	if(FB_LL) begin
		if(vbl_rise) o_fb <= {1'b0,~i_fb[0]};
		if(vs_rise)  i_fb <= {1'b0,~i_fb[0]};
		fb_new <= 1'b0;
	end
	else begin
		if(vs_rise) begin
			i_fb   <= buf_next(i_fb,o_fb);   // writer moves to the free buffer; old i_fb is complete
			fb_new <= 1'b1;
		end
		if(vbl_rise) begin
			if(vs_rise) begin
				o_fb   <= i_fb;              // same clock: show the frame that just completed
				fb_new <= 1'b0;
			end
			else if(fb_new) begin
				o_fb   <= buf_next(o_fb,i_fb); // newest complete frame
				fb_new <= 1'b0;
			end
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

	if(CE_PIXEL) begin
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

// ---------------------------------------------------------------------------
// pixel address generation (stock)
// ---------------------------------------------------------------------------
reg [22:0] ram_addr, next_addr;
reg [31:0] ram_data;
reg        ram_wr;
always @(posedge CLK_VIDEO) begin
	reg [13:0] hcnt = 0;
	reg old_vs, old_de;

	ram_wr <= 0;
	if(CE_PIXEL && FB_EN) begin
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

// ---------------------------------------------------------------------------
// write queue (fix 1): tuple = {byte-enable half, 29-bit DDR word address, 32-bit pixel}
// The buffer index is latched at push time so frames never mix across a buffer switch.
// ---------------------------------------------------------------------------
localparam QAW = 7;                         // 128 entries; a 64-pixel stall is ~13 us at 5 MHz pixels
(* ramstyle = "M10K, no_rw_check" *) reg [61:0] q_mem [0:(1<<QAW)-1];   // M10K, not MLAB (LAB budget)
reg [QAW:0] q_wp = 0, q_rp = 0;
wire        q_empty = (q_wp == q_rp);
wire        q_full  = (q_wp[QAW-1:0] == q_rp[QAW-1:0]) && (q_wp[QAW] != q_rp[QAW]);

wire [61:0] q_in = {ram_addr[2], MEM_BASE, i_fb, ram_addr[22:3], ram_data};

reg        out_v = 1'b0;
reg [61:0] out_q;

wire q_push = ram_wr;
wire accepted = out_v && !DDRAM_BUSY;
wire q_pop  = !q_empty && (!out_v || accepted);

reg old_vs_q;
always @(posedge CLK_VIDEO) begin
	old_vs_q <= VGA_VS;
	if (~old_vs_q & VGA_VS) fifo_ovf <= 1'b0;

	if (q_push) begin
		if (q_full) fifo_ovf <= 1'b1;
		else begin
			q_mem[q_wp[QAW-1:0]] <= q_in;
			q_wp <= q_wp + 1'd1;
		end
	end

	if (q_pop) begin
		out_q <= q_mem[q_rp[QAW-1:0]];
		q_rp  <= q_rp + 1'd1;
		out_v <= 1'b1;
	end
	else if (accepted) out_v <= 1'b0;
end

assign DDRAM_WE   = out_v;
assign DDRAM_ADDR = out_q[60:32];
assign DDRAM_BE   = out_q[61] ? 8'hF0 : 8'h0F;
assign DDRAM_DIN  = {out_q[31:0], out_q[31:0]};

endmodule
