// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 shimian5

//============================================================================
//  Leland - fast ROM loading via DDR3
//
//  The MRA's <rom index="0" address="0x30000000" ...> makes Main_MiSTer copy
//  the whole ROM image straight into HPS DDR3 at byte address 0x30000000 (fast,
//  no per-byte handshake), then end the download with NO ioctl_wr strobes and
//  ioctl_addr = image length. This module notices that, reads the image back
//  from DDR3 64 bits at a time, and REPLAYS it to leland_board as an ordinary
//  download (ioctl_download / ioctl_index / ioctl_addr / ioctl_wr / ioctl_data),
//  at the board's own pace (it honours the board's ioctl_wait FIFO stall).
//  leland_board therefore needs no changes: it sees the same byte stream it
//  always has, just without the HPS on the other end of the handshake.
//
//  Anything that is NOT a DDR load (a normally streamed ROM, DIP/other
//  indices, ...) passes straight through unchanged.
//
//  The technique (ROM staged in DDR3 at 0x30000000, replayed by a core-side
//  adaptor) follows the approach used by the IGS PGM core.
//
//  While replaying, `active` is high; the top level uses it (with the raw
//  ioctl_download) to keep the frame retimer off the shared DDR3 bus.
//============================================================================

module leland_ddr_loader
#(
	parameter [28:0] DDR_BASE_WORD = 29'h06000000 // byte 0x30000000 >> 3
)
(
	input             clk,

	// From hps_io
	input             ioctl_download,
	input      [15:0] ioctl_index,
	input      [26:0] ioctl_addr,
	input             ioctl_wr,
	input       [7:0] ioctl_data,
	output            ioctl_wait,      // back to hps_io

	// To leland_board
	output            o_download,
	output     [15:0] o_index,
	output     [26:0] o_addr,
	output            o_wr,
	output      [7:0] o_data,
	input             b_wait,          // leland_board's ioctl_wait

	// Replay in progress (including start-up delay)
	output            active,

	// DDR3 master (read only)
	output reg        ddr_acquire,
	output reg [28:0] ddr_addr,
	output reg        ddr_read,
	input             ddr_busy,
	input      [63:0] ddr_rdata,
	input             ddr_rdata_ready
);

localparam [2:0] S_IDLE = 3'd0,  // pass-through
                 S_DLY  = 3'd1,  // let the other DDR3 user drain
                 S_RD   = 3'd2,  // issue a 64-bit read
                 S_RW   = 3'd3,  // wait for read data
                 S_SET  = 3'd4,  // present address/data for one byte
                 S_STB  = 3'd5,  // one-clock write strobe
                 S_END  = 3'd6;  // drop download

reg  [2:0]  st = S_IDLE;
reg         prev_dl = 1'b0;
reg         wr_seen = 1'b0;
reg [26:0]  length  = 27'd0;
reg [26:0]  offset  = 27'd0;
reg  [5:0]  dly     = 6'd0;
reg [63:0]  buffer  = 64'd0;

reg         r_download = 1'b0;
reg [26:0]  r_addr     = 27'd0;
reg         r_wr       = 1'b0;
reg  [7:0]  r_data     = 8'd0;

wire replay = (st != S_IDLE);

// A DDR load ends here: index-0 download just fell with no bytes seen.
// Used combinationally so there is no one-clock gap (which would release the
// board's reset / show it a false end of download) before the replay starts.
wire start_cond = (st == S_IDLE) && prev_dl && !ioctl_download &&
                  (ioctl_index[7:0] == 8'd0) && !wr_seen && (ioctl_addr != 27'd0);

assign active     = replay | start_cond;
assign ioctl_wait = replay ? 1'b0 : b_wait;
assign o_download = replay ? r_download : (ioctl_download | start_cond);
assign o_index    = replay ? 16'd0      : ioctl_index;
assign o_addr     = replay ? r_addr     : ioctl_addr;
assign o_wr       = replay ? r_wr       : ioctl_wr;
assign o_data     = replay ? r_data     : ioctl_data;

initial begin
	ddr_acquire = 1'b0;
	ddr_addr    = 29'd0;
	ddr_read    = 1'b0;
end

always @(posedge clk) begin
	prev_dl <= ioctl_download;
	r_wr    <= 1'b0;

	// a streamed ROM sends bytes; a DDR load does not
	if (ioctl_download && !prev_dl && ioctl_index[7:0] == 8'd0) wr_seen <= 1'b0;
	if (ioctl_download && ioctl_wr  && ioctl_index[7:0] == 8'd0) wr_seen <= 1'b1;

	case (st)
		S_IDLE: begin
			ddr_acquire <= 1'b0;
			ddr_read    <= 1'b0;
			if (start_cond) begin
				length     <= ioctl_addr;
				offset     <= 27'd0;
				dly        <= 6'd0;
				r_download <= 1'b1;
				st         <= S_DLY;
			end
		end

		S_DLY: begin
			dly <= dly + 1'd1;
			if (&dly) st <= S_RD;
		end

		S_RD: begin
			ddr_acquire <= 1'b1;
			if (!ddr_busy) begin
				ddr_addr <= DDR_BASE_WORD + {2'd0, offset[26:3]};
				ddr_read <= 1'b1;
				st       <= S_RW;
			end
		end

		S_RW: begin
			ddr_acquire <= 1'b1;
			if (!ddr_busy) ddr_read <= 1'b0;
			if (ddr_rdata_ready) begin
				buffer      <= ddr_rdata;
				ddr_acquire <= 1'b0;
				ddr_read    <= 1'b0;
				st          <= S_SET;
			end
		end

		S_SET: begin
			if (offset == length) begin
				st <= S_END;
			end else if (!b_wait) begin
				r_addr <= offset;
				r_data <= buffer[offset[2:0]*8 +: 8];
				st     <= S_STB;
			end
		end

		S_STB: begin
			r_wr   <= 1'b1;
			offset <= offset + 1'd1;
			// image done, next byte from this word, or fetch the next word
			st     <= (offset + 1'd1 == length) ? S_END :
			          (&offset[2:0])            ? S_RD  : S_SET;
		end

		S_END: begin
			r_download <= 1'b0;
			st         <= S_IDLE;
		end

		default: st <= S_IDLE;
	endcase
end

endmodule
