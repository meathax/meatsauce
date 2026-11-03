// Main CPU: fx68k (cycle-accurate 68000, rtl/cpu/fx68k/PROVENANCE.md) plus
// address decode and bus sequencing for every in-scope memory map, selected
// by `board`. Autovectored interrupts only (VPA in the acknowledge cycle).
//
// Clock: phi1 and phi2 enables alternate every cpu_half clk (6 = 8 MHz, 3 =
// 16 MHz). An access starts when AS and a data strobe are low and DTACK
// follows acc_ready. A phi2 that would sample DTACK while the access is not
// ready is held until it is, so a slow SDRAM read costs clk cycles rather
// than a 68000 wait state. With cpu_half>=6, fabric-tick debt repays those
// stalls at up to twice the nominal rate (scripts/verify_r7_recovery.py).

`default_nettype none

package seta_board_pkg;
	// Memory maps. Must agree with scripts/mame_capture.py's FAMILIES table.
	typedef enum logic [4:0] {
		// downtown_map (downtown, twineagl, metafox, arbalest); its sub CPU,
		// tile bank and control registers are decoded in seta_core. The
		// numbering is seta_board_cfg's from before the split, kept so the
		// .mra mod bytes and scripts/maincpu_sweep.py still line up.
		BOARD_DOWNTOWN  = 5'd18,
		// calibr50_map: X1-010 on the 65C02, battery RAM, uPD4701
		BOARD_CALIBR50  = 5'd19,
		// tndrcade_map: no tile layer, sound on the 65C02
		BOARD_TNDRCADE  = 5'd20
	} board_t;
endpackage

import seta_board_pkg::*;

module maincpu (
	input  wire         clk,
	input  wire         reset,

	input  wire  [4:0]  board,

	// clk per phase (half a CPU clock); cpu_run low freezes the CPU (pause)
	input  wire  [3:0]  cpu_half,
	input  wire         cpu_run,

	// program ROM (sdram_narrow_bridge): rom_req pulses, rom_addr held until rom_valid
	output logic        rom_req,
	output logic [23:1] rom_addr,      // WORD address
	input  wire         rom_valid,
	input  wire  [15:0] rom_data,

	// work RAM, masked by wram_mask
	output logic [19:1] wram_addr,
	output logic        wram_wel, wram_weh,
	output logic [15:0] wram_wdata,
	input  wire  [15:0] wram_rdata,

	// Other regions: one-hot io_sel over the IO_* indices, read data due within
	// the access. Undriven reads are zero, as MAME's unmapped reads.
	output logic        io_req,
	output logic        io_we,
	output logic [23:1] io_addr,
	// palette index as a word, formed here where the full address exists
	output logic [11:0] pal_index_w,
	// COINS at in_base+8 (calibr50)
	output wire         coins_at8,
	output logic [15:0] io_wdata,
	output logic        io_uds, io_lds,
	output logic [15:0] io_sel,
	input  wire  [15:0] io_rdata,
	// hold the access in S_MEM3 (DTACK late) until the read data is current
	input  wire         io_hold,

	// 0 = none
	input  wire  [2:0]  ipl_level,

	// Trace strobe per completed access, for comparison with
	// mame_capture.py --boot-trace. iack: FC = 111 with the latched level on
	// A3..A1, so seta_irq clears the level actually taken.
	output logic        iack,
	output logic  [2:0] iack_level,

	output logic        dbg_stb,
	output logic [23:1] dbg_addr,
	output logic        dbg_we,
	output logic [15:0] dbg_data
);

	localparam int IO_PALETTE  = 0;
	localparam int IO_SPRYLOW  = 1;   // sprite Y low + per-column scroll
	localparam int IO_SPRCTRL  = 2;   // 4 control bytes
	localparam int IO_SPRCODE  = 3;   // sprite code / X / attributes
	localparam int IO_L0VRAM   = 4;
	localparam int IO_L1VRAM   = 5;
	localparam int IO_L0CTRL   = 6;
	localparam int IO_L1CTRL   = 7;
	localparam int IO_X1SND    = 8;
	localparam int IO_VREGS    = 9;   // the X1-011 order / sample-bank register
	localparam int IO_INPUTS   = 10;  // P1 / P2 / COINS
	localparam int IO_DSW      = 11;
	localparam int IO_WRAM2    = 12;  // the second work RAM block, where present
	// 13-15: seta_core's palette SRAM, protection and PIT slots, unused here

	// declared before the instance: a port connection to an undeclared name is
	// inferred as a net by ModelSim even under `default_nettype none`, and the
	// later explicit declaration then collides with it.
	wire [23:1] eab;
	wire [15:0] cpu_dout;
	wire [15:0] cpu_din;
	wire        as_n, n_uds, n_lds, rw_n;
	wire        fc0, fc1, fc2;
	wire  [2:0] fc = {fc2, fc1, fc0};
	logic       en_phi1, en_phi2;
	logic       acc_ready;

	wire        in_iack   = !as_n && (fc == 3'b111);
	wire        dtack_n   = !(acc_ready && !as_n && !in_iack);

	fx68k u_cpu (
		.clk(clk), .HALTn(1'b1), .extReset(reset), .pwrUp(reset),
		.enPhi1(en_phi1), .enPhi2(en_phi2),
		.eRWn(rw_n), .ASn(as_n), .LDSn(n_lds), .UDSn(n_uds), .E(), .VMAn(),
		.FC0(fc0), .FC1(fc1), .FC2(fc2), .BGn(), .oRESETn(), .oHALTEDn(),
		.DTACKn(dtack_n), .VPAn(!in_iack), .BERRn(1'b1),
		.BRn(1'b1), .BGACKn(1'b1),
		.IPL0n(~ipl_level[0]), .IPL1n(~ipl_level[1]), .IPL2n(~ipl_level[2]),
		.iEdb(cpu_din), .oEdb(cpu_dout), .eab(eab)
	);

	// an access: AS and a strobe (a write's strobes follow AS by a state, with
	// the data bus driven by then)
	wire        acc_active = !as_n && !in_iack && !(n_uds && n_lds);
	wire        acc_write  = !rw_n;
	wire [23:0] addr24     = {eab, 1'b0};

	// interrupt acknowledge: one pulse as the cycle starts
	logic       as_q = 1'b1;
	always_ff @(posedge clk) as_q <= as_n;
	assign iack       = in_iack && as_q;
	assign iack_level = eab[3:1];

	// Phase enables. Each delayed fabric tick is owed to the CPU. Repay one
	// tick per running fabric edge, advancing the phase counter by two, until
	// debt drains. The production cpu_half=6 gives nominal 8 MHz / maximum
	// 16 MHz, with at least three fabric clocks between ANY phase enables.
	// Keep smaller legacy half-periods at their original cadence so the
	// existing minimum-three-clock fx68k constraint is never shortened.
	// Pause freezes both phase and debt. Reset discards old-epoch debt while
	// retaining the original phase sequencing through the fx68k reset.
	// A 32-bit debt overflow stops the CPU until reset rather than silently
	// losing time (44.7 seconds of continuous stall at 96 MHz).
	logic [3:0] ph_cnt = 4'd0;
	logic       next_phi2 = 1'b0;
	logic [1:0] phi2_in_as = 2'd0;
	logic [31:0] ph_debt = 32'd0;
	logic        ph_debt_overflow = 1'b0;
	wire        ph_recover = !reset && (cpu_half >= 4'd6) && (ph_debt != 0)
	                       && ({1'b0, ph_cnt} + 5'd2 <= {1'b0, cpu_half});
	wire [4:0]  ph_step = ph_recover ? 5'd2 : 5'd1;
	wire        ph_due = cpu_run && !ph_debt_overflow
	                   && ({1'b0, ph_cnt} + ph_step >= {1'b0, cpu_half});
	wire        ph_hold = next_phi2 && !as_n && !in_iack && !acc_ready
	                   && phi2_in_as != 2'd0;
	assign en_phi1 = ph_due && !next_phi2;
	assign en_phi2 = ph_due && next_phi2 && !ph_hold;
	always_ff @(posedge clk) begin
		if (reset) begin
			ph_debt <= 32'd0;
			ph_debt_overflow <= 1'b0;
		end else if (cpu_run && !ph_debt_overflow) begin
			if (ph_due && ph_hold) begin
				if (&ph_debt) ph_debt_overflow <= 1'b1;
				else ph_debt <= ph_debt + 32'd1;
			end else if (ph_recover) ph_debt <= ph_debt - 32'd1;
		end
		if (cpu_run && !ph_debt_overflow) begin
			if (!ph_due)      ph_cnt <= ph_cnt + ph_step[3:0];
			else if (!ph_hold) begin
				ph_cnt    <= 4'd0;
				next_phi2 <= ~next_phi2;
			end
		end
		if (as_n)                            phi2_in_as <= 2'd0;
		else if (en_phi2 && phi2_in_as != 2'd3) phi2_in_as <= phi2_in_as + 2'd1;
	end

	// Address decode. Regions decode on ranges, so byte, word and long accesses all land.
	logic [23:0] rom_end;
	logic [23:0] wram_base, wram_end;
	logic [23:0] wram2_base, wram2_end;
	logic [23:0] pal_base, pal_end;
	logic [23:0] spry_base, sprc_base, sprcode_base;
	logic [23:0] l0v_base, l1v_base, l0c_base, l1c_base;
	logic [23:0] x1_base;
	logic [23:0] vregs_base;
	logic [23:0] in_base, dsw_base;
	// input window size, per map (calibr50 COINS at +8)
	logic  [4:0] in_span;
	logic        coins_hi;
	logic        has_l0, has_l1, has_wram2;
	logic [23:0] wram_mask;
	logic        board_unmapped;

	// base NONE: region absent
	localparam logic [23:0] NONE = 24'hFFFFFF;

	always_comb begin
		// defaults, overridden per map
		rom_end      = 24'h1FFFFF;
		wram_base    = 24'h200000;  wram_end   = 24'h21FFFF;
		wram_mask    = 24'h03FFFF;
		wram2_base   = 24'h300000;  wram2_end  = 24'h30FFFF;
		pal_base     = 24'h700400;  pal_end    = 24'h700FFF;
		l0v_base     = 24'h800000;  l1v_base   = 24'h880000;
		l0c_base     = 24'h900000;  l1c_base   = 24'h980000;
		spry_base    = 24'hA00000;  sprc_base  = 24'hA00600;
		sprcode_base = 24'hB00000;
		x1_base      = 24'hC00000;
		vregs_base   = 24'h500000;
		in_base      = 24'h400000;  dsw_base   = 24'h600000;
		in_span      = 5'd6;        coins_hi   = 1'b0;
		has_l0 = 1'b1; has_l1 = 1'b1; has_wram2 = 1'b1;
		board_unmapped = 1'b0;

		case (board)
			BOARD_DOWNTOWN: begin                    // downtown.cpp downtown_map
				rom_end    = 24'h09FFFF;
				// declared 0xf00000-0xffffff; the games write 0xf00000-0xf03fff
				// (metafox, arbalest, twineagl) and 0xffc000-0xffffff (downtown,
				// twineagl), which a 128 KB mirror keeps apart
				wram_base  = 24'hF00000; wram_end = 24'hFFFFFF;
				wram_mask  = 24'h01FFFF;
				wram2_base = NONE; has_wram2 = 1'b0;
				pal_base   = 24'h700000; pal_end  = 24'h7003FF;
				l0c_base   = 24'h800000; l0v_base = 24'h900000;
				l1c_base   = NONE;       l1v_base = NONE;  has_l1 = 1'b0;
				spry_base  = 24'hD00000; sprc_base = 24'hD00600;
				sprcode_base = 24'hE00000;
				x1_base    = 24'h100000;
				in_base    = NONE;
				vregs_base = NONE;
			end

			BOARD_CALIBR50: begin                    // downtown.cpp calibr50_map
				rom_end    = 24'h09FFFF;
				wram_base  = 24'hFF0000; wram_end = 24'hFFFFFF;
				wram_mask  = 24'h00FFFF;
				// the battery RAM, 0x200000-0x200fff (seta_core)
				wram2_base = 24'h200000; wram2_end = 24'h200FFF;
				has_wram2  = 1'b1;
				pal_base   = 24'h700000; pal_end  = 24'h7003FF;
				l0c_base   = 24'h800000; l0v_base = 24'h900000;
				l1c_base   = NONE;       l1v_base = NONE;  has_l1 = 1'b0;
				spry_base  = 24'hD00000; sprc_base = 24'hD00600;
				sprcode_base = 24'hE00000;
				x1_base    = NONE;
				// X1-004: P1 +0, P2 +2, COINS +8
				in_base    = 24'hA00000;
				in_span    = 5'd10;  coins_hi = 1'b1;
				vregs_base = NONE;
			end

			BOARD_TNDRCADE: begin                    // downtown.cpp tndrcade_map
				rom_end    = 24'h07FFFF;
				// 16 KB at 0xe00000, mirrored at 0xffc000
				wram_base  = 24'hE00000; wram_end = 24'hFFFFFF;
				wram_mask  = 24'h003FFF;
				wram2_base = NONE; has_wram2 = 1'b0;
				pal_base   = 24'h380000; pal_end  = 24'h3803FF;
				l0v_base = NONE; l1v_base = NONE; l0c_base = NONE; l1c_base = NONE;
				has_l0 = 1'b0; has_l1 = 1'b0;
				spry_base  = 24'h600000; sprc_base = 24'h600600;
				sprcode_base = 24'hC00000;
				x1_base    = NONE;
				// inputs and DSW are the 65C02's
				in_base    = NONE;  dsw_base = NONE;
				vregs_base = NONE;
			end

			default: board_unmapped = 1'b1;
		endcase
	end

	// is_rom from the live address (needed in S_IDLE); the rest from q_a
	wire is_rom     = (addr24 <= rom_end);

	// q_a: address latched in S_IDLE, stable through the access (timing)
	logic [23:0] q_a;
	wire is_wram    = (q_a >= wram_base)  && (q_a <= wram_end);
	wire is_wram2   = has_wram2 && (q_a >= wram2_base) && (q_a <= wram2_end);
	wire [10:0] pal_off_main = q_a[11:1] - pal_base[11:1];
	wire is_pal     = (q_a >= pal_base) && (q_a <= pal_end);
	wire is_spry    = (q_a >= spry_base)  && (q_a <  spry_base + 24'h600);
	wire is_sprc    = (q_a >= sprc_base)  && (q_a <  sprc_base + 24'h8);
	// VRAM and sprite code windows: 16 KB each
	localparam logic [23:0] vwin = 24'h4000;
	localparam logic [23:0] swin = 24'h4000;
	wire is_sprcode = (q_a >= sprcode_base) && (q_a < sprcode_base + swin);
	wire is_l0v     = has_l0 && (q_a >= l0v_base) && (q_a < l0v_base + vwin);
	wire is_l1v     = has_l1 && (q_a >= l1v_base) && (q_a < l1v_base + vwin);
	wire is_l0c     = has_l0 && (q_a >= l0c_base) && (q_a < l0c_base + 24'h6);
	wire is_l1c     = has_l1 && (q_a >= l1c_base) && (q_a < l1c_base + 24'h6);
	wire is_x1      = (q_a >= x1_base)    && (q_a <  x1_base + 24'h4000);
	wire is_vregs   = (vregs_base != NONE) && (q_a >= vregs_base) &&
	                  (q_a < vregs_base + 24'h8);
	// coins_hi: COINS at +8, with +4..+7 a gap
	wire is_inputs  = (q_a >= in_base) && (q_a < in_base + {19'd0, in_span})
	               && !(coins_hi && (q_a >= in_base + 24'h4)
	                             && (q_a <  in_base + 24'h8));
	wire is_dsw     = (q_a >= dsw_base)   && (q_a <  dsw_base + 24'h4);

	// Bus sequencing. acc_ready is a held level, DTACK, until AS rises. RAM and
	// I/O accesses take four cycles (S_MEM..S_MEM4): the request (address, data,
	// decode) is registered in S_MEM, io_req asserted in S_MEM2, the read
	// captured in S_MEM4. Registers everything leaving the module (timing).
	typedef enum logic [3:0] { S_IDLE, S_ROM, S_MEM, S_MEM2, S_MEM3, S_MEM4, S_DONE } state_t;
	state_t state;

	wire [23:0] wram_off = (q_a - wram_base) & wram_mask;

	wire [15:0] io_sel_comb = {3'b000,  // 15-13
	                   is_wram2,      // 12
	                   is_dsw,        // 11
	                   is_inputs,     // 10
	                   is_vregs,      //  9
	                   is_x1,         //  8
	                   is_l1c,        //  7
	                   is_l0c,        //  6
	                   is_l1v,        //  5
	                   is_l0v,        //  4
	                   is_sprcode,    //  3
	                   is_sprc,       //  2
	                   is_spry,       //  1
	                   is_pal};       //  0

	logic [15:0] rd_data;
	logic        dbg_sent;

	logic [23:1] q_addr;
	logic [15:0] q_wdata;
	logic        q_we, q_uds, q_lds;
	logic        q_wram, q_wram_wel, q_wram_weh;
	logic [19:1] q_wram_addr;
	logic [15:0] q_sel;

	// rom_addr registered (timing); addr24 is stable through the access
	logic [23:1] q_rom_addr;

	// ROM word latched on rom_valid. The bridge packs the even byte low; the
	// 68000 is big-endian, so the word is swapped here.
	parameter bit ROM_BYTESWAP = 1'b1;
	wire [15:0] rom_word = ROM_BYTESWAP ? {rom_data[7:0], rom_data[15:8]} : rom_data;

	always_ff @(posedge clk) begin
		rom_req <= 1'b0;                 // a PULSE, per the bridge's contract
		dbg_stb <= 1'b0;

		if (reset) begin
			state     <= S_IDLE;
			acc_ready <= 1'b0;
			dbg_sent  <= 1'b0;
			rd_data   <= 16'h0000;
		end else begin
			case (state)
				S_IDLE: begin
					q_a <= addr24;
					if (acc_active && !acc_ready) begin
						if (is_rom && !acc_write) begin
							rom_req    <= 1'b1;
							q_rom_addr <= addr24[23:1];
							state      <= S_ROM;
						end else begin
							state <= S_MEM;
						end
					end
				end

				S_ROM: begin
					if (rom_valid) begin
						rd_data   <= rom_word;
						acc_ready <= 1'b1;
						state     <= S_DONE;
					end
				end

				S_MEM: begin
					q_addr      <= q_a[23:1];
					q_wdata     <= cpu_dout;
					q_we        <= acc_write;
					q_uds       <= ~n_uds;
					q_lds       <= ~n_lds;
					q_sel       <= io_sel_comb;
					q_wram      <= is_wram;
					pal_index_w <= {1'b0, pal_off_main};
					q_wram_addr <= wram_off[19:1];
					q_wram_wel  <= is_wram && acc_write && !n_lds;
					q_wram_weh  <= is_wram && acc_write && !n_uds;
					state       <= S_MEM2;
				end
				S_MEM2: begin
					q_wram_wel <= 1'b0;
					q_wram_weh <= 1'b0;
					state      <= S_MEM3;
				end
				S_MEM3: if (!io_hold) state <= S_MEM4;
				S_MEM4: begin
					rd_data   <= q_wram ? wram_rdata : io_rdata;
					acc_ready <= 1'b1;
					state     <= S_DONE;
				end

				S_DONE: begin
					// the trace strobe on the first cycle, while the bus still
					// holds the access; ready held until the cycle ends
					if (!dbg_sent) begin
						dbg_sent  <= 1'b1;
						dbg_stb   <= 1'b1;
						dbg_addr  <= addr24[23:1];
						dbg_we    <= acc_write;
						dbg_data  <= acc_write ? cpu_dout : rd_data;
					end
					if (as_n) begin
						acc_ready <= 1'b0;
						dbg_sent  <= 1'b0;
						state     <= S_IDLE;
					end
				end
			endcase
		end
	end

	assign cpu_din    = rd_data;

	assign coins_at8  = coins_hi;

	assign rom_addr   = q_rom_addr;

	assign wram_addr  = q_wram_addr;
	assign wram_wdata = q_wdata;
	assign wram_wel   = q_wram_wel;
	assign wram_weh   = q_wram_weh;

	assign io_req   = (state == S_MEM2);
	assign io_we    = q_we;
	assign io_addr  = q_addr;
	assign io_wdata = q_wdata;
	assign io_uds   = q_uds;
	assign io_lds   = q_lds;
	assign io_sel   = q_sel;

// synthesis translate_off
	// simulation: a board value with no map
	always_ff @(posedge clk) begin
		if (!reset && board_unmapped)
			$fatal(1, "maincpu: board=%0d has no memory map", board);
	end

	// simulation: no region may start inside the ROM range (is_rom wins reads)
	always_ff @(posedge clk) begin
		if (!reset) begin
			if (wram_base <= rom_end)
				$fatal(1, "maincpu: board=%0d work RAM at %06x is inside ROM (rom_end %06x)",
				       board, wram_base, rom_end);
			if (has_wram2 && wram2_base != NONE && wram2_base <= rom_end)
				$fatal(1, "maincpu: board=%0d work RAM 2 at %06x is inside ROM (rom_end %06x)",
				       board, wram2_base, rom_end);
			if (pal_base != NONE && pal_base <= rom_end)
				$fatal(1, "maincpu: board=%0d palette at %06x is inside ROM (rom_end %06x)",
				       board, pal_base, rom_end);
			if (x1_base != NONE && x1_base <= rom_end)
				$fatal(1, "maincpu: board=%0d X1-010 at %06x is inside ROM (rom_end %06x)",
				       board, x1_base, rom_end);
			if (in_base != NONE && in_base <= rom_end)
				$fatal(1, "maincpu: board=%0d inputs at %06x are inside ROM (rom_end %06x)",
				       board, in_base, rom_end);
			if (dsw_base != NONE && dsw_base <= rom_end)
				$fatal(1, "maincpu: board=%0d DSW at %06x is inside ROM (rom_end %06x)",
				       board, dsw_base, rom_end);
		end
	end
// synthesis translate_on

endmodule

`default_nettype wire
