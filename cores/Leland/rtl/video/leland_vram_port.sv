// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 shimian5

//============================================================================
//  Leland - Leland CPU-side VRAM I/O port engine
//
//  One instance per CPU. Implements MAME leland_v.cpp exactly:
//    - video_addr_w   (memory-mapped address latch, 0xF800/0xF801)
//    - vram_port_w    (I/O ports 0x00-0x1F, mirrored at 0x40-0x5F)
//    - vram_port_r    (same range)
//
//  The master has an identical port (leland_mvram_port, installed at both 0x00-0x1F and
//  0x40-0x5F for Off-Road); the two CPUs communicate through a mailbox at the top of video
//  RAM (>= 0xF000).
//
//  Op encoding (from the port address):
//    addr[2:0] = operation      addr[3] = auto-increment (+2)
//    addr[4]   = transparency (Slave only; zero nibbles preserve VRAM)
//
//    op 1: write latch0 -> even byte, data -> odd byte;  addr += inc
//    op 2: write data -> even byte, latch1 -> odd byte;  addr += inc
//    op 3: write data -> addr; addr += inc & (addr<<1); addr ^= 1
//    op 5: latch1 <= data; write data -> odd byte (addr|1);  addr += inc
//    op 6: latch0 <= data; write data -> even byte (addr&~1); addr += inc
//    reads: op 3/5/6 mirror the write addressing; other ops return 0.
//
//  Address latch (video_addr_w):
//    low  (0xF800): addr = (addr & 0xFE00) | ((data << 1) & 0x01FE)
//    high (0xF801): addr = ((data << 9) & 0xFE00) | (addr & 0x01FE),
//                   buffer = data[7]
//  The buffer bit is tracked but unused, exactly like MAME (VRAM's upper
//  64 KB is a TODO there: "accessing upper half of video RAM is not
//  implemented").
//
//  The engine performs all address/latch math locally and emits
//  elementary BRAM operations (1 or 2 per Z80 I/O cycle) through a
//  2-deep queue; leland_board's sequencer executes them against the single
//  CPU-side VRAM BRAM port and returns read data via vp_pop/vp_rdata.
//
//  A new I/O cycle is never dropped: vp_stall holds the parent's Z80 /WAIT for as long as
//  the queue cannot accept the op (the same convention as the SDRAM rom_stall).
//============================================================================

module leland_vram_port #(parameter bit TRANS_EN = 1'b0)
(
	input         clk_sys,
	input         reset,
	input         CE_6M,

	// Z80 bus taps
	input  [15:0] cpu_addr,
	input   [7:0] cpu_dout,
	input         io_wr,        // ~iorq_n & ~wr_n
	input         io_rd,        // ~iorq_n & ~rd_n
	input         io_vram_sel,  // port decode: addr[7]==0 && addr[5]==0
	input         vidlat_wr,    // CE_6M-gated memory write to 0xF800/0xF801
	input         vidlat_hi,    // cpu_addr[0] (0=low byte, 1=high byte)

	// registered result of the last VRAM port read (feeds cpu_din)
	output  [7:0] rd_data,

	// High while a new I/O cycle cannot be committed yet; the parent ORs it into the Z80's
	// wait_n.
	output        vp_stall,

	// elementary op stream to leland_board's VRAM sequencer (head of queue)
	output        vp_req,       // op pending
	output        vp_rd,        // 1 = read op, 0 = write op
	output        vp_trans,     // transparent write (RMW nibble merge)
	output [15:0] vp_addr,
	output  [7:0] vp_data,
	input         vp_pop,       // sequencer consumed the head op (same-cycle)
	input   [7:0] vp_rdata      // read result, valid with vp_pop on reads
);

reg [15:0] addr_q;
reg        buffer_q;  // tracked like MAME's m_buffer, never used (see header)
reg  [7:0] latch0, latch1;
reg  [7:0] rd_data_q;

// 2-deep op queue. q1 only ever holds the second plain write of op 1/2.
reg        q0_v, q0_rd, q0_tr;
reg [15:0] q0_a;
reg  [7:0] q0_d;
reg        q1_v;
reg [15:0] q1_a;
reg  [7:0] q1_d;

// io_wr/io_rd stay asserted across several CE_6M ticks of one Z80 I/O cycle; each OUT/IN
// is committed exactly once, on the first tick where the queue is free. A new op is safe
// once q0 has been popped (q1 is always pushed together with q0).
wire queue_busy = q0_v;

reg io_wr_done, io_rd_done;

wire wr_commit = CE_6M && io_wr && io_vram_sel && !io_wr_done && !queue_busy;
wire rd_commit = CE_6M && io_rd && io_vram_sel && !io_rd_done && !queue_busy;

// A queued read is not a completed read. Keep /WAIT asserted until vp_pop
// has installed the reply in rd_data_q; arbitration can outlast the Z80's T2.
// Writes may retire once queued because their complete tuple is retained.
assign vp_stall = io_vram_sel && queue_busy &&
                   ((io_wr && !io_wr_done) || (io_rd && (!io_rd_done || q0_rd)));

always @(posedge clk_sys) begin
	if (reset) begin
		io_wr_done <= 1'b0;
		io_rd_done <= 1'b0;
	end else if (CE_6M) begin
		if (!io_wr) io_wr_done <= 1'b0;
		else if (wr_commit) io_wr_done <= 1'b1;
		if (!io_rd) io_rd_done <= 1'b0;
		else if (rd_commit) io_rd_done <= 1'b1;
	end
end

wire        op_inc = cpu_addr[3];
wire        op_tr  = TRANS_EN && cpu_addr[4];
wire  [2:0] op     = cpu_addr[2:0];

wire [15:0] addr_plus_inc = addr_q + (op_inc ? 16'd2 : 16'd0);
// MAME op 3: addr += inc & (addr << 1); addr ^= 1
// (increment only lands when inc is set AND the address is odd)
wire [15:0] addr_op3_next = (addr_q + ((op_inc && addr_q[0]) ? 16'd2 : 16'd0)) ^ 16'd1;

always @(posedge clk_sys) begin
	if (reset) begin
		addr_q    <= 16'd0;
		buffer_q  <= 1'b0;
		latch0    <= 8'd0;
		latch1    <= 8'd0;
		rd_data_q <= 8'd0;
		q0_v      <= 1'b0;
		q1_v      <= 1'b0;
	end else begin
		// Pop first; pushes below take precedence if they coincide.
		if (vp_pop) begin
			if (q0_rd) rd_data_q <= vp_rdata;
			q0_v  <= q1_v;
			q0_rd <= 1'b0;
			q0_tr <= 1'b0;
			q0_a  <= q1_a;
			q0_d  <= q1_d;
			q1_v  <= 1'b0;
		end

		// Memory-mapped address latch (video_addr_w); idempotent across CE_6M ticks.
		if (vidlat_wr) begin
			if (!vidlat_hi)
				addr_q <= {addr_q[15:9], cpu_dout, 1'b0};
			else begin
				addr_q   <= {cpu_dout[6:0], addr_q[8:1], 1'b0};
				buffer_q <= cpu_dout[7];
			end
		end

		// vram_port_w
		if (wr_commit) begin
			case (op)
				3'd1: begin
					q0_v <= 1'b1; q0_rd <= 1'b0; q0_tr <= 1'b0;
					q0_a <= {addr_q[15:1], 1'b0}; q0_d <= latch0;
					q1_v <= 1'b1;
					q1_a <= {addr_q[15:1], 1'b1}; q1_d <= cpu_dout;
					addr_q <= addr_plus_inc;
				end
				3'd2: begin
					q0_v <= 1'b1; q0_rd <= 1'b0; q0_tr <= 1'b0;
					q0_a <= {addr_q[15:1], 1'b0}; q0_d <= cpu_dout;
					q1_v <= 1'b1;
					q1_a <= {addr_q[15:1], 1'b1}; q1_d <= latch1;
					addr_q <= addr_plus_inc;
				end
				3'd3: begin
					q0_v <= 1'b1; q0_rd <= 1'b0; q0_tr <= op_tr;
					q0_a <= addr_q; q0_d <= cpu_dout;
					addr_q <= addr_op3_next;
				end
				3'd5: begin
					latch1 <= cpu_dout;
					q0_v <= 1'b1; q0_rd <= 1'b0; q0_tr <= op_tr;
					q0_a <= {addr_q[15:1], 1'b1}; q0_d <= cpu_dout;
					addr_q <= addr_plus_inc;
				end
				3'd6: begin
					latch0 <= cpu_dout;
					q0_v <= 1'b1; q0_rd <= 1'b0; q0_tr <= op_tr;
					q0_a <= {addr_q[15:1], 1'b0}; q0_d <= cpu_dout;
					addr_q <= addr_plus_inc;
				end
				default: ; // MAME: warning only -- no write, no addr change
			endcase
		end

		// vram_port_r
		if (rd_commit) begin
			case (op)
				3'd3: begin
					q0_v <= 1'b1; q0_rd <= 1'b1; q0_tr <= 1'b0;
					q0_a <= addr_q;
					addr_q <= addr_op3_next;
				end
				3'd5: begin
					q0_v <= 1'b1; q0_rd <= 1'b1; q0_tr <= 1'b0;
					q0_a <= {addr_q[15:1], 1'b1};
					addr_q <= addr_plus_inc;
				end
				3'd6: begin
					q0_v <= 1'b1; q0_rd <= 1'b1; q0_tr <= 1'b0;
					q0_a <= {addr_q[15:1], 1'b0};
					addr_q <= addr_plus_inc;
				end
				default: rd_data_q <= 8'd0; // MAME: unknown read op returns 0
			endcase
		end
	end
end

assign rd_data  = rd_data_q;
assign vp_req   = q0_v;
assign vp_rd    = q0_rd;
assign vp_trans = q0_tr;
assign vp_addr  = q0_a;
assign vp_data  = q0_d;

endmodule
